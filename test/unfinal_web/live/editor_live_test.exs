defmodule UnfinalWeb.EditorLiveTest do
  use UnfinalWeb.ConnCase

  alias Unfinal.ContentStore

  setup do
    ContentStore.clear()
    :ok
  end

  test "renders empty documents for root and arbitrary paths", %{conn: conn} do
    ContentStore.set("/existing", "saved text")

    {:ok, root, root_html} = live(conn, ~p"/")
    {:ok, notes, notes_html} = live(conn, "/notes")
    {:ok, existing, existing_html} = live(conn, "/existing")

    assert root_html =~ ~s(<article id="readonly-document")
    assert notes_html =~ ~s(<article id="readonly-document")
    assert existing_html =~ "saved text"
    refute render(root) =~ "saved text"
    refute render(notes) =~ "saved text"
    assert render(existing) =~ "saved text"
  end

  test "unauthenticated content view shows readonly page chrome", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/notes")

    assert html =~ ~s(<article id="readonly-document")
    assert html =~ ~s(border border-stone-200)
    refute html =~ "<textarea"
    refute html =~ ~s(readonly="readonly")
    assert html =~ "Unfinal"
    refute html =~ "If text exists, it is already out there."
    assert html =~ ~s(<footer id="login-bar")
    refute html =~ "Document /notes"
    assert html =~ "readonly live view"
    assert html =~ "Login to edit"
    assert html =~ ~s(href="/login?return_to=%2Fnotes")
  end

  test "readonly document does not add template whitespace to content", %{conn: conn} do
    ContentStore.set("/plain", "hello")

    {:ok, _view, html} = live(conn, "/plain")

    assert html =~ ~r/<article[^>]*id="readonly-document"[^>]*>hello<\/article>/
  end

  test "authenticated writer textarea is editable", %{conn: conn} do
    with_writers("writer@example.com")

    conn =
      Plug.Test.init_test_session(conn,
        authenticated: true,
        exe_user: %{"email" => "writer@example.com"}
      )

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "<textarea"
    refute html =~ ~s(readonly="readonly")
    assert html =~ "live editing"
    assert html =~ "Logged in as writer@example.com •"
    assert html =~ ~s(class="inline-flex items-center gap-1 whitespace-nowrap")
    assert html =~ ~s(id="logout-link")
    assert html =~ ~s(href="/logout?return_to=%2F")
    assert html =~ "Logout"
  end

  test "blank page links are hidden when unauthenticated", %{conn: conn} do
    with_blank_page_paths(["/bluebird", "/rainriver", "/moonstone", "/greenfield", "/sunwind"])

    {:ok, _view, html} = live(conn, ~p"/")

    refute html =~ ~s(id="blank-page-links")
    refute html =~ "/bluebird"
  end

  test "blank page links not rendered in disconnected (static) mount for authenticated writer",
       %{conn: conn} do
    with_writers("writer@example.com")
    with_blank_page_paths(["/bluebird", "/rainriver", "/moonstone", "/greenfield", "/sunwind"])

    conn =
      Plug.Test.init_test_session(conn,
        authenticated: true,
        exe_user: %{"email" => "writer@example.com"}
      )

    html =
      conn
      |> get(~p"/")
      |> html_response(200)

    # Disconnected (static) mount must not render blank-page links
    refute html =~ ~s(id="blank-page-links")
    refute html =~ "/bluebird"
  end

  test "homepage shows five non-mobile blank page links for authenticated writer after connect",
       %{conn: conn} do
    with_writers("writer@example.com")
    with_blank_page_paths(["/bluebird", "/rainriver", "/moonstone", "/greenfield", "/sunwind"])

    conn =
      Plug.Test.init_test_session(conn,
        authenticated: true,
        exe_user: %{"email" => "writer@example.com"}
      )

    {:ok, view, _html} = live(conn, ~p"/")
    rendered = render(view)

    assert rendered =~ ~s(<aside id="blank-page-links")
    assert rendered =~ ~s(class="hidden py-6 text-left text-sm text-stone-600 lg:block")
    assert rendered =~ ~s(href="/bluebird")
    assert rendered =~ ~s(href="/rainriver")
    assert rendered =~ ~s(href="/moonstone")
    assert rendered =~ ~s(href="/greenfield")
    assert rendered =~ ~s(href="/sunwind")

    assert rendered |> Floki.parse_document!() |> Floki.find("#blank-page-links a") |> length() ==
             5
  end

  test "generated blank page paths join exactly two dictionary words", %{conn: _conn} do
    words = UnfinalWeb.EditorLive.blank_page_words()
    dictionary_pattern = Enum.join(words, "|")

    assert UnfinalWeb.EditorLive.random_blank_page_paths()
           |> Enum.all?(fn path ->
             Regex.match?(~r/^\/(#{dictionary_pattern})(#{dictionary_pattern})$/, path)
           end)
  end

  test "blank page links are homepage only", %{conn: conn} do
    with_writers("writer@example.com")
    with_blank_page_paths(["/bluebird", "/rainriver", "/moonstone", "/greenfield", "/sunwind"])

    conn =
      Plug.Test.init_test_session(conn,
        authenticated: true,
        exe_user: %{"email" => "writer@example.com"}
      )

    {:ok, _view, html} = live(conn, "/notes")

    refute html =~ ~s(id="blank-page-links")
    refute html =~ "/bluebird"
  end

  test "authenticated non-writer sees content view", %{conn: conn} do
    with_writers("writer@example.com")

    conn =
      Plug.Test.init_test_session(conn,
        authenticated: true,
        exe_user: %{"email" => "other@example.com"}
      )

    {:ok, view, html} = live(conn, "/non-writer")

    assert html =~ ~s(<article id="readonly-document")
    refute html =~ "<textarea"
    refute html =~ ~s(readonly="readonly")
    assert html =~ "Logged in as other@example.com •"
    assert html =~ ~s(class="inline-flex items-center gap-1 whitespace-nowrap")
    assert html =~ ~s(id="logout-link")
    assert html =~ ~s(href="/logout?return_to=%2Fnon-writer")
    assert html =~ "Logout"

    render_hook(view, "save", %{"content" => "blocked"})
    assert ContentStore.get("/non-writer") == ""
  end

  test "authenticated writer edits persist only for current path and update matching viewers", %{
    conn: conn
  } do
    with_writers("writer@example.com")

    conn =
      Plug.Test.init_test_session(conn,
        authenticated: true,
        exe_user: %{"email" => "writer@example.com"}
      )

    {:ok, notes_editor, _html} = live(conn, "/notes")
    {:ok, notes_viewer, _html} = live(conn, "/notes")
    {:ok, other_viewer, _html} = live(conn, "/other")

    notes_editor
    |> form("form[phx-change=save]", %{content: "notes body"})
    |> render_change()

    assert ContentStore.get("/notes") == "notes body"
    assert ContentStore.get("/other") == ""
    assert render(notes_viewer) =~ "notes body"
    refute render(other_viewer) =~ "notes body"
  end

  defp with_blank_page_paths(paths) do
    Application.put_env(:unfinal, :blank_page_path_generator, fn -> paths end)

    on_exit(fn ->
      Application.delete_env(:unfinal, :blank_page_path_generator)
    end)
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
