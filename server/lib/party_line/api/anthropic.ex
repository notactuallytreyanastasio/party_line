defmodule PartyLine.API.Anthropic do
  @moduledoc """
  The Anthropic `/v1/messages` wire shape.

  Anthropic keeps the system prompt as a top-level field rather than a message
  role, and its stream is a sequence of named SSE events
  (`message_start` … `message_stop`) rather than OpenAI's `data:`-only chunks.
  Otherwise this mirrors `PartyLine.API.OpenAI`: parse to canonical
  `LangChain.Message`s, render the answer, attribute the persona.
  """
  alias LangChain.Message
  alias PartyLine.API.Chat

  @doc "Parse Anthropic `messages` + top-level `system` into LangChain messages."
  @spec parse_messages(list(), String.t() | nil) :: [Message.t()]
  def parse_messages(raw, system) when is_list(raw) do
    prefix = if is_binary(system) and system != "", do: [Message.new_system!(system)], else: []
    prefix ++ Enum.map(raw, &to_message/1)
  end

  def parse_messages(_, _), do: []

  defp to_message(%{"role" => "assistant", "content" => content}),
    do: Message.new_assistant!(text(content))

  defp to_message(%{"content" => content}), do: Message.new_user!(text(content))
  defp to_message(_), do: Message.new_user!("")

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

  @doc "Render a completed answer as an Anthropic `message` object."
  @spec render_message(Chat.result(), String.t() | nil) :: map()
  def render_message(result, requested_model) do
    %{
      id: id(),
      type: "message",
      role: "assistant",
      model: model_label(result, requested_model),
      content: [%{type: "text", text: result.content}],
      stop_reason: "end_turn",
      stop_sequence: nil,
      usage: %{
        input_tokens: result.prompt_tokens,
        output_tokens: Chat.estimate_tokens_public(result.content)
      },
      party_line: attribution(result.decision)
    }
  end

  @doc "A streaming context shared by every event of one streamed message."
  @spec stream_ctx(String.t(), non_neg_integer()) :: map()
  def stream_ctx(model, input_tokens),
    do: %{id: id(), model: model, input_tokens: input_tokens}

  @doc "Opening events: `message_start` then `content_block_start`."
  def stream_open(ctx) do
    start =
      event("message_start", %{
        type: "message_start",
        message: %{
          id: ctx.id,
          type: "message",
          role: "assistant",
          model: ctx.model,
          content: [],
          stop_reason: nil,
          stop_sequence: nil,
          usage: %{input_tokens: ctx.input_tokens, output_tokens: 0}
        }
      })

    block_start =
      event("content_block_start", %{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "text", text: ""}
      })

    start <> block_start
  end

  @doc "A `content_block_delta` carrying one token/run of streamed text."
  def stream_delta(ctx, text) do
    _ = ctx

    event("content_block_delta", %{
      type: "content_block_delta",
      index: 0,
      delta: %{type: "text_delta", text: text}
    })
  end

  @doc "Closing events: block stop, the message stop_reason + output usage, message_stop."
  def stream_close(ctx, output_tokens) do
    _ = ctx
    block_stop = event("content_block_stop", %{type: "content_block_stop", index: 0})

    message_delta =
      event("message_delta", %{
        type: "message_delta",
        delta: %{stop_reason: "end_turn", stop_sequence: nil},
        usage: %{output_tokens: output_tokens}
      })

    stop = event("message_stop", %{type: "message_stop"})
    block_stop <> message_delta <> stop
  end

  @doc "All events for an answer already in hand (non-streaming host, or a test)."
  @spec stream_frames(Chat.result(), String.t() | nil) :: [String.t()]
  def stream_frames(result, requested_model) do
    ctx = stream_ctx(model_label(result, requested_model), result.prompt_tokens)
    deltas = result.content |> chunk_text() |> Enum.map(&stream_delta(ctx, &1))
    out = Chat.estimate_tokens_public(result.content)
    [stream_open(ctx)] ++ deltas ++ [stream_close(ctx, out)]
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  @doc "The model label to advertise: the answering persona."
  def model_label(%{decision: %{card: card}}, _requested), do: card.persona
  def model_label(_result, requested), do: requested || "party-line-auto"

  defp attribution(%{card: card} = decision) do
    %{
      persona: card.persona,
      model: card.model,
      byline: PartyLine.Agents.Card.byline(card),
      note: PartyLine.Agents.Router.note(decision)
    }
  end

  defp chunk_text(text) do
    case text |> String.codepoints() |> Enum.chunk_every(40) |> Enum.map(&Enum.join/1) do
      [] -> [""]
      pieces -> pieces
    end
  end

  defp event(name, data), do: "event: #{name}\ndata: " <> Jason.encode!(data) <> "\n\n"

  defp id, do: "msg_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
end
