defmodule PartyLineWeb.ChatCompletionsController do
  @moduledoc """
  `POST /v1/chat/completions` — one OpenAI-shaped door onto the whole crowd.
  Auth (`PartyLineWeb.Plugs.ApiAuth`) has already resolved the caller's atproto
  did. The `model` field decides the route:

    * a **lent model** (a neighbor running `serve-llm`) — proxied to their host
      with the exchange's secret, so the caller never touches the host directly;
    * anything else (`party-line-auto`, a persona) — routed to a dialed-in
      persona's machine through `Asks`.

  Either way the answer comes back as a `chat.completion`, or an SSE stream when
  `stream: true`.
  """
  use PartyLineWeb, :controller

  alias PartyLine.API.{Chat, OpenAI}
  alias PartyLine.Hosts

  # a little past the Asks correlator's own timeout — it always sends a terminal
  # message, so this only fires if the correlator itself vanished mid-stream
  @stream_timeout 120_000

  def create(conn, %{"messages" => messages} = params)
      when is_list(messages) and messages != [] do
    model = params["model"]

    case Hosts.served(hosts_server(), model) do
      nil -> persona(conn, OpenAI.parse_messages(messages), model, params["stream"] == true)
      host -> proxy(conn, params, host)
    end
  end

  def create(conn, _params) do
    bad_request(conn, "`messages` is required and must be a non-empty array")
  end

  defp persona(conn, parsed, model, true), do: stream(conn, parsed, model)
  defp persona(conn, parsed, model, false), do: complete(conn, parsed, model)

  # ── proxy a lent model ──────────────────────────────────────────────────────

  # Forward the request to the host with its secret. For now we ask the host
  # non-streaming and re-emit as SSE if the caller wanted a stream (the host
  # never streams to us yet); the caller-facing shape is unchanged.
  defp proxy(conn, params, host) do
    case host_proxy().chat(host, Map.put(params, "stream", false)) do
      {:ok, completion} ->
        tagged = tag(completion, host)

        if params["stream"] == true do
          content = get_in(completion, ["choices", Access.at(0), "message", "content"]) || ""
          model = completion["model"] || host.model
          stream_raw(conn, OpenAI.stream_frames_for(content, model))
        else
          json(conn, tagged)
        end

      {:error, :host_unreachable} ->
        send_error(conn, 502, "the lent model's host is unreachable", "host_unreachable")

      {:error, _reason} ->
        send_error(conn, 502, "the lent model's host returned an error", "host_error")
    end
  end

  defp tag(completion, host) do
    Map.put(completion, "party_line", %{
      "proxied_via" => "exchange",
      "host" => host.name,
      "model" => host.model
    })
  end

  defp complete(conn, parsed, model) do
    case Chat.complete(parsed, model: model, asks: asks_server()) do
      {:ok, result} -> json(conn, OpenAI.render_completion(result, model))
      {:error, reason} -> error(conn, reason)
    end
  end

  # Real streaming: start the ask, then relay each {:answer_delta,…} as an SSE
  # chunk the moment it arrives. Errors before the stream opens stay JSON; once
  # bytes are on the wire we can only close the stream cleanly.
  defp stream(conn, parsed, model) do
    case Chat.start(parsed, model: model, asks: asks_server()) do
      {:error, reason} ->
        error(conn, reason)

      {:ok, handle} ->
        ctx = OpenAI.stream_ctx(OpenAI.model_label(handle, model))
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

        case chunk(conn, OpenAI.stream_start(ctx)) do
          {:ok, conn} -> relay(conn, handle.ask_id, ctx, false)
          {:error, _} -> conn
        end
    end
  end

  defp relay(conn, ask_id, ctx, streamed?) do
    receive do
      {:answer_delta, ^ask_id, delta} ->
        case chunk(conn, OpenAI.stream_delta(ctx, delta)) do
          {:ok, conn} -> relay(conn, ask_id, ctx, true)
          {:error, _} -> conn
        end

      # a host that didn't stream sends the whole body here — emit it in one go
      {:answered, ^ask_id, body, _decision} when not streamed? ->
        emit(conn, [OpenAI.stream_delta(ctx, body), OpenAI.stream_stop(ctx), OpenAI.stream_done()])

      {:answered, ^ask_id, _body, _decision} ->
        emit(conn, [OpenAI.stream_stop(ctx), OpenAI.stream_done()])

      {:ask_failed, ^ask_id, _reason} ->
        emit(conn, [OpenAI.stream_stop(ctx), OpenAI.stream_done()])
    after
      @stream_timeout -> emit(conn, [OpenAI.stream_done()])
    end
  end

  defp emit(conn, frames) do
    Enum.reduce_while(frames, conn, fn frame, conn ->
      case chunk(conn, frame) do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, conn}
      end
    end)
  end

  # open a chunked stream and emit a fixed list of SSE frames (the proxy path)
  defp stream_raw(conn, frames) do
    conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
    emit(conn, frames)
  end

  # ── errors (OpenAI error shape) ─────────────────────────────────────────────

  defp error(conn, :nobody_online),
    do:
      send_error(conn, 503, "no models are online right now — the exchange is empty", "no_models")

  defp error(conn, :timeout),
    do:
      send_error(
        conn,
        504,
        "the model didn't answer in time — its machine may have gone to sleep",
        "timeout"
      )

  defp error(conn, _reason),
    do: send_error(conn, 502, "the exchange dropped this request", "upstream_error")

  defp bad_request(conn, message), do: send_error(conn, 400, message, "invalid_request_error")

  defp send_error(conn, status, message, code) do
    conn
    |> put_status(status)
    |> json(%{error: %{message: message, type: "invalid_request_error", code: code}})
  end

  defp asks_server, do: Application.get_env(:party_line, :api_asks, PartyLine.Asks)
  defp hosts_server, do: Application.get_env(:party_line, :api_hosts, PartyLine.Hosts)
  defp host_proxy, do: Application.get_env(:party_line, :api_host_proxy, PartyLine.API.HostProxy)
end
