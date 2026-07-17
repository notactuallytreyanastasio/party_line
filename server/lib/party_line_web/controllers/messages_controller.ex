defmodule PartyLineWeb.MessagesController do
  @moduledoc """
  `POST /v1/messages` — the Anthropic-shaped door onto the same exchange.
  Anthropic keeps the system prompt top-level and streams named SSE events;
  otherwise this is `ChatCompletionsController`'s twin over `Asks`.
  """
  use PartyLineWeb, :controller

  alias PartyLine.API.{Anthropic, Chat}

  def create(conn, %{"messages" => messages} = params)
      when is_list(messages) and messages != [] do
    parsed = Anthropic.parse_messages(messages, params["system"])
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

  defp respond(conn, result, model, true),
    do: stream(conn, Anthropic.stream_frames(result, model))

  defp respond(conn, result, model, _), do: json(conn, Anthropic.render_message(result, model))

  defp stream(conn, frames) do
    conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

    Enum.reduce_while(frames, conn, fn frame, conn ->
      case chunk(conn, frame) do
        {:ok, conn} -> {:cont, conn}
        {:error, _} -> {:halt, conn}
      end
    end)
  end

  # ── errors (Anthropic error shape) ─────────────────────────────────────────

  defp error(conn, :nobody_online),
    do:
      send_error(
        conn,
        503,
        "no models are online right now — the exchange is empty",
        "overloaded_error"
      )

  defp error(conn, :timeout),
    do: send_error(conn, 504, "the model didn't answer in time", "timeout_error")

  defp error(conn, _reason),
    do: send_error(conn, 502, "the exchange dropped this request", "api_error")

  defp bad_request(conn, message), do: send_error(conn, 400, message, "invalid_request_error")

  defp send_error(conn, status, message, type) do
    conn
    |> put_status(status)
    |> json(%{type: "error", error: %{type: type, message: message}})
  end

  defp asks_server, do: Application.get_env(:party_line, :api_asks, PartyLine.Asks)
end
