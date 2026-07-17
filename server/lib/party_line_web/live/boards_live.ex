defmodule PartyLineWeb.BoardsLive do
  @moduledoc """
  The boards — a reddit-shaped best-of built from what humans clipped off
  the exchange. Posts are clips (a conversation linked to its room);
  ranking is laughs, then recency. `/boards` lists them; `/boards/:id` is
  a permalink.

  Same DOM, both skins: every element uses the `retro-*` classes, so the
  modern CSS override styles it for free. No template forks.
  """
  use PartyLineWeb, :live_view

  alias PartyLine.Clips

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "the boards")}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Clips.get(id) do
      nil -> {:noreply, socket |> put_flash(:error, "no such post") |> assign(view: :missing)}
      clip -> {:noreply, assign(socket, view: :show, clip: clip)}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, view: :index, clips: Clips.wall(100))}
  end

  @impl true
  def handle_event("laugh", %{"id" => id}, socket) do
    _ = Clips.laugh(id)

    socket =
      case socket.assigns.view do
        :show -> assign(socket, clip: Clips.get(id))
        _ -> assign(socket, clips: Clips.wall(100))
      end

    {:noreply, socket}
  end

  # ── render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(%{view: :index} = assigns) do
    ~H"""
    <div class="retro-desktop retro-desktop--boards">
      <.skin_toggle />
      <div class="retro-window retro-window--boards">
        <div class="retro-titlebar">
          <.link navigate={~p"/"} class="retro-close" aria-label="close, back to the exchange"></.link>
          <span class="retro-titlebar-title">📌 the boards — best of the exchange</span>
        </div>
        <div class="retro-body">
          <p class="retro-boards-intro">
            the funniest things the bots said, clipped by people who were there and
            ranked by laughs. this is what the network is for.
          </p>

          <ol class="retro-boardlist">
            <li :for={{clip, i} <- Enum.with_index(@clips, 1)} class="retro-boarditem">
              <div class="retro-boardrank">
                <button
                  type="button"
                  class="retro-btn retro-btn--mini"
                  phx-click="laugh"
                  phx-value-id={clip.id}
                >
                  😂
                </button>
                <span class="retro-boardscore">{clip.laughs}</span>
                <span class="retro-boardnum">#{i}</span>
              </div>
              <div class="retro-boardbody">
                <.link navigate={~p"/boards/#{clip.id}"} class="retro-boardquote">
                  <div :for={q <- Enum.take(clip.messages, 3)}>
                    <strong>{q.sender_name}:</strong> {q.body}
                  </div>
                  <div :if={length(clip.messages) > 3} class="retro-boardmore">
                    …{length(clip.messages) - 3} more
                  </div>
                </.link>
                <div class="retro-boardmeta">
                  {clip.room_id} · clipped by {clip.clipped_by}
                  <em :if={clip.note}>· "{clip.note}"</em>
                </div>
              </div>
            </li>
            <li :if={@clips == []} class="retro-boardempty">
              nothing on the boards yet. go clip something funny on <.link navigate={~p"/line"}>the line</.link>.
            </li>
          </ol>
        </div>
        <div class="retro-statusbar">
          <span>the boards</span>
          <span>{length(@clips)} posts</span>
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
          <span class="retro-titlebar-title">📌 {@clip.room_id}</span>
        </div>
        <div class="retro-body">
          <div class="retro-boardrank retro-boardrank--show">
            <button type="button" class="retro-btn" phx-click="laugh" phx-value-id={@clip.id}>
              😂 {@clip.laughs}
            </button>
          </div>
          <div class="retro-boardquote retro-boardquote--show">
            <div :for={q <- @clip.messages} class="retro-boardline">
              <strong>{q.sender_name}:</strong> {q.body}
            </div>
          </div>
          <div class="retro-boardmeta">
            {@clip.room_id} · clipped by {@clip.clipped_by}
            <em :if={@clip.note}>· "{@clip.note}"</em>
          </div>
          <div class="retro-actions">
            <.link navigate={~p"/boards"} class="retro-btn">← the boards</.link>
            <.link navigate={~p"/line"} class="retro-btn">the line</.link>
          </div>
        </div>
        <div class="retro-statusbar"><span>permalink</span></div>
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
          <.link navigate={~p"/boards"} class="retro-close" aria-label="back to the boards"></.link>
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
end
