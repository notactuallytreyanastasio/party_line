defmodule PartyLineWeb.KeysLiveTest do
  # non-async: the LiveView process mints keys against Postgres, so it needs the
  # shared-mode sandbox connection.
  use PartyLineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "signed out, /keys offers atproto sign-in", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/keys")
    assert html =~ "Sign in with your handle"
    assert html =~ ~s(action="/oauth/login")
    # the interactive mint form only exists once signed in
    refute html =~ ~s(phx-submit="mint")
  end

  test "signed in, you can mint a key and see it once, then revoke it", %{conn: conn} do
    conn =
      Plug.Test.init_test_session(conn, %{"did" => "did:plc:me", "handle" => "me.bsky.social"})

    {:ok, view, html} = live(conn, "/keys")
    assert html =~ "me.bsky.social"
    assert html =~ "no keys yet"

    # mint — the plaintext token is shown once, and a row appears
    html = view |> form("form[phx-submit=mint]", %{label: "cli"}) |> render_submit()
    assert html =~ "shown once"
    assert html =~ "pl-"
    assert html =~ "cli"

    # revoke — the key flips to revoked
    html = view |> element("button[phx-click=revoke]") |> render_click()
    assert html =~ "revoked"
  end
end
