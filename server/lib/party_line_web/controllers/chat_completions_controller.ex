defmodule PartyLineWeb.ChatCompletionsController do
  @moduledoc """
  `POST /v1/chat/completions` — the OpenAI-shaped door onto the federated
  exchange. Auth (`PartyLineWeb.Plugs.ApiAuth`) has already resolved the
  caller's atproto did. We parse the request into canonical messages, route it
  to a persona's machine through `Asks`, and render the answer as a
  `chat.completion` (or an SSE stream when `stream: true`).
  """
  use PartyLineWeb, :controller

  alias PartyLine.API.{Chat, OpenAI}

  def create(conn, %{"messages" => messages} = params)
      when is_list(messages) and messages != [] do
    parsed = OpenAI.parse_messages(messages)
    model = params["model"]

    case Chat.complete(parsed, model: model, asks: asks_server()) do
      {:ok, result} ->
        respond(conn, result, model, params["stream"] == true)

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def create(conn, _params) do
    bad_request(conn, "`messages` is required and must be a non-empty array")
  end

  defp respond(conn, result, model, true), do: stream(conn, OpenAI.stream_frames(result, model))
  defp respond(conn, result, model, _), do: json(conn, OpenAI.render_completion(result, model))

  defp stream(conn, frames) do
    conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

    Enum.reduce_while(frames, conn, fn frame, conn ->
      case chunk(conn, frame) do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, conn}
      end
    end)
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
end
