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

  @doc "The named SSE events for a streamed Anthropic answer."
  @spec stream_frames(Chat.result(), String.t() | nil) :: [String.t()]
  def stream_frames(result, requested_model) do
    msg_id = id()
    model = model_label(result, requested_model)
    out_tokens = Chat.estimate_tokens_public(result.content)

    start =
      event("message_start", %{
        type: "message_start",
        message: %{
          id: msg_id,
          type: "message",
          role: "assistant",
          model: model,
          content: [],
          stop_reason: nil,
          stop_sequence: nil,
          usage: %{input_tokens: result.prompt_tokens, output_tokens: 0}
        }
      })

    block_start =
      event("content_block_start", %{
        type: "content_block_start",
        index: 0,
        content_block: %{type: "text", text: ""}
      })

    deltas =
      result.content
      |> chunk_text()
      |> Enum.map(fn piece ->
        event("content_block_delta", %{
          type: "content_block_delta",
          index: 0,
          delta: %{type: "text_delta", text: piece}
        })
      end)

    block_stop = event("content_block_stop", %{type: "content_block_stop", index: 0})

    message_delta =
      event("message_delta", %{
        type: "message_delta",
        delta: %{stop_reason: "end_turn", stop_sequence: nil},
        usage: %{output_tokens: out_tokens}
      })

    stop = event("message_stop", %{type: "message_stop"})

    [start, block_start] ++ deltas ++ [block_stop, message_delta, stop]
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp model_label(%{decision: %{card: card}}, _requested), do: card.persona
  defp model_label(_result, requested), do: requested || "party-line-auto"

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
