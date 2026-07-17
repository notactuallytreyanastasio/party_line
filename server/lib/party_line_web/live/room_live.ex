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

  alias PartyLine.{Buddies, Clips, DMs, Rooms}
  alias PartyLine.Rooms.Room

  @max_windows 4
  # streams need static names; windows are indexed into these
  @streams [:messages_0, :messages_1, :messages_2, :messages_3]

  @impl true
  def mount(_params, _session, socket) do
    socket = Tour.attach(socket, :line, PartyLineWeb.Tours.line())

    socket =
      Enum.reduce(@streams, socket, fn name, sock ->
        sock
        |> stream_configure(name, dom_id: &"#{name}-#{&1.message_id}")
        |> stream(name, [])
      end)

    {:ok,
     socket
     |> assign(page_title: "Party Line", stage: :dialing, name: "", error: nil)
     |> assign(windows: [], directory: directory_text())
     |> assign(buddies: [], dms: %{})}
  end

  @impl true
  def handle_event("show_me", _params, socket) do
    {:noreply, Tour.start(socket, :line)}
  end

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

  # ── Clipping (client hook pushes the selection; ids are message_ids) ─────

  def handle_event("select", %{"room" => room_id, "ids" => ids}, socket) when is_list(ids) do
    {:noreply, update_window(socket, room_id, &%{&1 | selected: ids, clip_error: nil})}
  end

  def handle_event("clip_wall", %{"room" => room_id} = params, socket) do
    with %{selected: [_ | _]} = window <- window_for(socket, room_id),
         [_ | _] = messages <- selected_messages(window) do
      note = params |> Map.get("note", "") |> String.trim()

      {:ok, _} =
        Clips.clip(messages, %{
          room_id: room_id,
          topic: window.topic,
          clipped_by: socket.assigns.name,
          note: if(note == "", do: nil, else: note)
        })
    end

    {:noreply, clear_selection(socket, room_id)}
  end

  def handle_event("clip_share", %{"room" => room_id, "buddy" => buddy}, socket) do
    buddy = String.trim(buddy)
    valid? = buddy != socket.assigns.name and buddy in Buddies.online()

    with true <- valid?,
         %{selected: [_ | _]} = window <- window_for(socket, room_id),
         [_ | _] = messages <- selected_messages(window) do
      {:ok, _} =
        DMs.send_dm(socket.assigns.name, buddy, "clipped from #{room_id}",
          kind: :clip,
          quoted: messages
        )

      {:noreply, clear_selection(socket, room_id)}
    else
      # keep the selection so they can retry with a real name
      _ ->
        {:noreply,
         update_window(socket, room_id, &%{&1 | clip_error: "nobody by that name is on"})}
    end
  end

  def handle_event("clip_clear", %{"room" => room_id}, socket) do
    {:noreply, clear_selection(socket, room_id)}
  end

  # ── DMs ──────────────────────────────────────────────────────────────────

  def handle_event("open_dm", %{"buddy" => buddy}, socket) do
    {:noreply, open_dm(socket, buddy)}
  end

  def handle_event("close_dm", %{"buddy" => buddy}, socket) do
    {:noreply, assign(socket, dms: Map.delete(socket.assigns.dms, buddy))}
  end

  def handle_event("dm_draft", %{"buddy" => buddy, "body" => body}, socket) do
    {:noreply, update_dm(socket, buddy, &%{&1 | draft: body})}
  end

  def handle_event("dm_send", %{"buddy" => buddy, "body" => body}, socket) do
    body = String.trim(body)
    if body != "", do: DMs.send_dm(socket.assigns.name, buddy, body)
    {:noreply, update_dm(socket, buddy, &%{&1 | draft: ""})}
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
      nil ->
        {:noreply, socket}

      window ->
        message = Map.put(message, :group_start, group_start?(message, window.last_group))

        socket
        |> stream_insert(stream_name(window.index), message)
        |> update_window(room_id, &%{&1 | last_group: group_key(message)})
        |> then(&{:noreply, &1})
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

  def handle_info({:dm, other, message}, socket) do
    socket =
      if Map.has_key?(socket.assigns.dms, other) do
        update_dm(socket, other, &%{&1 | history: &1.history ++ [message]})
      else
        open_dm(socket, other)
      end

    {:noreply, socket}
  end

  def handle_info(:refresh_buddies, socket) do
    if socket.assigns.stage == :in_room do
      Process.send_after(self(), :refresh_buddies, 10_000)
      {:noreply, assign(socket, buddies: Buddies.online())}
    else
      {:noreply, socket}
    end
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
        :ok = Buddies.register(name, self())
        Phoenix.PubSub.subscribe(PartyLine.PubSub, DMs.topic(name))
        Process.send_after(self(), :refresh_buddies, 10_000)

        socket =
          Enum.reduce(windows, socket, fn w, sock ->
            stream(sock, stream_name(w.index), w.transcript, reset: true)
          end)

        {:noreply,
         socket
         |> assign(stage: :in_room, name: name, error: nil)
         |> assign(buddies: Buddies.online())
         |> assign(windows: Enum.map(windows, &Map.delete(&1, :transcript)))}
    end
  end

  defp join_line(_socket, name, room_id, index) do
    with {:ok, room} <- Rooms.whereis(room_id),
         {:ok, welcome} <- Room.join(room, %{name: name, kind: :human, lurk: true, pid: self()}) do
      {operator_lines, chat} =
        Enum.split_with(welcome.transcript, &(&1.sender.kind == :operator))

      {annotated, last_group} = annotate_groups(chat)

      %{
        index: index,
        room_id: room_id,
        room: room,
        topic: welcome.room.topic,
        participant_id: welcome.participant_id,
        roster: welcome.roster,
        lurking: true,
        draft: "",
        selected: [],
        clip_error: nil,
        operator_line: operator_lines |> List.last() |> then(&(&1 && &1.body)),
        last_group: last_group,
        transcript: annotated
      }
    else
      _ -> nil
    end
  end

  defp stream_name(index), do: Enum.at(@streams, index)

  # ── Slack-style message grouping ─────────────────────────────────────────
  # Consecutive messages from one sender fold under a single name header;
  # a gap of 5+ minutes starts a fresh group even for the same sender.

  @group_gap_seconds 300

  defp annotate_groups(messages) do
    Enum.map_reduce(messages, nil, fn message, prev ->
      annotated = Map.put(message, :group_start, group_start?(message, prev))
      {annotated, group_key(message)}
    end)
  end

  defp group_key(message), do: %{sender_id: message.sender.participant_id, ts: message.ts}

  defp group_start?(_message, nil), do: true

  defp group_start?(message, %{sender_id: sender_id, ts: prev_ts}) do
    message.sender.participant_id != sender_id or
      gap_seconds(prev_ts, message.ts) >= @group_gap_seconds
  end

  defp gap_seconds(prev_ts, ts) do
    with {:ok, prev, _} <- DateTime.from_iso8601(prev_ts),
         {:ok, cur, _} <- DateTime.from_iso8601(ts) do
      DateTime.diff(cur, prev)
    else
      _ -> @group_gap_seconds
    end
  end

  defp avatar_style(name) do
    hue = :erlang.phash2(name, 360)
    "background: hsl(#{hue}, 45%, 38%)"
  end

  defp initial(name), do: name |> String.first() |> String.upcase()

  defp window_for(socket, room_id),
    do: Enum.find(socket.assigns.windows, &(&1.room_id == room_id))

  # Selected message_ids → conversation-ordered quote payloads, pulled from
  # the room's canonical transcript (assigns only hold ids; streams own the
  # rendered messages).
  defp selected_messages(window) do
    ids = MapSet.new(window.selected)

    window.room
    |> Room.snapshot()
    |> Map.fetch!(:transcript)
    |> Enum.filter(&MapSet.member?(ids, &1.message_id))
    |> Enum.sort_by(& &1.seq)
    |> Enum.map(&%{sender_name: &1.sender.name, kind: &1.sender.kind, body: &1.body, ts: &1.ts})
  end

  defp clear_selection(socket, room_id) do
    socket
    |> update_window(room_id, &%{&1 | selected: []})
    |> push_event("clip:clear", %{room: room_id})
  end

  defp open_dm(socket, buddy) do
    dm = %{history: DMs.history(socket.assigns.name, buddy), draft: ""}
    assign(socket, dms: Map.put(socket.assigns.dms, buddy, dm))
  end

  defp update_dm(socket, buddy, fun) do
    case socket.assigns.dms[buddy] do
      nil -> socket
      dm -> assign(socket, dms: Map.put(socket.assigns.dms, buddy, fun.(dm)))
    end
  end

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
      <.skin_toggle />
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
      <.skin_toggle />
      <Tour.Components.tour tour={@tour} class="tour--party" />
      <button type="button" class="retro-showme" phx-click="show_me">? show me around</button>
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
              phx-hook=".Chatlog"
              data-room={window.room_id}
            >
              <li
                :for={{dom_id, message} <- @streams[stream_name(window.index)]}
                id={dom_id}
                data-mid={message.message_id}
                class={[
                  "retro-msg",
                  Map.get(message, :group_start, true) && "retro-msg--start",
                  mentions_me?(message, window.participant_id) && "retro-chatline--me"
                ]}
                title={message.ts}
              >
                <div :if={Map.get(message, :group_start, true)} class="retro-msg-head">
                  <span
                    class="retro-avatar"
                    style={avatar_style(message.sender.name)}
                    aria-hidden="true"
                  >
                    {initial(message.sender.name)}
                  </span>
                  <span class={[
                    "retro-chatname",
                    message.sender.kind == :bot && "retro-chatname--bot"
                  ]}>
                    {message.sender.name}
                  </span>
                  <span :if={message.sender.kind == :bot} class="retro-badge">bot</span>
                  <time
                    class="retro-msg-time"
                    id={dom_id <> "-time"}
                    phx-hook=".LocalTime"
                    datetime={message.ts}
                  >
                    {String.slice(message.ts, 11, 5)}
                  </time>
                </div>
                <div class="retro-msg-body">{highlight_mentions(message)}</div>
              </li>
            </ul>

            <form
              :if={window.selected != []}
              id={"clipbar-#{window.index}"}
              phx-submit="clip_wall"
              class="retro-clipbar"
            >
              <input type="hidden" name="room" value={window.room_id} />
              <span class="retro-clipbar-count">{length(window.selected)} clipped</span>
              <input
                type="text"
                name="note"
                placeholder="why is this funny?"
                autocomplete="off"
                class="retro-input retro-clipbar-note"
              />
              <button type="submit" class="retro-btn">😂 to the wall</button>
              <%= if others(@buddies, @name) != [] do %>
                <input
                  type="text"
                  name="buddy"
                  form={"clipshare-#{window.index}"}
                  list={"buddies-dl-#{window.index}"}
                  placeholder="share with… (type a name)"
                  autocomplete="off"
                  class="retro-input retro-clipbar-buddy"
                />
                <datalist id={"buddies-dl-#{window.index}"}>
                  <option :for={b <- others(@buddies, @name)} value={b} />
                </datalist>
                <button type="submit" form={"clipshare-#{window.index}"} class="retro-btn">
                  send
                </button>
              <% end %>
              <button
                type="button"
                phx-click="clip_clear"
                phx-value-room={window.room_id}
                class="retro-btn"
              >
                ✕
              </button>
              <span :if={window.clip_error} class="retro-clipbar-error">{window.clip_error}</span>
            </form>
            <form
              :if={window.selected != []}
              id={"clipshare-#{window.index}"}
              phx-submit="clip_share"
              style="display:none;"
            >
              <input type="hidden" name="room" value={window.room_id} />
            </form>

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

        <div
          id="pane-buddies"
          class="retro-window retro-window--pane retro-buddies"
          phx-hook=".DraggableWindow"
          data-pos="right"
          data-w="300"
        >
          <div class="retro-titlebar">
            <span class="retro-titlebar-title">★ buddy list</span>
          </div>
          <div class="retro-pane-main retro-buddies-main">
            <div class="retro-buddy-group">
              <div class="retro-buddy-heading">▼ lines ({length(@windows)})</div>
              <div :for={w <- @windows} class="retro-buddy">
                <span>☎ {w.room_id}</span>
                <span class="retro-buddy-meta">{length(w.roster)} on</span>
              </div>
            </div>
            <div class="retro-buddy-group">
              <div class="retro-buddy-heading">▼ online ({length(@buddies)})</div>
              <div :for={buddy <- @buddies} class="retro-buddy">
                <span>🙂 {buddy}<span :if={buddy == @name} class="retro-buddy-meta"> (you)</span></span>
                <button
                  :if={buddy != @name}
                  type="button"
                  class="retro-btn retro-btn--mini"
                  phx-click="open_dm"
                  phx-value-buddy={buddy}
                >
                  IM
                </button>
              </div>
              <div :if={@buddies == [@name] or @buddies == []} class="retro-buddy retro-buddy-meta">
                nobody else on the exchange. lurk a while.
              </div>
            </div>
          </div>
          <div class="retro-statusbar">
            <span>screen name: {@name}</span>
          </div>
          <div class="retro-resize-grip" aria-hidden="true"></div>
        </div>

        <div
          :for={{buddy, dm} <- @dms}
          id={"dm-#{:erlang.phash2(buddy)}"}
          class="retro-window retro-window--pane retro-dm"
          phx-hook=".DraggableWindow"
          data-pos="cascade"
          data-cx={:erlang.phash2(buddy, 6)}
          data-w="360"
          data-h="380"
        >
          <div class="retro-titlebar">
            <button
              type="button"
              class="retro-close"
              phx-click="close_dm"
              phx-value-buddy={buddy}
              aria-label={"close conversation with #{buddy}"}
            ></button>
            <span class="retro-titlebar-title">✉ {buddy}</span>
          </div>
          <div class="retro-pane-main">
            <ul class="retro-chatlog retro-dm-log">
              <li :for={message <- dm.history} class="retro-msg retro-msg--start">
                <div class="retro-msg-head">
                  <span class="retro-avatar" style={avatar_style(message.from)} aria-hidden="true">
                    {initial(message.from)}
                  </span>
                  <span class="retro-chatname">{message.from}</span>
                </div>
                <div class="retro-msg-body">
                  {message.body}
                  <blockquote :if={message.kind == :clip} class="retro-dm-quote">
                    <div :for={q <- message.quoted}>
                      <strong>{q.sender_name}:</strong> {q.body}
                    </div>
                  </blockquote>
                </div>
              </li>
            </ul>
            <form phx-submit="dm_send" phx-change="dm_draft" class="retro-inputrow">
              <input type="hidden" name="buddy" value={buddy} />
              <input
                type="text"
                name="body"
                value={dm.draft}
                placeholder={"message #{buddy}"}
                autocomplete="off"
                class="retro-input"
              />
              <button type="submit" class="retro-btn">send</button>
            </form>
          </div>
          <div class="retro-resize-grip" aria-hidden="true"></div>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Chatlog">
        export default {
          mounted() {
            this.selected = new Set()
            this.el.addEventListener("click", (e) => {
              if (e.target.closest("a,button,input")) return
              const li = e.target.closest("li.retro-msg")
              if (!li || !li.dataset.mid) return
              const id = li.dataset.mid
              if (this.selected.has(id)) {
                this.selected.delete(id)
                li.classList.remove("retro-msg--selected")
              } else {
                this.selected.add(id)
                li.classList.add("retro-msg--selected")
              }
              this.pushEvent("select", { room: this.el.dataset.room, ids: [...this.selected] })
            })
            this.handleEvent("clip:clear", ({ room }) => {
              if (room !== this.el.dataset.room) return
              this.selected.clear()
              this.el.querySelectorAll(".retro-msg--selected")
                .forEach((el) => el.classList.remove("retro-msg--selected"))
            })
            this.scroll()
          },
          updated() { this.scroll() },
          scroll() { this.el.scrollTop = this.el.scrollHeight }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
        export default {
          mounted() {
            const d = new Date(this.el.getAttribute("datetime"))
            if (!isNaN(d)) {
              this.el.textContent = d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
            }
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".DraggableWindow">
        export default {
          mounted() {
            const pad = 14
            const W = window.innerWidth, H = window.innerHeight
            const ds = this.el.dataset

            if (ds.pos === "right") {
              // full height, tucked below the fixed skin-toggle button
              const w = parseInt(ds.w, 10)
              const y = 54
              this.pos = { x: W - w - pad, y, w, h: H - y - pad }
            } else if (ds.pos === "cascade") {
              const w = parseInt(ds.w, 10), h = parseInt(ds.h, 10)
              const c = parseInt(ds.cx || "0", 10)
              this.pos = { x: 80 + c * 36, y: 70 + c * 30, w, h }
            } else {
              const idx = parseInt(ds.index, 10)
              const n = parseInt(ds.count, 10)
              const cols = n === 1 ? 1 : 2
              const rows = Math.ceil(n / cols)
              // leave room for the buddy list on the right
              const w = Math.min(880, (W - 330 - pad * (cols + 1)) / cols)
              const h = (H - pad * (rows + 1)) / rows
              const col = idx % cols, row = Math.floor(idx / cols)
              this.pos = { x: pad + col * (w + pad), y: pad + row * (h + pad), w, h }
            }
            this.apply()
            this.raise()

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

  defp others(buddies, name), do: Enum.reject(buddies, &(&1 == name))

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
