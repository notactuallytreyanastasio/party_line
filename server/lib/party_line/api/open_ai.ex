defmodule PartyLine.API.OpenAI do
  @moduledoc """
  The OpenAI `/v1/chat/completions` wire shape.

  Requests come in as OpenAI JSON; this parses the `messages` array into the
  canonical `LangChain.Message` list the rest of the API speaks, and renders
  the answer back into either a `chat.completion` object or the
  `chat.completion.chunk` SSE stream. Usage counts are rough estimates — a
  stranger's laptop doesn't report tokens — and the answering persona is
  attributed under a non-standard `party_line` key clients can ignore.
  """
  alias LangChain.Message
  alias PartyLine.API.Chat

  @doc "Parse an OpenAI `messages` array into LangChain messages."
  @spec parse_messages(list()) :: [Message.t()]
  def parse_messages(raw) when is_list(raw), do: Enum.map(raw, &to_message/1)
  def parse_messages(_), do: []

  defp to_message(%{"role" => role, "content" => content}), do: build(role, text(content))
  defp to_message(%{"content" => content}), do: build("user", text(content))
  defp to_message(_), do: Message.new_user!("")

  defp build("system", t), do: Message.new_system!(t)
  defp build("assistant", t), do: Message.new_assistant!(t)
  defp build(_role, t), do: Message.new_user!(t)

  # OpenAI content is a string or an array of typed parts (text/image/…). We
  # keep the text; images have nowhere to go on a text-only exchange.
  defp text(content) when is_binary(content), do: content

  defp text(parts) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{"type" => "text", "text" => t} -> t
      %{"text" => t} when is_binary(t) -> t
      t when is_binary(t) -> t
      _ -> ""
    end)
  end

  defp text(_), do: ""

  # ── rendering ──────────────────────────────────────────────────────────────

  @doc "Render a completed answer as a `chat.completion` object."
  @spec render_completion(Chat.result(), String.t() | nil) :: map()
  def render_completion(result, requested_model) do
    completion_tokens = Chat.estimate_tokens_public(result.content)

    %{
      id: id("chatcmpl"),
      object: "chat.completion",
      created: System.system_time(:second),
      model: model_label(result, requested_model),
      choices: [
        %{
          index: 0,
          message: %{role: "assistant", content: result.content},
          finish_reason: "stop"
        }
      ],
      usage: %{
        prompt_tokens: result.prompt_tokens,
        completion_tokens: completion_tokens,
        total_tokens: result.prompt_tokens + completion_tokens
      },
      party_line: attribution(result.decision)
    }
  end

  @doc """
  A streaming context — one stable id/created/model shared by every chunk of a
  single streamed response, as the OpenAI stream format requires.
  """
  @spec stream_ctx(String.t()) :: map()
  def stream_ctx(model),
    do: %{id: id("chatcmpl"), created: System.system_time(:second), model: model}

  @doc "Opening chunk: the assistant role delta."
  def stream_start(ctx),
    do: chunk(ctx, [%{index: 0, delta: %{role: "assistant"}, finish_reason: nil}])

  @doc "A content chunk carrying one token/run of streamed text."
  def stream_delta(ctx, text),
    do: chunk(ctx, [%{index: 0, delta: %{content: text}, finish_reason: nil}])

  @doc "Closing chunk: the stop delta."
  def stream_stop(ctx), do: chunk(ctx, [%{index: 0, delta: %{}, finish_reason: "stop"}])

  @doc "The final `[DONE]` sentinel."
  def stream_done, do: "data: [DONE]\n\n"

  @doc """
  All SSE frames for an answer already in hand — start, the body in a few
  chunks, stop, `[DONE]`. Used when the whole body arrives at once (a
  non-streaming host, or a test).
  """
  @spec stream_frames(Chat.result(), String.t() | nil) :: [String.t()]
  def stream_frames(result, requested_model),
    do: stream_frames_for(result.content, model_label(result, requested_model))

  @doc "All SSE frames for a bare `content` string under `model` — used by the host proxy."
  @spec stream_frames_for(String.t(), String.t()) :: [String.t()]
  def stream_frames_for(content, model) do
    ctx = stream_ctx(model)
    deltas = content |> chunk_text() |> Enum.map(&stream_delta(ctx, &1))
    [stream_start(ctx)] ++ deltas ++ [stream_stop(ctx), stream_done()]
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # the answering persona is the honest "model" label; echo the request only
  # when the caller didn't get routed somewhere more specific
  @doc "The model label to advertise for an answer: the answering persona."
  def model_label(%{decision: %{card: card}}, _requested), do: card.persona
  def model_label(_result, requested), do: requested || "party-line-auto"

  defp chunk(ctx, choices) do
    frame(%{
      id: ctx.id,
      object: "chat.completion.chunk",
      created: ctx.created,
      model: ctx.model,
      choices: choices
    })
  end

  defp attribution(%{card: card} = decision) do
    %{
      persona: card.persona,
      model: card.model,
      byline: PartyLine.Agents.Card.byline(card),
      note: PartyLine.Agents.Router.note(decision)
    }
  end

  # ~40-char pieces: enough chunks to look like a stream, few enough to stay cheap
  defp chunk_text(text) do
    case text |> String.codepoints() |> Enum.chunk_every(40) |> Enum.map(&Enum.join/1) do
      [] -> [""]
      pieces -> pieces
    end
  end

  defp frame(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  defp id(prefix),
    do: prefix <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
end
