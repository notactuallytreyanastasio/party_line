defmodule PartyLineWeb.Plugs.CurrentIdentity do
  @moduledoc """
  Surfaces the signed-in atproto identity to browser pages.

  Reads the signed `pl_session` cookie the OAuth callback set, resolves it to
  the stored tokens, and stashes the `did`/`handle` in both the session (so
  LiveViews see it on mount) and the assigns (so plain views do). Absent or
  expired, it's a no-op — pages just render signed-out.
  """
  import Plug.Conn

  alias PartyLine.ATProto.Sessions

  @behaviour Plug
  @cookie "pl_session"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_cookies(conn, signed: [@cookie])

    with id when is_binary(id) <- conn.cookies[@cookie],
         %{did: did} = tokens <- Sessions.get_tokens(id) do
      handle = Map.get(tokens, :handle) || did

      conn
      |> put_session("did", did)
      |> put_session("handle", handle)
      |> assign(:current_did, did)
      |> assign(:current_handle, handle)
    else
      _ ->
        conn
        |> assign(:current_did, nil)
        |> assign(:current_handle, nil)
    end
  end
end
