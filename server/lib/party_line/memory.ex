defmodule PartyLine.Memory do
  @moduledoc """
  Shared helpers for the room-memory graphs.

  The one thing here worth its own module: turning a room id into the deciduous
  graph id that holds that room's memory. It's a namespace, and the namespace
  is a boundary.
  """

  @room_prefix "plr-"

  @doc """
  The deciduous graph id for a room's shared memory.

  Room ids arrive from a federated bot's join frame (see
  `PartyLineWeb.BotSocket`), so a bot effectively picks the suffix. Prefixing
  with `#{@room_prefix}` — which a room id, being `[a-z0-9][a-z0-9_-]*`, can
  produce only if it *starts* with those exact characters, and the server, not
  the bot, prepends — keeps room graphs in their own namespace on the shared
  daemon. A bot cannot address a human's project graph (`party-line-root`, a
  personal deciduous graph) by naming it, because whatever it sends lands under
  `#{@room_prefix}…` instead.

  Both writers of a room's graph — the server's `Ingest` and a bot's brokered
  `Broker` call — must run the id through here, or they'd write to two
  different graphs.
  """
  @spec room_graph(String.t()) :: String.t()
  def room_graph(room_id) when is_binary(room_id), do: @room_prefix <> room_id
end
