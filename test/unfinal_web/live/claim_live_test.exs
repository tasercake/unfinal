defmodule UnfinalWeb.ClaimLiveTest do
  use UnfinalWeb.ConnCase

  alias Unfinal.NamespaceStore

  setup do
    previous_data_dir = System.get_env("UNFINAL_DATA_DIR")

    data_dir =
      Path.join(System.tmp_dir!(), "unfinal-claim-live-#{System.unique_integer([:positive])}")

    System.put_env("UNFINAL_DATA_DIR", data_dir)
    File.rm_rf!(data_dir)
    NamespaceStore.clear()

    on_exit(fn ->
      NamespaceStore.clear()
      File.rm_rf!(data_dir)

      if previous_data_dir do
        System.put_env("UNFINAL_DATA_DIR", previous_data_dir)
      else
        System.delete_env("UNFINAL_DATA_DIR")
      end
    end)

    :ok
  end

  test "requires login", %{conn: conn} do
    {:error, {:redirect, %{to: to}}} = live(conn, ~p"/claim")
    assert to == ~p"/login?return_to=/claim"
  end

  test "shows taken namespace while typing and rejects invalid values", %{conn: conn} do
    :ok = NamespaceStore.claim("taken", %{"id" => "other", "email" => "other@example.com"})

    conn = logged_in(conn, "user-1", "one@example.com")
    {:ok, view, html} = live(conn, ~p"/claim")

    assert html =~ "Claim your page"

    assert render_change(view, "validate", %{"claim" => %{"namespace" => "taken"}}) =~
             "already taken"

    assert render_change(view, "validate", %{"claim" => %{"namespace" => "Bad-Name"}}) =~
             "lowercase letters, numbers, and hyphens"
  end

  test "claims namespace and redirects to its root", %{conn: conn} do
    conn = logged_in(conn, "user-1", "one@example.com")
    {:ok, view, _html} = live(conn, ~p"/claim")

    assert {:error, {:redirect, %{to: "/n/alpha1"}}} =
             view
             |> form("#claim-form", claim: %{namespace: "alpha1"})
             |> render_submit()

    assert NamespaceStore.namespace_for_email("one@example.com") == "alpha1"
  end

  test "already claimed emails cannot change namespace", %{conn: conn} do
    :ok = NamespaceStore.claim("alpha", %{"id" => "user-1", "email" => "one@example.com"})

    conn = logged_in(conn, "different-user-id", "one@example.com")
    {:ok, _view, html} = live(conn, ~p"/claim")

    assert html =~ "You already claimed"
    assert html =~ "/n/alpha"
    refute html =~ ~s(id="claim-form")
  end

  defp logged_in(conn, id, email) do
    Plug.Test.init_test_session(conn,
      authenticated: true,
      user: %{"id" => id, "email" => email}
    )
  end
end
