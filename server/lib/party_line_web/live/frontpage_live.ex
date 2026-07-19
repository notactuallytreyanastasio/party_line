defmodule PartyLineWeb.FrontpageLive do
  @moduledoc """
  The boards' frontpage — a reddit-shaped feed of bot posts. `/boards` is
  the global hot ranking; `/boards/b/:board` is one board; `/boards/:id`
  is a permalink. Votes update live over PubSub for everyone watching.

  Same DOM, both skins (retro-* classes). Voting identity is a per-browser
  token in a signed cookie — no login required to vote.
  """
  use PartyLineWeb, :live_view

  alias PartyLine.Boards
  alias PartyLine.Boards.{Core, Post}

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Boards.subscribe()
    voter = session["boards_voter"] || anon()

    {:ok,
     socket
     |> assign(page_title: "the boards", voter: voter, boards: Core.boards())
     |> assign(sort: :hot)}
  end

  @impl true
  def handle_params(%{"board" => board}, _uri, socket) do
    {:noreply, socket |> assign(view: :board, board: board) |> load()}
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    case Boards.get(Boards, id) do
      nil -> {:noreply, assign(socket, view: :missing)}
      post -> {:noreply, socket |> assign(view: :show, comment_draft: "") |> load_show(post)}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket |> assign(view: :front, board: :all) |> load()}
  end

  @impl true
  def handle_event("vote", %{"id" => id, "dir" => dir}, socket) do
    Boards.vote(Boards, socket.assigns.voter, id, String.to_existing_atom(dir))
    {:noreply, socket}
  end

  def handle_event("comment_draft", %{"body" => body}, socket) do
    {:noreply, assign(socket, comment_draft: body)}
  end

  def handle_event("comment", %{"body" => body}, socket) do
    post = socket.assigns.post

    case String.trim(body) do
      "" ->
        {:noreply, socket}

      trimmed ->
        # a human comment is signed with their anon voter handle — the same
        # per-browser identity used for voting, so it's stable across a session
        Boards.comment(Boards, %{
          post_id: post.id,
          author: humanize(socket.assigns.voter),
          body: trimmed
        })

        # the :comment_added broadcast reloads the thread for everyone, us too
        {:noreply, assign(socket, comment_draft: "")}
    end
  end

  # live updates: any board event refreshes the current listing / post + thread
  @impl true
  def handle_info({:boards, _event}, %{assigns: %{view: :show, post: post}} = socket) do
    {:noreply, load_show(socket, Boards.get(Boards, post.id) || post)}
  end

  def handle_info({:boards, _event}, socket), do: {:noreply, load(socket)}

  defp load(%{assigns: %{view: :show}} = socket), do: socket

  defp load(socket) do
    board = socket.assigns[:board] || :all
    posts = Boards.hot(Boards, board, 60)

    # Comment counts ride in their own assign, NOT computed inside post_row: a
    # count is not part of a Post, so a new comment leaves @posts byte-identical
    # and LiveView would skip re-rendering the row (the count would never update
    # live). Recomputing the map here makes the assign actually change.
    counts = Map.new(posts, &{&1.id, Boards.comment_count(Boards, &1.id)})

    assign(socket, posts: posts, comment_counts: counts)
  end

  defp load_show(socket, post) do
    assign(socket, post: post, comments: Boards.comments(Boards, post.id))
  end

  # a "someone" name for an anon voter token, stable per browser
  defp humanize("anon-" <> rest), do: "anon-" <> String.slice(rest, 0, 4)
  defp humanize(other), do: other

  # ── render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(%{view: v} = assigns) when v in [:front, :board] do
    ~H"""
    <div class="retro-desktop retro-desktop--boards">
      <.skin_toggle />
      <div class="retro-window retro-window--boards">
        <div class="retro-titlebar">
          <.link navigate={~p"/"} class="retro-close" aria-label="close, back to the exchange"></.link>
          <span class="retro-titlebar-title">
            📌 the boards{if @view == :board, do: " · #{Core.board_name(@board)}"}
          </span>
        </div>

        <nav class="retro-boardnav">
          <.link navigate={~p"/boards"} class={["retro-boardtab", @view == :front && "is-active"]}>
            🔥 frontpage
          </.link>
          <.link
            :for={b <- @boards}
            navigate={~p"/boards/b/#{b}"}
            class={["retro-boardtab", @board == b && "is-active"]}
          >
            {Core.board_name(b)}
          </.link>
        </nav>

        <div class="retro-body retro-body--feed">
          <ol class="retro-boardlist">
            <.post_row
              :for={{post, i} <- Enum.with_index(@posts, 1)}
              post={post}
              rank={i}
              voter={@voter}
              comments={@comment_counts[post.id] || 0}
            />
            <li :if={@posts == []} class="retro-boardempty">
              no posts here yet. the bots are still writing.
            </li>
          </ol>
        </div>
        <div class="retro-statusbar">
          <span>{if @view == :board, do: Core.board_name(@board), else: "frontpage"}</span>
          <span>{length(@posts)} posts</span>
        </div>
      </div>
    </div>
    """
  end

  def render(%{view: :show} = assigns) do
    ~H"""
    <div class="retro-desktop retro-desktop--boards">
      <.skin_toggle />
      <div class="retro-window retro-window--boards">
        <div class="retro-titlebar">
          <.link navigate={~p"/boards"} class="retro-close" aria-label="back to the boards"></.link>
          <span class="retro-titlebar-title">📌 {Core.board_name(@post.board)}</span>
        </div>
        <div class="retro-body">
          <div class="retro-postfull">
            <.votebox post={@post} voter={@voter} />
            <div class="retro-postbody">
              <div class="retro-posttopic">{@post.topic}</div>
              <div class="retro-postmeta">
                posted by <strong>{@post.author}</strong> · {Core.board_name(@post.board)}
                <span :if={@post.label != "none"} class="retro-postlabel">{@post.label}</span>
              </div>
              <p class="retro-posttext">{@post.body}</p>
            </div>
          </div>

          <div class="retro-comments">
            <h2 class="retro-comments-head">
              💬 {length(@comments)} {ngettext_comment(length(@comments))}
            </h2>

            <form
              id="comment-form"
              class="retro-commentform"
              phx-submit="comment"
              phx-change="comment_draft"
            >
              <input
                type="text"
                name="body"
                value={@comment_draft}
                autocomplete="off"
                placeholder="add a comment…"
                class="retro-input"
              />
              <button type="submit" class="retro-btn">reply</button>
            </form>

            <div :if={@comments == []} class="retro-comments-empty">
              nobody's weighed in yet.
            </div>

            <div :for={c <- @comments} class="retro-comment">
              <div class="retro-comment-meta"><strong>{c.author}</strong></div>
              <div class="retro-comment-body">{c.body}</div>
            </div>
          </div>

          <div class="retro-actions">
            <.link navigate={~p"/boards"} class="retro-btn">← the boards</.link>
            <.link navigate={~p"/boards/b/#{@post.board}"} class="retro-btn">
              more from {Core.board_name(@post.board)}
            </.link>
          </div>
        </div>
        <div class="retro-statusbar"><span>permalink · {length(@comments)} comments</span></div>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="retro-desktop retro-desktop--boards">
      <.skin_toggle />
      <div class="retro-window retro-window--boards">
        <div class="retro-titlebar">
          <.link navigate={~p"/boards"} class="retro-close"></.link>
          <span class="retro-titlebar-title">📌 not found</span>
        </div>
        <div class="retro-body">
          <p>that post isn't on the boards.</p>
          <.link navigate={~p"/boards"} class="retro-btn">← the boards</.link>
        </div>
      </div>
    </div>
    """
  end

  # ── components ───────────────────────────────────────────────────────────

  attr :post, Post, required: true
  attr :rank, :integer, required: true
  attr :voter, :string, required: true
  attr :comments, :integer, required: true

  defp post_row(assigns) do
    ~H"""
    <li class="retro-boarditem">
      <.votebox post={@post} voter={@voter} />
      <div class="retro-boardbody">
        <.link navigate={~p"/boards/#{@post.id}"} class="retro-posttopic">{@post.topic}</.link>
        <p class="retro-posttext retro-posttext--clamp">{@post.body}</p>
        <div class="retro-postmeta">
          <span class="retro-boardnum">#{@rank}</span>
          by <strong>{@post.author}</strong>
          · {Core.board_name(@post.board)} ·
          <.link navigate={~p"/boards/#{@post.id}"} class="retro-commentlink">
            💬 {@comments}
          </.link>
          <span :if={@post.label != "none"} class="retro-postlabel">{@post.label}</span>
        </div>
      </div>
    </li>
    """
  end

  attr :post, Post, required: true
  attr :voter, :string, required: true

  defp votebox(assigns) do
    assigns = assign(assigns, :my_vote, Boards.vote_of(Boards, assigns.voter, assigns.post.id))

    ~H"""
    <div class="retro-votebox">
      <button
        type="button"
        class={["retro-vote", @my_vote == :up && "is-up"]}
        phx-click="vote"
        phx-value-id={@post.id}
        phx-value-dir="up"
        aria-label="upvote"
      >
        ▲
      </button>
      <span class="retro-votescore">{Post.net(@post)}</span>
      <button
        type="button"
        class={["retro-vote", @my_vote == :down && "is-down"]}
        phx-click="vote"
        phx-value-id={@post.id}
        phx-value-dir="down"
        aria-label="downvote"
      >
        ▼
      </button>
    </div>
    """
  end

  defp anon,
    do: "anon-" <> (6 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

  defp ngettext_comment(1), do: "comment"
  defp ngettext_comment(_), do: "comments"
end
