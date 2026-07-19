defmodule PartyLineWeb.PipelineController do
  @moduledoc """
  HTTP surface for the pipeline-shard catalog. A `serve-shard` daemon registers
  its slice, heartbeats to stay listed, and deregisters on exit. `index` is the
  public read — assembled pipelines, no addresses. `lease` hands an
  authenticated caller (a driver) the ordered endpoints + secrets for a ready
  pipeline.

  Envelope: `{"ok": true, "data": ...}` / `{"ok": false, "error": ...}`.
  """

  use PartyLineWeb, :controller

  alias PartyLine.Pipelines

  def register(conn, params) do
    case Pipelines.register(conn.assigns.did, params) do
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
    case Pipelines.heartbeat(id, conn.assigns.did) do
      :ok ->
        json(conn, %{ok: true, data: %{id: id}})

      {:error, :unknown} ->
        conn |> put_status(:not_found) |> json(%{ok: false, error: "unknown shard"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{ok: false, error: "not your shard"})
    end
  end

  def deregister(conn, %{"id" => id}) do
    :ok = Pipelines.deregister(id, conn.assigns.did)
    send_resp(conn, :no_content, "")
  end

  def index(conn, _params) do
    # already the public projection — assembled pipelines, never a shard address.
    json(conn, %{ok: true, data: %{pipelines: Pipelines.pipelines()}})
  end

  def lease(conn, %{"model" => model}) do
    case Pipelines.lease(model) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{ok: false, error: "no complete pipeline for that model"})

      stages ->
        json(conn, %{ok: true, data: %{model: model, stages: stages}})
    end
  end

  def lease(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{ok: false, error: "model is required"})
  end
end
