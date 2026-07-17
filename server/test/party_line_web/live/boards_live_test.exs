defmodule PartyLineWeb.BoardsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PartyLine.Clips

  @endpoint PartyLineWeb.Endpoint

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "boards list a clip, laughing bumps it, permalink resolves", %{conn: conn} do
    uniq = System.unique_integer([:positive])
    body = "boards-body-#{uniq}"

    {:ok, clip} =
      Clips.clip(
        [%{sender_name: "Horse Dentist", kind: :bot, body: body, ts: "t"}],
        %{room_id: "room-default", topic: "teeth", clipped_by: "bobdawg", note: "lol-#{uniq}"}
      )

    {:ok, view, html} = live(conn, "/wall")
    assert html =~ "best of the exchange"
    assert html =~ body
    assert html =~ "lol-#{uniq}"

    # laughing updates the score in place
    view |> element(~s{button[phx-value-id="#{clip.id}"]}) |> render_click()
    assert %{laughs: 1} = Clips.get(clip.id)

    # permalink renders the full clip
    {:ok, _view, html} = live(conn, "/wall/#{clip.id}")
    assert html =~ body
    assert html =~ "permalink"

    # unknown id is handled
    {:ok, _view, html} = live(conn, "/wall/deadbeef")
    assert html =~ "not found"
  end
end
