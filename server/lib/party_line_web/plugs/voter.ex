defmodule PartyLineWeb.Plugs.Voter do
  @moduledoc """
  Ensures a stable per-browser voter id in the session, so board votes
  persist across reloads without requiring a login. Anonymous by design;
  a signed-in atproto identity can supersede it later.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, "boards_voter") do
      nil ->
        id = "anon-" <> (9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
        put_session(conn, "boards_voter", id)

      _ ->
        conn
    end
  end
end
