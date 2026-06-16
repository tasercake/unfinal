defmodule SynopticonWeb.EditorLiveTest do
  use SynopticonWeb.ConnCase

  alias Synopticon.ContentStore

  setup do
    ContentStore.clear()
    :ok
  end

  test "renders empty documents for root and arbitrary paths", %{conn: conn} do
    ContentStore.set("/existing", "saved text")

    {:ok, root, root_html} = live(conn, ~p"/")
    {:ok, notes, notes_html} = live(conn, "/notes")
    {:ok, existing, existing_html} = live(conn, "/existing")

    assert root_html =~ "<textarea"
    assert notes_html =~ "<textarea"
    assert existing_html =~ "saved text"
    refute render(root) =~ "saved text"
    refute render(notes) =~ "saved text"
    assert render(existing) =~ "saved text"
  end

  test "unauthenticated textarea is readonly and shows readonly page chrome", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/notes")

    assert html =~ "<textarea"
    assert html =~ ~s(readonly="readonly")
    assert html =~ "Synopticon"
    refute html =~ "If text exists, it is already out there."
    assert html =~ ~s(<footer id="login-bar")
    assert html =~ "Document /notes"
    assert html =~ "readonly live view"
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
  end

  test "authenticated non-writer textarea is readonly", %{conn: conn} do
    with_writers("writer@example.com")

    conn =
      Plug.Test.init_test_session(conn,
        authenticated: true,
        exe_user: %{"email" => "other@example.com"}
      )

    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "<textarea"
    assert html =~ ~s(readonly="readonly")

    render_hook(view, "save", %{"content" => "blocked"})
    assert ContentStore.get("/") == ""
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

  defp with_writers(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "synopticon-live-writers-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, content)
    Application.put_env(:synopticon, :writers_path, path)

    on_exit(fn ->
      Application.delete_env(:synopticon, :writers_path)
      File.rm(path)
    end)
  end
end
