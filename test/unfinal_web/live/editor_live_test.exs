defmodule UnfinalWeb.EditorLiveTest do
  use UnfinalWeb.ConnCase

  alias Phoenix.LiveView.Socket
  alias Unfinal.ContentStore
  alias Unfinal.NamespaceStore

  setup do
    Application.put_env(:unfinal, :object_store_adapter, Unfinal.FakeObjectStore)
    Application.put_env(:unfinal, :content_store_flush_interval_ms, 10)
    ContentStore.clear()
    NamespaceStore.clear()

    on_exit(fn ->
      ContentStore.clear()
      NamespaceStore.clear()
      Application.delete_env(:unfinal, :content_store_flush_interval_ms)
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
    refute root_html =~ ~s(id="pages-nav")
    assert existing_html =~ "saved text"
    assert render(root) =~ "root text"
    refute render(notes) =~ "saved text"
    assert render(existing) =~ "saved text"
  end

  test "redirects trailing slash on editor root and preserves query string", %{conn: conn} do
    conn = get(conn, "/n/?draft=1")

    assert redirected_to(conn, 301) == "/n?draft=1"
  end

  test "accepts only valid document paths", %{conn: conn} do
    for path <- ["/n", "/n/alpha", "/n/alpha-1", "/n/nested/page-2"] do
      assert {:ok, _view, _html} = live(conn, path)
    end

    for path <- [
          "/n/Alpha",
          "/n/alpha_beta",
          "/n/alpha.beta",
          "/n/alpha%20beta",
          "/n/alpha//beta",
          "/n/-alpha",
          "/n/alpha-",
          "/n/.."
        ] do
      conn = get(conn, path)
      assert html_response(conn, 404)
    end
  end

  test "unauthenticated content view includes social preview metadata", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/n/notes")

    assert html =~ ~r/<title[^>]*>Unfinal<\/title>/
    assert html =~ ~s(<meta property="og:title" content="Unfinal")

    assert html =~
             ~s(<meta property="og:description" content="The anti-perfectionist blogging platform")

    assert html =~ ~s(<meta property="og:type" content="website")
    assert html =~ ~s(<meta property="og:url" content="https://unfinal.page")
    assert html =~ ~s(<meta name="twitter:card" content="summary")
    assert html =~ ~s(<meta name="twitter:title" content="Unfinal")

    assert html =~
             ~s(<meta name="twitter:description" content="The anti-perfectionist blogging platform")

    refute html =~ "Phoenix Framework"
  end

  test "unauthenticated content view shows readonly page chrome", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/n/notes")

    assert html =~ ~s(<article id="readonly-document")
    assert html =~ ~s(id="pages-nav")
    refute html =~ "<textarea"
    assert html =~ "Unfinal"
    assert html =~ ~s(id="login-bar")
    assert html =~ "Read only"
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

    assert_eventually(fn -> ContentStore.get("/").content == "root body" end)
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
    refute namespace_html =~ "phx-throttle"
    refute namespace_html =~ "phx-debounce"
    assert child_html =~ "<textarea"
    refute other_html =~ "<textarea"

    namespace |> form("form[phx-change=save]", %{content: "home"}) |> render_change()
    child |> form("form[phx-change=save]", %{content: "child"}) |> render_change()
    render_hook(root, "save", %{"content" => "blocked"})
    render_hook(other, "save", %{"content" => "blocked"})

    assert_eventually(fn -> ContentStore.get("/alpha").content == "home" end)
    assert_eventually(fn -> ContentStore.get("/alpha/page").content == "child" end)
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

  test "claimed user sees indexed pages and inline new page row under namespace", %{conn: conn} do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    :ok = Unfinal.PageIndex.upsert("alpha", "/", ~U[2026-06-23 00:00:00Z])
    :ok = Unfinal.PageIndex.upsert("alpha", "/bluebird", ~U[2026-06-24 00:00:00Z])
    :ok = Unfinal.PageIndex.upsert("alpha", "/rainriver", ~U[2026-06-25 00:00:00Z])
    conn = logged_in(conn, "different-owner-id", "owner@example.com")

    {:ok, view, html} = live(conn, "/n/alpha")

    assert html =~ ~s(href="/n/alpha/rainriver")
    assert html =~ ~s(href="/n/alpha/bluebird")

    rendered = render(view)

    assert rendered =~ "Pages"
    refute rendered =~ "Write somewhere new"
    assert rendered =~ ~s(href="/n/alpha/rainriver")
    assert rendered =~ ~s(href="/n/alpha/bluebird")
    assert rendered =~ ~s(href="/n/alpha")
    refute rendered =~ ~s(href="/n/alpha/")
    assert rendered =~ ~s(id="new-page-form")
    assert rendered =~ ~s(phx-submit="open_new_page")
    assert rendered =~ ~s(name="path")

    assert {:error, {:live_redirect, %{to: "/n/alpha/new-page"}}} =
             view |> form("#new-page-form", %{path: "new-page"}) |> render_submit()

    links = rendered |> Floki.parse_document!() |> Floki.find("#pages-nav a")
    link_hrefs = Enum.map(links, &Floki.attribute(&1, "href"))

    assert link_hrefs == [["/n/alpha"], ["/n/alpha/rainriver"], ["/n/alpha/bluebird"]]
    assert links |> Floki.text() =~ "/alpha"
    assert links |> Floki.text() =~ "/alpha/rainriver"
    refute links |> Floki.text() =~ "/n/alpha/rainriver"
  end

  test "claimed user viewing another namespace sees its pages but no new page form", %{conn: conn} do
    :ok = NamespaceStore.claim("kp", %{"id" => "owner", "email" => "owner@example.com"})
    :ok = Unfinal.PageIndex.upsert("kp", "/private", ~U[2026-06-24 00:00:00Z])
    :ok = Unfinal.PageIndex.upsert("tanay", "/", ~U[2026-06-23 00:00:00Z])
    :ok = Unfinal.PageIndex.upsert("tanay", "/edtech", ~U[2026-06-24 00:00:00Z])
    conn = logged_in(conn, "owner", "owner@example.com")

    {:ok, view, _html} = live(conn, "/n/tanay")
    rendered = render(view)

    assert rendered =~ ~s(href="/n/tanay/edtech")
    refute rendered =~ ~s(href="/n/kp/private")
    refute rendered =~ ~s(id="new-page-form")
    refute rendered =~ ~s(phx-submit="open_new_page")
    refute rendered =~ "<textarea"
  end

  test "claimed user sees indexed current page only once in sidebar", %{conn: conn} do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    :ok = Unfinal.PageIndex.upsert("alpha", "/", ~U[2026-06-23 00:00:00Z])
    :ok = Unfinal.PageIndex.upsert("alpha", "/bluebird", ~U[2026-06-24 00:00:00Z])
    :ok = Unfinal.PageIndex.upsert("alpha", "/rainriver", ~U[2026-06-25 00:00:00Z])
    conn = logged_in(conn, "different-owner-id", "owner@example.com")

    {:ok, view, _html} = live(conn, "/n/alpha/bluebird")

    rendered = render(view)

    current_page_link_count =
      rendered
      |> String.split(~s(href="/n/alpha/bluebird"))
      |> length()
      |> Kernel.-(1)

    assert current_page_link_count == 1

    links = rendered |> Floki.parse_document!() |> Floki.find("#pages-nav a")

    assert Enum.map(links, &Floki.attribute(&1, "href")) == [
             ["/n/alpha"],
             ["/n/alpha/bluebird"],
             ["/n/alpha/rainriver"]
           ]
  end

  test "claimed user viewing unindexed namespace root sees current root but child pages do not invent root",
       %{
         conn: conn
       } do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    :ok = Unfinal.PageIndex.upsert("alpha", "/bluebird", ~U[2026-06-24 00:00:00Z])
    conn = logged_in(conn, "different-owner-id", "owner@example.com")

    {:ok, root_view, _html} = live(conn, "/n/alpha")

    root_links = root_view |> render() |> Floki.parse_document!() |> Floki.find("#pages-nav a")

    assert Enum.map(root_links, &Floki.attribute(&1, "href")) == [
             ["/n/alpha"],
             ["/n/alpha/bluebird"]
           ]

    {:ok, child_view, _html} = live(conn, "/n/alpha/bluebird")

    child_links = child_view |> render() |> Floki.parse_document!() |> Floki.find("#pages-nav a")

    assert Enum.map(child_links, &Floki.attribute(&1, "href")) == [["/n/alpha/bluebird"]]
  end

  test "writer save updates namespace page index", %{conn: conn} do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    conn = logged_in(conn, "owner", "owner@example.com")

    {:ok, root_view, _html} = live(conn, "/n/alpha")
    root_view |> form("form[phx-change=save]", %{content: "root indexed"}) |> render_change()

    assert_eventually(fn -> ContentStore.get("/alpha").content == "root indexed" end)
    assert [%{path: "/"}] = Unfinal.PageIndex.list("alpha")

    {:ok, view, _html} = live(conn, "/n/alpha/notes")
    view |> form("form[phx-change=save]", %{content: "indexed"}) |> render_change()

    assert_eventually(fn -> ContentStore.get("/alpha/notes").content == "indexed" end)
    assert [%{path: "/notes"}, %{path: "/"}] = Unfinal.PageIndex.list("alpha")
  end

  test "writer save queues without echoing content or durable metadata" do
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
    assert updated_socket.assigns.saved_content == ""
    assert updated_socket.assigns.revision == 0
    assert updated_socket.assigns.etag == nil
  end

  test "writer save queues content matching previous saved content" do
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
    assert_eventually(fn -> ContentStore.get("/notes").content == "saved remotely" end)
  end

  test "writer can queue content matching stale rendered content after another queued save" do
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
    assert reverted_socket.assigns.revision == 0
    assert_eventually(fn -> ContentStore.get("/notes").content == "initial" end)
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

  test "readonly content update accepts delete tombstone despite lower revision" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        storage_path: "/notes",
        content: "old",
        etag: "old-etag",
        revision: 3
      }
    }

    assert {:noreply, updated_socket} =
             UnfinalWeb.EditorLive.handle_info(
               {:content_updated, "/notes", %{content: "", etag: nil, revision: 0}},
               socket
             )

    assert updated_socket.assigns.content == ""
    assert updated_socket.assigns.etag == nil
    assert updated_socket.assigns.revision == 0
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

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
