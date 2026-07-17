defmodule PartyLine.Memory.Broker do
  @moduledoc """
  Lets a leased bot read and write its room's shared memory — without ever
  reaching the deciduous daemon itself.

  A room's graph has many authors on purpose: the server records what was
  *said*, and each persona records what it *made of it*. That is the point of
  putting a decision graph under a chat room rather than a transcript — several
  minds annotating one thread.

  ## Why a broker and not a URL

  Bots run on other people's computers, and the exchange federates
  outbound-only (node 296: no inbound exposure). A leased laptop cannot reach
  our daemon, and handing strangers a daemon token so they could would be a
  worse idea than any convenience it bought. So the bot calls tools over the
  socket it already has, and the server does the talking.

  That indirection is also where the boundary lives. The broker decides two
  things a bot cannot:

    * **which graph** — always the room the bot actually joined. A bot cannot
      name a graph, so it cannot read or scribble on a room it isn't in.
    * **which tools** — append and read. Never destroy.

  ## Append and read, never destroy

  Deciduous exposes `delete_node`, `unlink_nodes`, `update_status`. Those are
  fine for a human curating their own graph and wrong for an anonymous laptop
  editing a room's shared history: "many authors" must not mean "anyone can
  erase what the others remembered". A bot may add to the record and read it
  back. Nothing it does can take anything away.
  """

  alias PartyLine.Memory.Client

  # Everything a persona needs to remember something and find it again — and
  # nothing that can remove what someone else remembered.
  @allowed ~w(add_node link_nodes list_nodes search_nodes show_node get_node_context trace_chain)

  @type result :: {:ok, term()} | {:error, term()}

  @doc "The tools a leased bot may call. Public so the system prompt can't drift from it."
  @spec allowed_tools() :: [String.t()]
  def allowed_tools, do: @allowed

  @doc """
  Run `tool` against `room_id`'s graph on behalf of a bot.

  The caller supplies the room — never the bot — so a bot's reach stops at the
  room it joined. Returns `{:error, {:tool_not_allowed, tool}}` for anything
  outside `allowed_tools/0`, and `{:error, :memory_disabled}` when no daemon is
  configured, which is the common case in test and for anyone running the
  exchange without one.
  """
  @spec call(String.t(), String.t(), map(), keyword()) :: result()
  def call(room_id, tool, args, opts \\ []) do
    config = Keyword.get_lazy(opts, :config, &config/0)

    cond do
      # The boundary is checked first, on purpose: whether a tool is allowed is
      # not a function of whether a daemon happens to be configured. Answering
      # "memory is off" to `delete_node` would make the refusal look incidental,
      # and would flip to a real delete the day someone turns memory on.
      tool not in @allowed ->
        {:error, {:tool_not_allowed, tool}}

      is_nil(config) ->
        {:error, :memory_disabled}

      true ->
        run(%{config | graph: PartyLine.Memory.room_graph(room_id)}, tool, args)
    end
  end

  # A bot's first write is what creates a room's graph if the server hasn't
  # yet — the same ensure the ingest does, so neither has to go first.
  defp run(config, tool, args) do
    with :ok <- Client.ensure_graph(config) do
      Client.tool(config, tool, args)
    end
  end

  defp config do
    env = Application.get_env(:party_line, :memory, [])

    if Keyword.get(env, :enabled, false) do
      %{api_url: Keyword.get(env, :api_url), token: Keyword.get(env, :token), graph: nil}
    end
  end
end
