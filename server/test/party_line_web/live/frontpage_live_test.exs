defmodule PartyLineWeb.FrontpageLiveTest do
  @moduledoc """
  The boards' public face: the frontpage feed, per-board views, permalinks,
  and live voting over PubSub.

  These drive the app-started `PartyLine.Boards` server, which is in-memory and
  shared across the app, so every post uses run-unique bodies/topics to stay
  independent — the same accepted trade-off as the clips wall tests.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PartyLine.Boards

  @endpoint PartyLineWeb.Endpoint

  setup do
    PartyLine.DataCase.checkout_singletons!()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  # the net score rendered in a post's votebox: the span right after the
  # up-arrow button carrying this post id ([^>]* keeps us inside that tag)
  defp score_for(html, id) do
    [_, score] =
      Regex.run(
        ~r{phx-value-id="#{id}"[^>]*>\s*▲\s*</button>\s*<span class="retro-votescore">(-?\d+)</span>},
        html
      )

    String.to_integer(score)
  end

  defp submit!(uniq, board \\ "confessions") do
    {:ok, post} =
      Boards.submit(%{
        board: board,
        topic: "frontpage-topic-#{uniq}",
        author: "erowid smoothie",
        body: "frontpage-body-#{uniq}"
      })

    post
  end

  test "a submitted post renders in the hot feed", %{conn: conn} do
    uniq = System.unique_integer([:positive])
    post = submit!(uniq)

    {:ok, _view, html} = live(conn, "/boards")
    assert html =~ "the boards"
    assert html =~ post.topic
    assert html =~ post.body
    assert html =~ "erowid smoothie"
    assert html =~ "confessions"
  end

  test "board views scope the feed; an empty board says so", %{conn: conn} do
    uniq = System.unique_integer([:positive])
    post = submit!(uniq, "confessions")

    {:ok, _view, html} = live(conn, "/boards/b/confessions")
    assert html =~ post.body

    {:ok, _view, html} = live(conn, "/boards/b/questions")
    refute html =~ post.body

    # a board nobody has ever posted on renders the empty state
    {:ok, _view, html} = live(conn, "/boards/b/empty-board-#{uniq}")
    assert html =~ "no posts here yet"
  end

  test "permalink renders the full post; unknown ids get the not-found view", %{conn: conn} do
    uniq = System.unique_integer([:positive])
    post = submit!(uniq)

    {:ok, _view, html} = live(conn, "/boards/#{post.id}")
    assert html =~ post.topic
    assert html =~ post.body
    assert html =~ "permalink"

    {:ok, _view, html} = live(conn, "/boards/no-such-post-#{uniq}")
    assert html =~ "not found"
  end

  test "voting up from the feed tallies live and toggles off", %{conn: conn} do
    uniq = System.unique_integer([:positive])
    post = submit!(uniq)

    {:ok, view, _html} = live(conn, "/boards")
    up = ~s{button[phx-value-id="#{post.id}"][phx-value-dir="up"]}

    view |> element(up) |> render_click()

    # the PubSub {:boards, _} broadcast lands before the vote call returns,
    # so the next render already reflects the refreshed listing
    assert has_element?(view, "#{up}.is-up")
    assert score_for(render(view), post.id) == 1
    assert Boards.get(post.id).ups == 1

    # same direction again clears the vote (Core toggle semantics)
    view |> element(up) |> render_click()
    refute has_element?(view, "#{up}.is-up")
    assert score_for(render(view), post.id) == 0
    assert Boards.get(post.id).ups == 0
  end

  test "the voter identity survives a reload on the same session", %{conn: conn} do
    uniq = System.unique_integer([:positive])
    post = submit!(uniq)
    up = ~s{button[phx-value-id="#{post.id}"][phx-value-dir="up"]}

    # dispatch a real GET first so the conn carries the Voter plug's session
    # cookie in its response — ConnTest only recycles an already-sent conn
    conn = get(conn, "/boards")
    {:ok, view, _html} = live(conn)
    view |> element(up) |> render_click()
    assert has_element?(view, "#{up}.is-up")

    # a second visit on the now-dispatched conn recycles the session cookie,
    # so the Voter plug's existing-session branch hands back the same voter id
    {:ok, view2, _html} = live(conn, "/boards")
    assert has_element?(view2, "#{up}.is-up")
  end

  test "the show view updates live when someone else votes", %{conn: conn} do
    uniq = System.unique_integer([:positive])
    post = submit!(uniq)

    {:ok, view, html} = live(conn, "/boards/#{post.id}")
    assert score_for(html, post.id) == 0

    {:ok, _} = Boards.vote("other-voter-#{uniq}", post.id, :up)

    assert score_for(render(view), post.id) == 1
  end

  describe "comments" do
    test "a human can comment on a post and it renders live", %{conn: conn} do
      uniq = System.unique_integer([:positive])

      {:ok, post} =
        Boards.submit(Boards, %{
          board: "confessions",
          topic: "comment-topic-#{uniq}",
          author: "Horse Dentist",
          body: "the molars knew"
        })

      {:ok, view, html} = live(conn, "/boards/#{post.id}")
      assert html =~ "nobody&#39;s weighed in yet"

      body = "big if true #{uniq}"
      view |> element("form[phx-submit=\"comment\"]") |> render_submit(%{body: body})

      html = render(view)
      assert html =~ body
      assert html =~ "1 comment"
      refute html =~ "nobody&#39;s weighed in yet"
    end

    test "a comment from someone else shows up live over PubSub", %{conn: conn} do
      uniq = System.unique_integer([:positive])

      {:ok, post} =
        Boards.submit(Boards, %{
          board: "sagas",
          topic: "live-comment-#{uniq}",
          author: "erowid smoothie",
          body: "part one of many"
        })

      {:ok, view, _html} = live(conn, "/boards/#{post.id}")

      # a bot (or another tab) comments — the open permalink must update
      {:ok, _} =
        Boards.comment(Boards, %{
          post_id: post.id,
          author: "DigimonOtis",
          body: "raccoon-adjacent take #{uniq}"
        })

      assert render(view) =~ "raccoon-adjacent take #{uniq}"
      assert render(view) =~ "DigimonOtis"
    end

    test "the feed shows a comment count that updates", %{conn: conn} do
      uniq = System.unique_integer([:positive])

      {:ok, post} =
        Boards.submit(Boards, %{
          board: "trivia",
          topic: "feed-count-#{uniq}",
          author: "Beef Inspector",
          body: "did you know"
        })

      {:ok, view, _html} = live(conn, "/boards/b/trivia")
      # the row's comment chip starts at 0 and reflects new comments live
      {:ok, _} = Boards.comment(Boards, %{post_id: post.id, author: "x", body: "first!"})

      assert render(view) =~ "💬 1"
    end
  end
end
