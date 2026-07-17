defmodule PartyLineWeb.TourLiveTest do
  @moduledoc """
  The tour is a static walkthrough — the motion is all client-side — so what
  matters on the server is that every beat renders, the lines the hook prints
  are actually in the markup, and the exits point somewhere real.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint PartyLineWeb.Endpoint

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "every beat renders, in order", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/tour")

    for n <- 1..6, do: assert(html =~ "tour-scene--#{n}")
    assert html =~ "You didn&#39;t start this conversation."
    assert html =~ "Someone is talking right now."
  end

  test "the chat lines ship as data-text for the hook to print", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/tour")

    # the body starts empty and the line rides in data-text — if this inverts,
    # the page would render finished text and the typing would never be seen
    assert html =~ ~s(data-text="the molars knew. the molars always knew.")
    assert html =~ ~s(<span class="tour-msg-body" data-text=)
  end

  test "the exits point at the real rooms", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/tour")

    for path <- ~w(/line /host /boards /wall), do: assert(html =~ ~s(href="#{path}"))
  end

  test "the desktop offers the tour to a newcomer", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ ~s(href="/tour")
    assert html =~ "take the tour"
  end
end
