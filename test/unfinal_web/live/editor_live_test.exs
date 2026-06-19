defmodule UnfinalWeb.EditorLiveTest do
  use UnfinalWeb.ConnCase

  alias Unfinal.ContentStore
  alias Unfinal.NamespaceStore

  setup do
    previous_data_dir = System.get_env("UNFINAL_DATA_DIR")

    data_dir =
      Path.join(System.tmp_dir!(), "unfinal-editor-live-#{System.unique_integer([:positive])}")

    System.put_env("UNFINAL_DATA_DIR", data_dir)
    File.rm_rf!(data_dir)
    ContentStore.clear()
    NamespaceStore.clear()

    on_exit(fn ->
      ContentStore.clear()
      NamespaceStore.clear()
      File.rm_rf!(data_dir)

      if previous_data_dir do
        System.put_env("UNFINAL_DATA_DIR", previous_data_dir)
      else
        System.delete_env("UNFINAL_DATA_DIR")
      end
    end)

    {:ok, data_dir: data_dir}
  end

  test "redirects slash to /n and renders storage paths without /n prefix", %{conn: conn} do
    ContentStore.set("/", "root text")
    ContentStore.set("/existing", "saved text")

    assert {:error, {:redirect, %{to: "/n"}}} = live(conn, ~p"/")
    {:ok, root, root_html} = live(conn, ~p"/n")
    {:ok, notes, notes_html} = live(conn, "/n/notes")
    {:ok, existing, existing_html} = live(conn, "/n/existing")

    assert root_html =~ ~s(<article id="readonly-document")
    assert notes_html =~ ~s(<article id="readonly-document")
    assert root_html =~ "root text"
    assert existing_html =~ "saved text"
    assert render(root) =~ "root text"
    refute render(notes) =~ "saved text"
    assert render(existing) =~ "saved text"
  end

  test "unauthenticated content view shows readonly page chrome", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/n/notes")

    assert html =~ ~s(<article id="readonly-document")
    refute html =~ "<textarea"
    assert html =~ "Unfinal"
    assert html =~ ~s(<footer id="login-bar")
    assert html =~ "readonly live view"
    assert html =~ "Login to edit"
    assert html =~ ~s(href="/login?return_to=%2Fn%2Fnotes")
  end

  test "readonly document does not add template whitespace to content", %{conn: conn} do
    ContentStore.set("/plain", "hello")

    {:ok, _view, html} = live(conn, "/n/plain")

    assert html =~ ~r/<article[^>]*id="readonly-document"[^>]*>hello<\/article>/
  end

  test "superuser edits only /n root", %{conn: conn, data_dir: data_dir} do
    with_writers("writer@example.com")
    conn = logged_in(conn, "writer", "writer@example.com")

    {:ok, root, root_html} = live(conn, ~p"/n")
    {:ok, child, child_html} = live(conn, "/n/alpha")

    assert root_html =~ "<textarea"
    refute child_html =~ "<textarea"

    root |> form("form[phx-change=save]", %{content: "root body"}) |> render_change()
    render_hook(child, "save", %{"content" => "blocked"})

    assert ContentStore.get("/") == "root body"
    assert ContentStore.get("/n") == ""
    assert ContentStore.get("/alpha") == ""
    assert File.read!(document_file(data_dir, "/")) == "root body"
    refute File.exists?(document_file(data_dir, "/n"))
  end

  test "namespace owner edits own namespace and descendants but not root", %{
    conn: conn,
    data_dir: data_dir
  } do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    conn = logged_in(conn, "owner", "owner@example.com")

    {:ok, root, root_html} = live(conn, ~p"/n")
    {:ok, namespace, namespace_html} = live(conn, "/n/alpha")
    {:ok, child, child_html} = live(conn, "/n/alpha/page")
    {:ok, other, other_html} = live(conn, "/n/beta")

    refute root_html =~ "<textarea"
    assert namespace_html =~ "<textarea"
    assert child_html =~ "<textarea"
    refute other_html =~ "<textarea"

    namespace |> form("form[phx-change=save]", %{content: "home"}) |> render_change()
    child |> form("form[phx-change=save]", %{content: "child"}) |> render_change()
    render_hook(root, "save", %{"content" => "blocked"})
    render_hook(other, "save", %{"content" => "blocked"})

    assert ContentStore.get("/alpha") == "home"
    assert ContentStore.get("/alpha/page") == "child"
    assert ContentStore.get("/") == ""
    assert ContentStore.get("/beta") == ""
    assert ContentStore.get("/n/alpha") == ""
    assert ContentStore.get("/n/alpha/page") == ""
    assert File.read!(document_file(data_dir, "/alpha")) == "home"
    assert File.read!(document_file(data_dir, "/alpha/page")) == "child"
    refute File.exists?(document_file(data_dir, "/n/alpha"))
  end

  test "unclaimed logged-in user sees claim link instead of blank page links", %{conn: conn} do
    with_blank_page_paths(["/n/alpha/bluebird"])
    conn = logged_in(conn, "user", "user@example.com")

    {:ok, _view, html} = live(conn, ~p"/n")

    assert html =~ "Claim your page"
    assert html =~ ~s(href="/claim")
    refute html =~ "Write somewhere new"
    refute html =~ "/n/alpha/bluebird"
  end

  test "claimed user sees generated blank page links under namespace", %{conn: conn} do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    with_blank_page_paths(["bluebird", "rainriver", "moonstone", "greenfield", "sunwind"])
    conn = logged_in(conn, "owner", "owner@example.com")

    {:ok, view, _html} = live(conn, "/n/alpha")
    rendered = render(view)

    assert rendered =~ "Write somewhere new"
    assert rendered =~ ~s(href="/n/alpha/bluebird")

    links = rendered |> Floki.parse_document!() |> Floki.find("#blank-page-links a")

    assert length(links) == 5
    assert links |> Floki.text() =~ "/alpha/bluebird"
    refute links |> Floki.text() =~ "/n/alpha/bluebird"
  end

  test "generated blank page paths join exactly two dictionary words" do
    words = UnfinalWeb.EditorLive.blank_page_words()
    dictionary_pattern = Enum.join(words, "|")

    assert UnfinalWeb.EditorLive.random_blank_page_paths()
           |> Enum.all?(fn path ->
             Regex.match?(~r/^(#{dictionary_pattern})(#{dictionary_pattern})$/, path)
           end)
  end

  defp document_file(data_dir, path) do
    hash = :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)
    Path.join([data_dir, "documents", hash <> ".txt"])
  end

  defp logged_in(conn, id, email) do
    Plug.Test.init_test_session(conn,
      authenticated: true,
      exe_user: %{"id" => id, "email" => email}
    )
  end

  defp with_blank_page_paths(paths) do
    Application.put_env(:unfinal, :blank_page_path_generator, fn -> paths end)

    on_exit(fn -> Application.delete_env(:unfinal, :blank_page_path_generator) end)
  end

  defp with_writers(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "unfinal-live-writers-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, content)
    Application.put_env(:unfinal, :writers_path, path)

    on_exit(fn ->
      Application.delete_env(:unfinal, :writers_path)
      File.rm(path)
    end)
  end
end
