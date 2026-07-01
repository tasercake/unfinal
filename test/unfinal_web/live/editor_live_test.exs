defmodule UnfinalWeb.EditorLiveTest do
  use UnfinalWeb.ConnCase

  alias Phoenix.LiveView.Socket
  alias Unfinal.Documents
  alias Unfinal.NamespaceStore
  alias Unfinal.SQLiteCleanup
  alias Unfinal.SqliteDocuments

  setup do
    Application.put_env(:unfinal, :storage_mode, :sqlite)
    Application.put_env(:unfinal, :content_store_flush_interval_ms, 10)
    SQLiteCleanup.clear_all()
    Documents.clear()

    on_exit(fn ->
      SQLiteCleanup.clear_all()
      Documents.clear()
      Application.delete_env(:unfinal, :content_store_flush_interval_ms)
      Application.delete_env(:unfinal, :storage_mode)
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

    assert_eventually(fn -> Documents.get("/").content == "root body" end)
    assert Documents.get("/n").content == ""
    assert Documents.get("/alpha").content == ""
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

    assert_eventually(fn -> Documents.get("/alpha").content == "home" end)
    assert_eventually(fn -> Documents.get("/alpha/page").content == "child" end)
    assert Documents.get("/").content == ""
    assert Documents.get("/beta").content == ""
    assert Documents.get("/n/alpha").content == ""
    assert Documents.get("/n/alpha/page").content == ""
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
             ["/n/alpha/rainriver"],
             ["/n/alpha/bluebird"]
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

    assert_eventually(fn -> Documents.get("/alpha").content == "root indexed" end)
    assert [%{path: "/"}] = Unfinal.PageIndex.list("alpha")

    {:ok, view, _html} = live(conn, "/n/alpha/notes")
    view |> form("form[phx-change=save]", %{content: "indexed"}) |> render_change()

    assert_eventually(fn -> Documents.get("/alpha/notes").content == "indexed" end)
    assert [%{path: "/notes"}, %{path: "/"}] = Unfinal.PageIndex.list("alpha")
  end

  test "writer save ack is fast and document persists through SQLite", %{conn: conn} do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    conn = logged_in(conn, "owner", "owner@example.com")

    {:ok, view, _html} = live(conn, "/n/alpha/fast")

    started_at = System.monotonic_time(:millisecond)
    view |> form("form[phx-change=save]", %{content: "fast ack"}) |> render_change()
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 100
    assert_eventually(fn -> Documents.get("/alpha/fast").content == "fast ack" end)
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
    assert_eventually(fn -> Documents.get("/notes").content == "saved remotely" end)
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
    assert_eventually(fn -> Documents.get("/notes").content == "initial" end)
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

  # ── Delete document tests ─────────────────────────────────────────────────────

  test "namespace owner can delete a non-root document", %{conn: conn} do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    save_document("/alpha/notes", "my notes")
    conn = logged_in(conn, "owner", "owner@example.com")

    {:ok, view, _html} = live(conn, "/n/alpha")

    assert Documents.get("/alpha/notes").content == "my notes"

    # Click the trash icon to show confirmation
    html =
      view
      |> element("button[phx-click='confirm_delete'][phx-value-path='/n/alpha/notes']")
      |> render_click()

    assert html =~ "Permanently delete"

    # Confirm the deletion
    {:error, {:live_redirect, %{to: redirect_to}}} =
      view
      |> element("button[phx-click='delete_page'][phx-value-path='/n/alpha/notes']")
      |> render_click()

    assert redirect_to == "/n/alpha"

    # Document is deleted from storage
    assert Documents.get("/alpha/notes").content == ""
    assert Documents.get("/alpha/notes").revision == 0

    # Document is removed from page index
    page_paths = Unfinal.PageIndex.list("alpha")
    refute Enum.any?(page_paths, &(&1.path == "/notes"))
  end

  test "delete button is not shown to non-owner", %{conn: conn} do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    :ok = Unfinal.PageIndex.upsert("alpha", "/notes", ~U[2026-06-24 00:00:00Z])
    conn = logged_in(conn, "other", "other@example.com")

    {:ok, _view, html} = live(conn, "/n/alpha")

    refute html =~ "confirm_delete"
    refute html =~ "hero-trash-solid"
  end

  test "non-owner cannot delete another user's document" do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    save_document("/alpha/notes", "private notes")

    # Non-owner uses Documents.delete directly
    assert {:error, :not_authorized} = Documents.delete("/alpha/notes", "other@example.com")
    assert Documents.get("/alpha/notes").content == "private notes"
  end

  test "cannot delete namespace root document" do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    save_document("/alpha", "root content")

    # Direct API call
    assert {:error, :cannot_delete_root} = Documents.delete("/alpha", "owner@example.com")
    assert Documents.get("/alpha").content == "root content"
  end

  test "root page in sidebar has no delete button for owner", %{conn: conn} do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    :ok = Unfinal.PageIndex.upsert("alpha", "/", ~U[2026-06-23 00:00:00Z])
    :ok = Unfinal.PageIndex.upsert("alpha", "/notes", ~U[2026-06-24 00:00:00Z])
    conn = logged_in(conn, "owner", "owner@example.com")

    {:ok, _view, html} = live(conn, "/n/alpha")

    # Root link (/n/alpha) is rendered as a plain <a> without a delete button in the same element
    # Non-root links have delete buttons - verify delete buttons exist for non-root pages
    assert html =~ ~s(phx-click="confirm_delete")
    assert html =~ ~s(phx-value-path="/n/alpha/notes")

    # The root link does NOT appear in a div with confirm_delete; it's a plain <a>
    # Parse and verify the root link is a standalone element, not inside a group
    parsed = Floki.parse_document!(html)
    root_links = Floki.find(parsed, "a[href='/n/alpha']")
    assert length(root_links) >= 1
    # Verify no confirm_delete button targets the root path
    delete_buttons = Floki.find(parsed, "button[phx-value-path='/n/alpha']")
    assert delete_buttons == []
  end

  test "can create a new document at the same path after deletion", %{conn: conn} do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    save_document("/alpha/notes", "original content")
    conn = logged_in(conn, "owner", "owner@example.com")

    {:ok, view, _html} = live(conn, "/n/alpha")

    # Delete: confirm_delete then delete_page
    view
    |> element("button[phx-click='confirm_delete'][phx-value-path='/n/alpha/notes']")
    |> render_click()

    {:error, {:live_redirect, _}} =
      view
      |> element("button[phx-click='delete_page'][phx-value-path='/n/alpha/notes']")
      |> render_click()

    assert_eventually(fn -> Documents.get("/alpha/notes").content == "" end)

    # Create a new document at the same path
    {:ok, new_view, _html} = live(conn, "/n/alpha/notes")
    new_view |> form("form[phx-change=save]", %{content: "new content"}) |> render_change()

    assert_eventually(fn -> Documents.get("/alpha/notes").content == "new content" end)
  end

  test "deleting current page redirects to namespace root", %{conn: conn} do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    save_document("/alpha/notes", "notes")
    conn = logged_in(conn, "owner", "owner@example.com")

    {:ok, view, _html} = live(conn, "/n/alpha/notes")

    view
    |> element("button[phx-click='confirm_delete'][phx-value-path='/n/alpha/notes']")
    |> render_click()

    {:error, {:live_redirect, %{to: redirect_to}}} =
      view
      |> element("button[phx-click='delete_page'][phx-value-path='/n/alpha/notes']")
      |> render_click()

    assert redirect_to == "/n/alpha"
  end

  test "deleting a page from sidebar while viewing another page", %{conn: conn} do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    save_document("/alpha/home", "home")
    save_document("/alpha/notes", "notes")
    conn = logged_in(conn, "owner", "owner@example.com")

    {:ok, view, _html} = live(conn, "/n/alpha/home")

    view
    |> element("button[phx-click='confirm_delete'][phx-value-path='/n/alpha/notes']")
    |> render_click()

    {:error, {:live_redirect, %{to: redirect_to}}} =
      view
      |> element("button[phx-click='delete_page'][phx-value-path='/n/alpha/notes']")
      |> render_click()

    # Always redirects to namespace root after delete
    assert redirect_to == "/n/alpha"
    assert Documents.get("/alpha/notes").content == ""
    assert Documents.get("/alpha/home").content == "home"
  end

  test "delete confirmation dialog shows page name and can be cancelled", %{conn: conn} do
    :ok = NamespaceStore.claim("alpha", %{"id" => "owner", "email" => "owner@example.com"})
    :ok = Unfinal.PageIndex.upsert("alpha", "/notes", ~U[2026-06-24 00:00:00Z])
    conn = logged_in(conn, "owner", "owner@example.com")

    {:ok, view, _html} = live(conn, "/n/alpha")

    # Click trash icon to show confirmation
    html =
      view
      |> element("button[phx-click='confirm_delete'][phx-value-path='/n/alpha/notes']")
      |> render_click()

    assert html =~ "Permanently delete"
    assert html =~ "/alpha/notes"
    assert html =~ ~s(phx-click="cancel_delete")
    assert html =~ ~s(phx-click="delete_page")

    # Cancel the dialog
    html = view |> element("button[phx-click='cancel_delete']") |> render_click()
    refute html =~ "Permanently delete"
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
    # Use SqliteDocuments.put for namespace-relative paths; insert directly for root
    case SqliteDocuments.put(path, content, nil, 0) do
      {:ok, _doc} ->
        :ok

      :ignored ->
        # Root path "/" is ignored by SqliteDocuments; insert directly
        now_iso = DateTime.to_iso8601(DateTime.utc_now())

        Unfinal.Repo.query(
          "INSERT OR REPLACE INTO documents(path, namespace, relative_path, content, revision, updated_at) VALUES(?1, ?2, ?3, ?4, 1, ?5)",
          [path, path, "/", content, now_iso],
          timeout: 5_000
        )

        :ok

      {:error, reason} ->
        flunk("save_document failed: #{inspect(reason)}")
    end
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
