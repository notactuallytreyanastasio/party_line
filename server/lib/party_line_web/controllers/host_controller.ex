defmodule PartyLineWeb.HostController do
  @moduledoc """
  HTTP surface for the tailnet LLM-host catalog. Daemons register, then
  heartbeat to stay listed, and deregister on a clean exit. `index` is the
  public read — it never exposes the internal catalog id, only the fields
  a caller needs to reach the host.

  All responses share the ecosystem envelope: `{"ok": true, "data": ...}`
  on success, `{"ok": false, "error": ...}` on failure.
  """

  use PartyLineWeb, :controller

  alias PartyLine.Hosts

  def register(conn, params) do
    case Hosts.register(params) do
      {:ok, %{id: id, ttl_seconds: ttl}} ->
        conn
        |> put_status(:created)
        |> json(%{ok: true, data: %{id: id, ttl_seconds: ttl}})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{ok: false, error: to_string(reason)})
    end
  end

  def heartbeat(conn, %{"id" => id}) do
    case Hosts.heartbeat(id) do
      :ok ->
        json(conn, %{ok: true, data: %{id: id}})

      {:error, :unknown} ->
        conn
        |> put_status(:not_found)
        |> json(%{ok: false, error: "unknown host"})
    end
  end

  def deregister(conn, %{"id" => id}) do
    :ok = Hosts.deregister(id)
    send_resp(conn, :no_content, "")
  end

  def index(conn, _params) do
    # `Hosts.list/0` is already the public projection — no url, no secret. A
    # lent model is reached through the exchange's /v1, never by its address.
    json(conn, %{ok: true, data: %{hosts: Hosts.list()}})
  end
end
