defmodule PartyLineWeb.DialController do
  use PartyLineWeb, :controller

  @doc """
  The stumble-upon entry point. M1: stub matchmaker, one default room.
  """
  def dial(conn, params) do
    json(conn, PartyLine.Rooms.dial(params))
  end
end
