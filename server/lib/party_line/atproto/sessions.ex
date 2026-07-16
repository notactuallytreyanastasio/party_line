defmodule PartyLine.ATProto.Sessions do
  @moduledoc """
  In-flight and established atproto OAuth sessions, keyed by an opaque id
  that lives in the user's signed cookie. In-memory for now (ETS via a
  GenServer) — tokens are DPoP-bound and short-lived, and a v0.2 auth
  prototype doesn't need durable token storage yet.

  Two states:
  - **pending** (`put_pending/1`): the crypto + PKCE + state stashed between
    `/oauth/login` and the callback.
  - **authed** (`put_tokens/2`): the exchanged tokens after callback.
  """

  use GenServer

  @name __MODULE__

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, @name))

  def put_pending(session) do
    id = token()
    GenServer.call(@name, {:put, {:pending, id}, session})
    id
  end

  def take_pending(id), do: GenServer.call(@name, {:take, {:pending, id}})

  def put_tokens(id \\ nil, tokens) do
    id = id || token()
    GenServer.call(@name, {:put, {:authed, id}, tokens})
    id
  end

  def get_tokens(id), do: GenServer.call(@name, {:get, {:authed, id}})
  def delete_tokens(id), do: GenServer.call(@name, {:delete, {:authed, id}})

  # ── server ──────────────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:put, key, value}, _from, state), do: {:reply, :ok, Map.put(state, key, value)}
  def handle_call({:get, key}, _from, state), do: {:reply, Map.get(state, key), state}

  def handle_call({:take, key}, _from, state) do
    {value, state} = Map.pop(state, key)
    {:reply, value, state}
  end

  def handle_call({:delete, key}, _from, state), do: {:reply, :ok, Map.delete(state, key)}

  defp token, do: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
