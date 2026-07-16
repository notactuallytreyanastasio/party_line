defmodule PartyLine.DMs do
  @moduledoc """
  Direct messages between humans on the exchange. Ephemeral by design —
  history lives in memory (capped per conversation) for the life of the
  server, like a phone call, not an archive. Delivery is PubSub: each
  user subscribes to `buddy:<name>` and receives `{:dm, other, message}`.

  Clips (quoted bot exchanges) travel as DMs with `kind: :clip` and the
  quoted lines in `quoted`, so the window can render them as a quote block.
  """

  use GenServer

  @name __MODULE__
  @keep 200

  def start_link(opts) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, @name))
  end

  def send_dm(server \\ @name, from, to, body, opts \\ []) do
    GenServer.call(server, {:send, from, to, body, opts})
  end

  def history(server \\ @name, a, b) do
    GenServer.call(server, {:history, a, b})
  end

  def topic(buddy_name), do: "buddy:#{buddy_name}"

  # ── Server ────────────────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{convos: %{}}}

  @impl true
  def handle_call({:send, from, to, body, opts}, _from, state) do
    message = %{
      id: "dm-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower),
      from: from,
      to: to,
      body: body,
      kind: Keyword.get(opts, :kind, :text),
      quoted: Keyword.get(opts, :quoted, []),
      ts: DateTime.to_iso8601(DateTime.utc_now())
    }

    key = convo_key(from, to)

    state =
      update_in(state.convos[key], fn history ->
        Enum.take([message | history || []], @keep)
      end)

    for name <- Enum.uniq([from, to]) do
      Phoenix.PubSub.broadcast(
        PartyLine.PubSub,
        topic(name),
        {:dm, other(name, message), message}
      )
    end

    {:reply, {:ok, message}, state}
  end

  def handle_call({:history, a, b}, _from, state) do
    {:reply, state.convos |> Map.get(convo_key(a, b), []) |> Enum.reverse(), state}
  end

  defp convo_key(a, b), do: Enum.sort([a, b])

  defp other(name, %{from: name, to: to}), do: to
  defp other(name, %{from: from}) when from != name, do: from
end
