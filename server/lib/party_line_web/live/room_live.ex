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
    <div class="min-h-screen flex items-center justify-center bg-base-200">
      <div class="card bg-base-100 shadow-xl w-96">
        <div class="card-body items-center text-center">
          <h1 class="card-title text-3xl">☎ party line</h1>
          <p class="text-sm opacity-70">
            somewhere, a conversation is already happening. pick up the receiver.
          </p>
          <form phx-submit="dial" class="w-full mt-4 flex flex-col gap-3">
            <input
              type="text"
              name="name"
              value={@name}
              placeholder="who's calling?"
              autocomplete="off"
              class="input input-bordered w-full"
            />
            <button type="submit" class="btn btn-primary w-full">dial in</button>
          </form>
          <p :if={@error} class="text-error text-sm mt-2">{@error}</p>
        </div>
      </div>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-base-200">
      <header class="navbar bg-base-100 shadow-sm px-4">
        <div class="flex-1">
          <span class="text-lg font-bold">☎ party line</span>
          <span class="ml-3 text-sm opacity-70">
            {@room_id} — tonight: <em>{@topic}</em>
          </span>
        </div>
        <div :if={@lurking} class="flex items-center gap-2">
          <span class="text-sm opacity-70">you're lurking — nobody can see you</span>
          <button phx-click="announce" class="btn btn-primary btn-sm">clear your throat</button>
        </div>
      </header>

      <div class="flex flex-1 overflow-hidden">
        <main class="flex-1 flex flex-col">
          <ul
            id="messages"
            phx-update="stream"
            class="flex-1 overflow-y-auto p-4 space-y-2"
            phx-hook=".ScrollToBottom"
          >
            <li :for={{dom_id, message} <- @streams.messages} id={dom_id} class="chat chat-start">
              <div class="chat-header text-xs opacity-60">
                {message.sender.name}
                <span :if={message.sender.kind == :bot} class="badge badge-ghost badge-xs ml-1">
                  bot
                </span>
              </div>
              <div class={[
                "chat-bubble",
                message.sender.kind == :bot && "chat-bubble-neutral",
                mentions_me?(message, @participant_id) && "ring-2 ring-primary"
              ]}>
                {highlight_mentions(message)}
              </div>
            </li>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToBottom">
              export default {
                mounted() { this.el.scrollTop = this.el.scrollHeight },
                updated() { this.el.scrollTop = this.el.scrollHeight }
              }
            </script>
          </ul>

          <form id="speak-form" phx-submit="speak" phx-change="draft" class="p-4 bg-base-100 flex gap-2">
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
              class="input input-bordered flex-1"
            />
            <button type="submit" class="btn btn-primary" disabled={@lurking}>send</button>
          </form>
        </main>

        <aside class="w-56 bg-base-100 border-l border-base-300 p-4 overflow-y-auto">
          <h2 class="text-xs uppercase tracking-wide opacity-60 mb-3">on the line</h2>
          <ul class="space-y-2">
            <li :for={p <- @roster} class="flex items-center gap-2 text-sm">
              <span class={[
                "w-2 h-2 rounded-full",
                (p.kind == :bot && "bg-success") || "bg-primary"
              ]}>
              </span>
              {p.name}
              <span :if={p.kind == :bot} class="badge badge-ghost badge-xs">bot</span>
              <span :if={p.participant_id == @participant_id} class="opacity-50 text-xs">
                (you)
              </span>
            </li>
          </ul>
        </aside>
      </div>
    </div>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp mentions_me?(%{mentions: mentions}, participant_id),
    do: Enum.any?(mentions, &(&1.participant_id == participant_id))

  # Bold the exact @-mentions the server recognized — names may contain
  # spaces, so split on the full "@Name" strings, not on tokens.
  defp highlight_mentions(%{body: body, mentions: []}), do: body

  defp highlight_mentions(%{body: body, mentions: mentions}) do
    pattern =
      mentions
      |> Enum.map(&Regex.escape("@" <> &1.name))
      |> Enum.join("|")

    regex = Regex.compile!("(#{pattern})", "iu")
    highlighted = MapSet.new(mentions, &String.downcase("@" <> &1.name))

    body
    |> String.split(regex, include_captures: true)
    |> Enum.map(fn part ->
      if MapSet.member?(highlighted, String.downcase(part)) do
        Phoenix.HTML.raw([
          "<span class=\"font-semibold text-primary\">",
          Phoenix.HTML.html_escape(part) |> Phoenix.HTML.safe_to_string(),
          "</span>"
        ])
      else
        part
      end
    end)
  end
end
