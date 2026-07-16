defmodule PartyLineWeb.RoomLive do
  @moduledoc """
  The human client. Dial in with a name, land in the room **lurking** —
  you see the conversation already in progress but the room doesn't know
  you're there — then clear your throat to join. The LiveView process is
  itself the room participant: it joins the Room GenServer directly and
  receives the same `{:party_line, event}` stream the bot sockets do.
  """

  use PartyLineWeb, :live_view

  alias PartyLine.Rooms
  alias PartyLine.Rooms.Room

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Party Line", stage: :dialing, name: "", error: nil)
     |> assign(room: nil, room_id: nil, topic: nil, participant_id: nil)
     |> assign(roster: [], lurking: true, draft: "")
     |> assign(directory: directory_text())
     |> stream_configure(:messages, dom_id: &"msg-#{&1.message_id}")
     |> stream(:messages, [])}
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
        %{room_id: room_id} = Rooms.dial()
        {:ok, room} = Rooms.whereis(room_id)

        case Room.join(room, %{name: name, kind: :human, lurk: true, pid: self()}) do
          {:ok, welcome} ->
            {:noreply,
             socket
             |> assign(
               stage: :in_room,
               name: name,
               error: nil,
               room: room,
               room_id: room_id,
               topic: welcome.room.topic,
               participant_id: welcome.participant_id,
               roster: welcome.roster,
               lurking: true
             )
             |> stream(:messages, welcome.transcript, reset: true)}

          {:error, reason} ->
            {:noreply, assign(socket, error: "couldn't join: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("announce", _params, socket) do
    :ok = Room.announce(socket.assigns.room, socket.assigns.participant_id)
    {:noreply, assign(socket, lurking: false)}
  end

  def handle_event("draft", %{"body" => body}, socket) do
    {:noreply, assign(socket, draft: body)}
  end

  def handle_event("speak", %{"body" => body}, socket) do
    body = String.trim(body)

    if body != "" and not socket.assigns.lurking do
      Room.speak(socket.assigns.room, socket.assigns.participant_id, nil, body)
    end

    {:noreply, assign(socket, draft: "")}
  end

  @impl true
  def handle_info({:party_line, %{type: :message} = message}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
  end

  def handle_info({:party_line, %{type: :presence} = presence}, socket) do
    %{event: event, participant: participant} = presence

    roster =
      case event do
        :left ->
          Enum.reject(socket.assigns.roster, &(&1.participant_id == participant.participant_id))

        _joined_or_announced ->
          if Enum.any?(socket.assigns.roster, &(&1.participant_id == participant.participant_id)) do
            socket.assigns.roster
          else
            socket.assigns.roster ++ [participant]
          end
      end

    {:noreply, assign(socket, roster: roster)}
  end

  # humans don't bid; ignore director traffic defensively
  def handle_info({:party_line, _event}, socket), do: {:noreply, socket}

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
            somewhere, a conversation is already happening.
            pick up the receiver.
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
    <div class="retro-desktop">
      <pre class="retro-crash retro-directory" aria-hidden="true">{@directory}</pre>
      <pre class="retro-crash retro-directory retro-directory--right" aria-hidden="true">{@directory}</pre>
      <div class="retro-window retro-window--app">
        <div class="retro-titlebar">
          <.link navigate={~p"/"} class="retro-close" aria-label="hang up, back to the exchange"></.link>
          <span class="retro-titlebar-title">
            ☎ {@room_id} — tonight: {@topic}
          </span>
        </div>

        <div class="retro-app-main">
          <div class="retro-chatcol">
            <div :if={@lurking} class="retro-lurkbar">
              <span>you're lurking — nobody can hear you breathe</span>
              <button phx-click="announce" class="retro-btn">clear your throat</button>
            </div>

            <ul id="messages" phx-update="stream" class="retro-chatlog" phx-hook=".ScrollToBottom">
              <li
                :for={{dom_id, message} <- @streams.messages}
                id={dom_id}
                class={[
                  "retro-chatline",
                  message.sender.kind == :operator && "retro-chatline--operator",
                  message.sender.kind != :operator &&
                    mentions_me?(message, @participant_id) && "retro-chatline--me"
                ]}
              >
                <.chat_line message={message} />
              </li>
              <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToBottom">
                export default {
                  mounted() { this.el.scrollTop = this.el.scrollHeight },
                  updated() { this.el.scrollTop = this.el.scrollHeight }
                }
              </script>
            </ul>

            <form id="speak-form" phx-submit="speak" phx-change="draft" class="retro-inputrow">
              <input
                type="text"
                name="body"
                value={@draft}
                placeholder={
                  if @lurking,
                    do: "clear your throat to speak…",
                    else: "say something (@name to address someone)"
                }
                disabled={@lurking}
                autocomplete="off"
                class="retro-input"
              />
              <button type="submit" class="retro-btn" disabled={@lurking}>send</button>
            </form>
          </div>

          <aside class="retro-roster">
            <h2>on the line</h2>
            <ul>
              <li :for={p <- @roster}>
                <span class={["retro-dot", dot_class(p.kind)]}></span>
                {p.name}
                <span :if={p.kind == :bot} class="retro-badge">bot</span>
                <span :if={p.kind == :operator} class="retro-badge">host</span>
                <span :if={p.participant_id == @participant_id} style="opacity:.6; font-size:.75rem;">
                  (you)
                </span>
              </li>
            </ul>
          </aside>
        </div>

        <div class="retro-statusbar">
          <span>connected · {@room_id}{hosted_suffix(@roster)}</span>
          <span>{length(@roster)} on the line</span>
        </div>
      </div>
    </div>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # The operator is the voice of the exchange: a host line, not a speaker.
  # It renders centered and name-less; every other kind keeps the Name: body
  # form. Mentions stay highlighted in both.
  defp chat_line(%{message: %{sender: %{kind: :operator}}} = assigns) do
    ~H"""
    <span class="retro-operator-line">{highlight_mentions(@message)}</span>
    """
  end

  defp chat_line(assigns) do
    ~H"""
    <span class={["retro-chatname", @message.sender.kind == :bot && "retro-chatname--bot"]}>
      {@message.sender.name}
    </span>
    <span :if={@message.sender.kind == :bot} class="retro-badge">bot</span>: {highlight_mentions(
      @message
    )}
    """
  end

  defp dot_class(:bot), do: "retro-dot--bot"
  defp dot_class(:operator), do: "retro-dot--operator"
  defp dot_class(_), do: "retro-dot--human"

  defp hosted_suffix(roster) do
    if Enum.any?(roster, &(&1.kind == :operator)), do: " · hosted line", else: ""
  end

  # The desktop behind the window is a page torn from the exchange's phone
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
