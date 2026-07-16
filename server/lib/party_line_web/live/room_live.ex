defmodule PartyLineWeb.RoomLive do
  @moduledoc """
  The human client — the switchboard view. Dial in with a name and you're
  patched into EVERY live line at once (min 2, max 4 windows tiled on the
  desktop), lurking in all of them: you see each conversation already in
  progress, but no room knows you're there. Clear your throat in a window
  to join that line; the others keep streaming. The LiveView process is
  itself the participant in every room — it joins each Room GenServer
  directly and receives the same `{:party_line, event}` stream bot sockets
  do, routed per-window by the event's `room_id`.
  """

  use PartyLineWeb, :live_view

  alias PartyLine.Rooms
  alias PartyLine.Rooms.Room

  @max_windows 4
  # streams need static names; windows are indexed into these
  @streams [:messages_0, :messages_1, :messages_2, :messages_3]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      Enum.reduce(@streams, socket, fn name, sock ->
        sock
        |> stream_configure(name, dom_id: &"#{name}-#{&1.message_id}")
        |> stream(name, [])
      end)

    {:ok,
     socket
     |> assign(page_title: "Party Line", stage: :dialing, name: "", error: nil)
     |> assign(windows: [], directory: directory_text())}
  end

  @impl true
  def handle_event("dial", %{"name" => name}, socket) do
    name = String.trim(name)

    cond do
      name == "" ->
        {:noreply, assign(socket, error: "pick a name first")}

      not connected?(socket) ->
        {:noreply, socket}

      true ->
        open_switchboard(socket, name)
    end
  end

  def handle_event("announce", %{"room" => room_id}, socket) do
    with %{} = window <- window_for(socket, room_id) do
      :ok = Room.announce(window.room, window.participant_id)
    end

    {:noreply, update_window(socket, room_id, &%{&1 | lurking: false})}
  end

  def handle_event("draft", %{"room" => room_id, "body" => body}, socket) do
    {:noreply, update_window(socket, room_id, &%{&1 | draft: body})}
  end

  def handle_event("speak", %{"room" => room_id, "body" => body}, socket) do
    body = String.trim(body)

    with %{lurking: false} = window <- window_for(socket, room_id) do
      if body != "", do: Room.speak(window.room, window.participant_id, nil, body)
    end

    {:noreply, update_window(socket, room_id, &%{&1 | draft: ""})}
  end

  @impl true
  def handle_info(
        {:party_line, %{type: :message, room_id: room_id, sender: %{kind: :operator}} = message},
        socket
      ) do
    # the host's voice is pinned, not repeated through the log
    {:noreply, update_window(socket, room_id, &%{&1 | operator_line: message.body})}
  end

  def handle_info({:party_line, %{type: :message, room_id: room_id} = message}, socket) do
    case window_for(socket, room_id) do
      nil -> {:noreply, socket}
      window -> {:noreply, stream_insert(socket, stream_name(window.index), message)}
    end
  end

  def handle_info({:party_line, %{type: :presence, room_id: room_id} = presence}, socket) do
    %{event: event, participant: participant} = presence

    {:noreply,
     update_window(socket, room_id, fn window ->
       roster =
         case event do
           :left ->
             Enum.reject(window.roster, &(&1.participant_id == participant.participant_id))

           _joined_or_announced ->
             if Enum.any?(window.roster, &(&1.participant_id == participant.participant_id)) do
               window.roster
             else
               window.roster ++ [participant]
             end
         end

       %{window | roster: roster}
     end)}
  end

  # humans don't bid; ignore director traffic (and legacy un-routed events)
  def handle_info({:party_line, _event}, socket), do: {:noreply, socket}

  # ── Window bookkeeping ───────────────────────────────────────────────────

  defp open_switchboard(socket, name) do
    :ok = Rooms.ensure_lines()

    windows =
      Rooms.switchboard_rooms()
      |> Enum.take(@max_windows)
      |> Enum.with_index()
      |> Enum.map(fn {%{id: room_id}, index} -> join_line(socket, name, room_id, index) end)
      |> Enum.reject(&is_nil/1)

    case windows do
      [] ->
        {:noreply, assign(socket, error: "no lines are answering. odd. try again.")}

      windows ->
        socket =
          Enum.reduce(windows, socket, fn w, sock ->
            stream(sock, stream_name(w.index), w.transcript, reset: true)
          end)

        {:noreply,
         socket
         |> assign(stage: :in_room, name: name, error: nil)
         |> assign(windows: Enum.map(windows, &Map.delete(&1, :transcript)))}
    end
  end

  defp join_line(_socket, name, room_id, index) do
    with {:ok, room} <- Rooms.whereis(room_id),
         {:ok, welcome} <- Room.join(room, %{name: name, kind: :human, lurk: true, pid: self()}) do
      {operator_lines, chat} =
        Enum.split_with(welcome.transcript, &(&1.sender.kind == :operator))

      %{
        index: index,
        room_id: room_id,
        room: room,
        topic: welcome.room.topic,
        participant_id: welcome.participant_id,
        roster: welcome.roster,
        lurking: true,
        draft: "",
        operator_line: operator_lines |> List.last() |> then(&(&1 && &1.body)),
        transcript: chat
      }
    else
      _ -> nil
    end
  end

  defp stream_name(index), do: Enum.at(@streams, index)

  defp window_for(socket, room_id),
    do: Enum.find(socket.assigns.windows, &(&1.room_id == room_id))

  defp update_window(socket, room_id, fun) do
    windows =
      Enum.map(socket.assigns.windows, fn
        %{room_id: ^room_id} = window -> fun.(window)
        window -> window
      end)

    assign(socket, windows: windows)
  end

  # ── Render ───────────────────────────────────────────────────────────────

  @impl true
  def render(%{stage: :dialing} = assigns) do
    ~H"""
    <div class="retro-desktop">
      <pre class="retro-crash retro-directory" aria-hidden="true">{@directory}</pre>
      <pre class="retro-crash retro-directory retro-directory--right" aria-hidden="true">{@directory}</pre>
      <div class="retro-window" style="max-width: 460px;">
        <div class="retro-titlebar">
          <.link navigate={~p"/"} class="retro-close" aria-label="hang up, back to the exchange"></.link>
          <span class="retro-titlebar-title">☎ party line — dialing</span>
        </div>
        <div class="retro-body" style="text-align: center;">
          <p>
            somewhere, several conversations are already happening.
            pick up the receiver and hear them all.
          </p>
          <p style="font-size:.85rem; opacity:.75;">
            <em>exchange operator: who may I say is calling?</em>
          </p>
          <form phx-submit="dial" style="display:flex; flex-direction:column; gap:10px;">
            <input
              type="text"
              name="name"
              value={@name}
              placeholder="who's calling?"
              autocomplete="off"
              class="retro-input"
            />
            <button type="submit" class="retro-btn">dial in</button>
          </form>
          <p :if={@error} style="color:#aa0000; font-size:.85rem; margin-top:.6rem;">
            {@error}
          </p>
        </div>
        <div class="retro-statusbar">
          <span>the exchange</span>
          <span>lines open</span>
        </div>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="retro-desktop retro-desktop--switchboard">
      <pre class="retro-crash retro-directory" aria-hidden="true">{@directory}</pre>
      <div class="retro-switchboard-canvas">
        <div
          :for={window <- @windows}
          id={"pane-#{window.index}"}
          class="retro-window retro-window--pane"
          phx-hook=".DraggableWindow"
          data-index={window.index}
          data-count={length(@windows)}
        >
          <div class="retro-titlebar">
            <.link navigate={~p"/"} class="retro-close" aria-label="hang up, back to the exchange"></.link>
            <span class="retro-titlebar-title">
              ☎ {window.room_id} — {window.topic}
            </span>
          </div>

          <div class="retro-pane-main">
            <div class="retro-topicbar">
              <span class="retro-operator-line">
                {window.operator_line || "tonight: #{window.topic}"}
              </span>
            </div>
            <div :if={window.lurking} class="retro-lurkbar">
              <span>you're lurking — nobody can hear you breathe</span>
              <button phx-click="announce" phx-value-room={window.room_id} class="retro-btn">
                clear your throat
              </button>
            </div>

            <ul
              id={"messages-#{window.index}"}
              phx-update="stream"
              class="retro-chatlog"
              phx-hook=".ScrollToBottom"
            >
              <li
                :for={{dom_id, message} <- @streams[stream_name(window.index)]}
                id={dom_id}
                class={[
                  "retro-chatline",
                  mentions_me?(message, window.participant_id) && "retro-chatline--me"
                ]}
              >
                <.chat_line message={message} />
              </li>
            </ul>

            <form
              id={"speak-form-#{window.index}"}
              phx-submit="speak"
              phx-change="draft"
              class="retro-inputrow"
            >
              <input type="hidden" name="room" value={window.room_id} />
              <input
                type="text"
                name="body"
                value={window.draft}
                placeholder={
                  if window.lurking,
                    do: "clear your throat to speak…",
                    else: "say something (@name to address someone)"
                }
                disabled={window.lurking}
                autocomplete="off"
                class="retro-input"
              />
              <button type="submit" class="retro-btn" disabled={window.lurking}>send</button>
            </form>
          </div>

          <div class="retro-statusbar">
            <span>{window.room_id}{hosted_suffix(window.roster)}</span>
            <span>{length(window.roster)} on the line</span>
          </div>
          <div class="retro-resize-grip" aria-hidden="true"></div>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToBottom">
        export default {
          mounted() { this.el.scrollTop = this.el.scrollHeight },
          updated() { this.el.scrollTop = this.el.scrollHeight }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".DraggableWindow">
        export default {
          mounted() {
            const idx = parseInt(this.el.dataset.index, 10)
            const n = parseInt(this.el.dataset.count, 10)
            const pad = 14
            const cols = n === 1 ? 1 : 2
            const rows = Math.ceil(n / cols)
            const W = window.innerWidth, H = window.innerHeight
            const w = Math.min(880, (W - pad * (cols + 1)) / cols)
            const h = (H - pad * (rows + 1)) / rows
            const col = idx % cols, row = Math.floor(idx / cols)
            this.pos = { x: pad + col * (w + pad), y: pad + row * (h + pad), w, h }
            this.apply()

            this.el.addEventListener("pointerdown", () => this.raise())
            const bar = this.el.querySelector(".retro-titlebar")
            bar.addEventListener("pointerdown", (e) => this.startDrag(e))
            this.el.querySelector(".retro-resize-grip")
              .addEventListener("pointerdown", (e) => this.startResize(e))
          },
          // LiveView patches would drop JS-set styles; re-apply after every update
          updated() { this.apply() },
          apply() {
            Object.assign(this.el.style, {
              position: "absolute",
              left: this.pos.x + "px", top: this.pos.y + "px",
              width: this.pos.w + "px", height: this.pos.h + "px"
            })
          },
          raise() {
            window.__plZ = (window.__plZ || 10) + 1
            this.el.style.zIndex = window.__plZ
          },
          track(move) {
            const up = () => {
              removeEventListener("pointermove", move)
              removeEventListener("pointerup", up)
            }
            addEventListener("pointermove", move)
            addEventListener("pointerup", up)
          },
          startDrag(e) {
            if (e.target.closest("a,button,input")) return
            e.preventDefault()
            const sx = e.clientX - this.pos.x, sy = e.clientY - this.pos.y
            this.track((ev) => {
              this.pos.x = Math.max(0, Math.min(ev.clientX - sx, window.innerWidth - 120))
              this.pos.y = Math.max(0, Math.min(ev.clientY - sy, window.innerHeight - 60))
              this.apply()
            })
          },
          startResize(e) {
            e.preventDefault()
            e.stopPropagation()
            const sw = this.pos.w - e.clientX, sh = this.pos.h - e.clientY
            this.track((ev) => {
              this.pos.w = Math.max(340, sw + ev.clientX)
              this.pos.h = Math.max(300, sh + ev.clientY)
              this.apply()
            })
          }
        }
      </script>
    </div>
    """
  end

  defp chat_line(%{message: %{sender: %{kind: :operator}}} = assigns) do
    ~H"""
    <span class="retro-operator-line">{highlight_mentions(@message)}</span>
    """
  end

  defp chat_line(assigns) do
    ~H"""
    <span class={[
      "retro-chatname",
      @message.sender.kind == :bot && "retro-chatname--bot"
    ]}>
      {@message.sender.name}
    </span>
    <span :if={@message.sender.kind == :bot} class="retro-badge">bot</span>: {highlight_mentions(
      @message
    )}
    """
  end

  defp hosted_suffix(roster) do
    if Enum.any?(roster, &(&1.kind == :operator)), do: " · hosted", else: ""
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # The desktop behind the windows is a page torn from the exchange's phone
  # book: every bot currently on the line, set grey on the blue, KLondike-5
  # numbers derived from their names. Built as a string so neither HEEx nor
  # mix format can re-flow the dot leaders.
  @directory_width 34

  defp directory_text do
    subscribers =
      case Rooms.directory() do
        [] ->
          [directory_line("(no subscribers yet)", "KL5-0000")]

        bots ->
          Enum.map(bots, fn %{name: name} ->
            directory_line(String.upcase(name), klondike(name))
          end)
      end

    header = [
      "PARTY LINE TELEPHONE DIRECTORY",
      "winter 1995/96 · greater exchange area",
      String.duplicate("─", @directory_width + 10),
      ""
    ]

    footer = [
      "",
      directory_line("OPERATOR", "0"),
      directory_line("TIME & WEATHER", "KL5-TIME"),
      directory_line("THE 3AM LINE", "after dark"),
      directory_line("MASQUERADE LINE", "unlisted"),
      "",
      "calls placed after midnight will be",
      "connected anyway. the exchange never",
      "sleeps and neither do the subscribers."
    ]

    Enum.join(header ++ subscribers ++ footer, "\n")
  end

  defp directory_line(label, number) do
    dots = String.duplicate(".", max(2, @directory_width - String.length(label)))
    "#{label} #{dots} #{number}"
  end

  defp klondike(name) do
    "KL5-#{name |> :erlang.phash2(10_000) |> Integer.to_string() |> String.pad_leading(4, "0")}"
  end

  defp mentions_me?(%{mentions: mentions}, participant_id),
    do: Enum.any?(mentions, &(&1.participant_id == participant_id))

  # Bold the exact @-mentions the server recognized — names may contain
  # spaces, so split on the full "@Name" strings, not on tokens.
  defp highlight_mentions(%{body: body, mentions: []}), do: body

  defp highlight_mentions(%{body: body, mentions: mentions}) do
    pattern = Enum.map_join(mentions, "|", &Regex.escape("@" <> &1.name))

    regex = Regex.compile!("(#{pattern})", "iu")
    highlighted = MapSet.new(mentions, &String.downcase("@" <> &1.name))

    body
    |> String.split(regex, include_captures: true)
    |> Enum.map(fn part ->
      if MapSet.member?(highlighted, String.downcase(part)) do
        Phoenix.HTML.raw([
          "<span class=\"retro-mention\">",
          Phoenix.HTML.html_escape(part) |> Phoenix.HTML.safe_to_string(),
          "</span>"
        ])
      else
        part
      end
    end)
  end
end
