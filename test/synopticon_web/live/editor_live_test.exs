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

  test "unauthenticated textarea is readonly", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "<textarea"
    assert html =~ ~s(readonly="readonly")
  end

  test "authenticated textarea is editable", %{conn: conn} do
    conn = Plug.Test.init_test_session(conn, authenticated: true)

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "<textarea"
    refute html =~ ~s(readonly="readonly")
  end

  test "authenticated edits persist only for current path and update matching viewers", %{
    conn: conn
  } do
    conn = Plug.Test.init_test_session(conn, authenticated: true)

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
end
