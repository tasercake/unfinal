defmodule UnfinalWeb.EditorLiveTest do
  use UnfinalWeb.ConnCase

  alias Phoenix.LiveView.Socket
  alias Unfinal.ContentStore
  alias Unfinal.NamespaceStore

  setup do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FakeObjectStore)
    ContentStore.clear()
    NamespaceStore.clear()

    on_exit(fn ->
      ContentStore.clear()
      NamespaceStore.clear()
    end)

    :ok
  end

  test "redirects slash to /n and renders storage paths without /n prefix", %{conn: conn} do
    save_document("/", "root text")
    save_document("/existing", "saved text")

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
    save_document("/plain", "hello")

    {:ok, _view, html} = live(conn, "/n/plain")

    assert html =~ ~r/<article[^>]*id="readonly-document"[^>]*>hello<\/article>/
  end

  test "superuser edits only /n root", %{conn: conn} do
    with_writers("writer@example.com")
    conn = logged_in(conn, "writer", "writer@example.com")

    {:ok, root, root_html} = live(conn, ~p"/n")
    {:ok, child, child_html} = live(conn, "/n/alpha")

    assert root_html =~ "<textarea"
    refute child_html =~ "<textarea"

    root |> form("form[phx-change=save]", %{content: "root body"}) |> render_change()
    render_hook(child, "save", %{"content" => "blocked"})

    assert ContentStore.get("/").content == "root body"
    assert ContentStore.get("/n").content == ""
    assert ContentStore.get("/alpha").content == ""
  end

  test "namespace owner edits own namespace and descendants but not root", %{conn: conn} do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    conn = logged_in(conn, "different-owner-id", "owner@example.com")

    {:ok, root, root_html} = live(conn, ~p"/n")
    {:ok, namespace, namespace_html} = live(conn, "/n/alpha")
    {:ok, child, child_html} = live(conn, "/n/alpha/page")
    {:ok, other, other_html} = live(conn, "/n/beta")

    refute root_html =~ "<textarea"
    assert namespace_html =~ "<textarea"
    assert namespace_html =~ ~s(phx-throttle="500")
    assert child_html =~ "<textarea"
    refute other_html =~ "<textarea"

    namespace |> form("form[phx-change=save]", %{content: "home"}) |> render_change()
    child |> form("form[phx-change=save]", %{content: "child"}) |> render_change()
    render_hook(root, "save", %{"content" => "blocked"})
    render_hook(other, "save", %{"content" => "blocked"})

    assert ContentStore.get("/alpha").content == "home"
    assert ContentStore.get("/alpha/page").content == "child"
    assert ContentStore.get("/").content == ""
    assert ContentStore.get("/beta").content == ""
    assert ContentStore.get("/n/alpha").content == ""
    assert ContentStore.get("/n/alpha/page").content == ""
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
    conn = logged_in(conn, "different-owner-id", "owner@example.com")

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

  test "writer save success updates etag and revision without assigning saved content" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        writer?: true,
        storage_path: "/notes",
        content: "local draft",
        saved_content: "",
        etag: nil,
        revision: 0
      }
    }

    assert {:noreply, updated_socket} =
             UnfinalWeb.EditorLive.handle_event("save", %{"content" => "saved remotely"}, socket)

    assert updated_socket.assigns.content == "local draft"
    assert updated_socket.assigns.saved_content == "saved remotely"
    assert updated_socket.assigns.revision == 1
    assert is_binary(updated_socket.assigns.etag)
  end

  test "writer save skips no-op content using last saved content, not rendered content" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        writer?: true,
        storage_path: "/notes",
        content: "local draft",
        saved_content: "saved remotely",
        etag: "etag-1",
        revision: 1
      }
    }

    assert {:noreply, unchanged_socket} =
             UnfinalWeb.EditorLive.handle_event("save", %{"content" => "saved remotely"}, socket)

    assert unchanged_socket == socket
  end

  test "writer can save content matching stale rendered content after another successful save" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        writer?: true,
        storage_path: "/notes",
        content: "initial",
        saved_content: "initial",
        etag: nil,
        revision: 0
      }
    }

    assert {:noreply, saved_socket} =
             UnfinalWeb.EditorLive.handle_event("save", %{"content" => "changed"}, socket)

    assert {:noreply, reverted_socket} =
             UnfinalWeb.EditorLive.handle_event("save", %{"content" => "initial"}, saved_socket)

    assert reverted_socket.assigns.content == "initial"
    assert reverted_socket.assigns.saved_content == "initial"
    assert reverted_socket.assigns.revision == 2
    assert ContentStore.get("/notes").content == "initial"
  end

  test "readonly content update uses PubSub payload without reading object store" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        storage_path: "/notes",
        content: "old",
        saved_content: "old",
        etag: "old",
        revision: 1
      }
    }

    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FailingObjectStore)

    assert {:noreply, updated_socket} =
             UnfinalWeb.EditorLive.handle_info(
               {:content_updated, "/notes", %{content: "new", etag: "new-etag", revision: 2}},
               socket
             )

    assert updated_socket.assigns.content == "new"
    assert updated_socket.assigns.etag == "new-etag"
    assert updated_socket.assigns.revision == 2
  end

  defp save_document(path, content) do
    base = ContentStore.get(path)
    assert {:ok, _document} = ContentStore.put(path, content, base.etag, base.revision)
  end

  defp logged_in(conn, id, email) do
    Plug.Test.init_test_session(conn,
      authenticated: true,
      user: %{"id" => id, "email" => email}
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
