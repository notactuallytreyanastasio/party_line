defmodule PartyLineWeb.MessagesController do
  @moduledoc """
  `POST /v1/messages` — the Anthropic-shaped door onto the same exchange.
  Anthropic keeps the system prompt top-level and streams named SSE events;
  otherwise this is `ChatCompletionsController`'s twin over `Asks`.
  """
  use PartyLineWeb, :controller

  alias PartyLine.API.{Anthropic, Chat}

  @stream_timeout 120_000

  def create(conn, %{"messages" => messages} = params)
      when is_list(messages) and messages != [] do
    parsed = Anthropic.parse_messages(messages, params["system"])
    model = params["model"]

    if params["stream"] == true do
      stream(conn, parsed, model)
    else
      complete(conn, parsed, model)
    end
  end

  def create(conn, _params) do
    bad_request(conn, "`messages` is required and must be a non-empty array")
  end

  defp complete(conn, parsed, model) do
    case Chat.complete(parsed, model: model, asks: asks_server()) do
      {:ok, result} -> json(conn, Anthropic.render_message(result, model))
      {:error, reason} -> error(conn, reason)
    end
  end

  defp stream(conn, parsed, model) do
    case Chat.start(parsed, model: model, asks: asks_server()) do
      {:error, reason} ->
        error(conn, reason)

      {:ok, handle} ->
        ctx = Anthropic.stream_ctx(Anthropic.model_label(handle, model), handle.prompt_tokens)
        conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

        case chunk(conn, Anthropic.stream_open(ctx)) do
          {:ok, conn} -> relay(conn, handle.ask_id, ctx, "")
          {:error, _} -> conn
        end
    end
  end

  defp relay(conn, ask_id, ctx, acc) do
    receive do
      {:answer_delta, ^ask_id, delta} ->
        case chunk(conn, Anthropic.stream_delta(ctx, delta)) do
          {:ok, conn} -> relay(conn, ask_id, ctx, acc <> delta)
          {:error, _} -> conn
        end

      # a host that didn't stream sends the whole body here
      {:answered, ^ask_id, body, _decision} when acc == "" ->
        emit(conn, [
          Anthropic.stream_delta(ctx, body),
          Anthropic.stream_close(ctx, Chat.estimate_tokens_public(body))
        ])

      {:answered, ^ask_id, _body, _decision} ->
        emit(conn, [Anthropic.stream_close(ctx, Chat.estimate_tokens_public(acc))])

      {:ask_failed, ^ask_id, _reason} ->
        emit(conn, [Anthropic.stream_close(ctx, Chat.estimate_tokens_public(acc))])
    after
      @stream_timeout ->
        emit(conn, [Anthropic.stream_close(ctx, Chat.estimate_tokens_public(acc))])
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
