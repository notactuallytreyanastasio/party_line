defmodule PartyLineWeb.ToursTest do
  @moduledoc """
  A Tour step points at a CSS selector, so a tour breaks silently when the
  markup it names drifts: the spotlight just lands on nothing. These render
  each real page and assert every target is present, which turns "the tour is
  broken" from something a newcomer discovers into a failing test.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PartyLineWeb.Tours

  @endpoint PartyLineWeb.Endpoint

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  # A step's target is a CSS selector; has_element?/2 speaks CSS, so it can
  # answer the only question that matters: is that thing on the page?
  defp assert_targets(view, steps) do
    for step <- steps, target = step.target, target != nil do
      assert has_element?(view, target),
             "tour step #{inspect(step.title)} points at #{inspect(target)}, " <>
               "which is not on the page"
    end
  end

  test "every landing tour target is on the landing page", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert_targets(view, Tours.landing())
  end

  test "every boards tour target is on the boards page", %{conn: conn} do
    {:ok, _} =
      PartyLine.Boards.submit(PartyLine.Boards, %{
        board: "confessions",
        topic: "tour-topic-#{System.unique_integer([:positive])}",
        author: "Horse Dentist",
        body: "the molars knew"
      })

    {:ok, view, _html} = live(conn, "/boards")
    assert_targets(view, Tours.boards())
  end

  test "every line tour target is on the line, once you've dialed in", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/line")
    # the speak form and message pane only exist after dialing in
    view |> element("form") |> render_submit(%{name: "tour taker"})

    assert_targets(view, Tours.line())
  end

  describe "starting a tour" do
    test "the landing page offers it, and starting shows the first card", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      # nothing is showing until asked for
      refute html =~ ~s(id="tour")

      html = view |> element(~s{button[phx-click="show_me"]}) |> render_click()
      assert html =~ ~s(id="tour")
      assert html =~ "This is a party line"
      assert html =~ "1 of #{length(Tours.landing())}"
    end

    test "next walks forward, back walks back, skip closes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view |> element(~s{button[phx-click="show_me"]}) |> render_click()

      html = view |> element(~s{button[phx-click="tour:next"]}) |> render_click()
      assert html =~ "Two ways in"
      assert html =~ "2 of"

      html = view |> element(~s{button[phx-click="tour:back"]}) |> render_click()
      assert html =~ "This is a party line"

      html = view |> element(~s{button[phx-click="tour:stop"]}) |> render_click()
      refute html =~ ~s(id="tour")
    end

    test "the first step has no Back button to press", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view |> element(~s{button[phx-click="show_me"]}) |> render_click()

      refute has_element?(view, ~s{button[phx-click="tour:back"]})
    end

    test "walking off the end closes the tour", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view |> element(~s{button[phx-click="show_me"]}) |> render_click()

      html =
        Enum.reduce(Tours.landing(), nil, fn _step, _acc ->
          view |> element(~s{button[phx-click="tour:next"]}) |> render_click()
        end)

      refute html =~ ~s(id="tour")
    end
  end

  test "the boards tour rides on the boards page without touching its events", %{conn: conn} do
    uniq = System.unique_integer([:positive])

    {:ok, post} =
      PartyLine.Boards.submit(PartyLine.Boards, %{
        board: "confessions",
        topic: "tour-vote-#{uniq}",
        author: "erowid smoothie",
        body: "body-#{uniq}"
      })

    {:ok, view, _html} = live(conn, "/boards")
    view |> element(~s{button[phx-click="show_me"]}) |> render_click()

    # Tour attaches a handle_event hook to the host LiveView; the page's own
    # events must still land, or the library would be eating them
    view
    |> element(~s{button[phx-value-id="#{post.id}"][phx-value-dir="up"]})
    |> render_click()

    assert PartyLine.Boards.get(PartyLine.Boards, post.id).ups == 1
    assert has_element?(view, "#tour")
  end
end
