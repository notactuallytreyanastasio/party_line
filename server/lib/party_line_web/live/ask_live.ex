defmodule PartyLineWeb.AskLive do
  @moduledoc """
  The third facet: a plain chat box over a network of strangers' laptops.

  It looks like every other chat interface on earth, which is the joke and also
  the point — underneath, nothing runs here. Every answer is generated on
  someone else's machine by a model they chose, wearing a personality they
  wrote, and the byline says so.

  The asking is non-blocking on purpose: `Asks.ask/4` returns the routing
  decision immediately, so the page can say *who* it's asking before a single
  token exists, and the answer arrives later as a message. A LiveView that
  blocked on a 20B waking up on a laptop would be a LiveView that looked broken.
  """

  use PartyLineWeb, :live_view

  alias PartyLine.Agents.{Card, Router}
  alias PartyLine.Asks
  alias PartyLine.Bots

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(5_000, :refresh_exchange)

    {:ok,
     socket
     |> assign(page_title: "ask the exchange", turns: [], draft: "", waiting: nil)
     |> assign(exchange: Bots.cards())}
  end

  @impl true
  def handle_event("draft", %{"body" => body}, socket) do
    {:noreply, assign(socket, draft: body)}
  end

  def handle_event("ask", %{"body" => body}, socket) do
    body = String.trim(body)

    cond do
      body == "" ->
        {:noreply, socket}

      socket.assigns.waiting ->
        {:noreply, socket}

      true ->
        case Asks.ask(Asks, self(), body, []) do
          {:error, :nobody_online} ->
            {:noreply,
             socket
             |> assign(draft: "")
             |> add(%{
               role: :system,
               body: "nobody's on the exchange right now — no laptops, no answers.",
               note: nil
             })}

          {:ok, ask_id, decision} ->
            {:noreply,
             socket
             |> assign(draft: "", waiting: %{id: ask_id, decision: decision})
             |> add(%{role: :you, body: body, note: nil})}
        end
    end
  end

  @impl true
  def handle_info({:answered, ask_id, body, decision}, socket) do
    case socket.assigns.waiting do
      %{id: ^ask_id} ->
        {:noreply,
         socket
         |> assign(waiting: nil)
         |> add(%{
           role: :agent,
           body: body,
           byline: Card.byline(decision.card),
           note: Router.note(decision)
         })}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:ask_failed, ask_id, reason}, socket) do
    case socket.assigns.waiting do
      %{id: ^ask_id, decision: decision} ->
        {:noreply,
         socket
         |> assign(waiting: nil)
         |> add(%{role: :system, body: failure(reason, decision), note: nil})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(:refresh_exchange, socket) do
    {:noreply, assign(socket, exchange: Bots.cards())}
  end

  defp add(socket, turn), do: assign(socket, turns: socket.assigns.turns ++ [turn])

  defp failure(:timeout, decision),
    do:
      "#{decision.card.persona} never answered — their machine may have gone to sleep. try again?"

  defp failure(reason, _decision), do: "the exchange dropped this one (#{reason}). try again?"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="retro-desktop retro-desktop--ask">
      <.skin_toggle />
      <div class="retro-window retro-window--ask">
        <div class="retro-titlebar">
          <.link navigate={~p"/"} class="retro-close" aria-label="close"></.link>
          <span class="retro-titlebar-title">▣ ask the exchange</span>
        </div>

        <div class="retro-askbar">
          <span :if={@exchange == []}>nobody's on — start a harness</span>
          <span :if={@exchange != []}>
            {length(@exchange)} {ngettext_agent(length(@exchange))} on the exchange:
            <span :for={c <- @exchange} class="retro-askchip" title={Card.byline(c)}>
              {c.persona} <small>{size(c)}</small>
            </span>
          </span>
        </div>

        <div class="retro-asklog" id="asklog" phx-hook=".Stick">
          <p :if={@turns == []} class="retro-askempty">
            ask anything. it gets routed to whoever's online — you don't pick, unless
            you do: try <em>"is there something that's 24B or more?"</em>
            or <em>"8bit or better"</em>.
          </p>

          <div :for={turn <- @turns} class={"retro-askturn retro-askturn--#{turn.role}"}>
            <div :if={turn.role == :agent} class="retro-askbyline">{turn[:byline]}</div>
            <div class="retro-askbody">{turn.body}</div>
            <div :if={turn[:note]} class="retro-asknote">{turn.note}</div>
          </div>

          <div :if={@waiting} class="retro-askturn retro-askturn--agent">
            <div class="retro-askbyline">{Card.byline(@waiting.decision.card)}</div>
            <div class="retro-askbody retro-askwaiting">
              thinking<span class="retro-askdots">…</span>
            </div>
            <div :if={Router.note(@waiting.decision)} class="retro-asknote">
              {Router.note(@waiting.decision)}
            </div>
          </div>
        </div>

        <form class="retro-askform" phx-submit="ask" phx-change="draft">
          <input
            type="text"
            name="body"
            value={@draft}
            autocomplete="off"
            placeholder={if @waiting, do: "waiting on an answer…", else: "ask the exchange…"}
            disabled={@waiting != nil}
            class="retro-input"
          />
          <button type="submit" class="retro-btn" disabled={@waiting != nil}>ask</button>
        </form>

        <div class="retro-statusbar">
          <span>nothing runs here · every answer is someone else's machine</span>
          <span>{length(@turns)} turns</span>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Stick">
        export default {
          mounted() { this.pin() },
          updated() { this.pin() },
          pin() { this.el.scrollTop = this.el.scrollHeight }
        }
      </script>
    </div>
    """
  end

  # a host that never said how big it is shows a shrug, not a zero
  defp size(%Card{params_b: b}) when b == 0.0, do: "?"
  defp size(%Card{} = c), do: "#{trunc(c.params_b)}B"

  defp ngettext_agent(1), do: "agent"
  defp ngettext_agent(_), do: "agents"
end
