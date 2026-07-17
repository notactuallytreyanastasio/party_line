defmodule PartyLine.Agents.Target do
  @moduledoc """
  What the asker asked for, if anything.

  A request is a wish, not a filter. "is there something that's 24B or more"
  means *try* — the exchange is strangers' laptops, and the honest answer when
  nothing that big is on is "no, here's what is" rather than a refusal or,
  worse, silently handing it to a 4B and saying nothing.

  Constraints are comparative on purpose. `min_params_b: 24` is a thing a
  person actually wants; `power: :large` is a bucket the router invented for
  its own convenience, and buckets can't express "24 or more".

  Parsing is a regex over the surface of the message, for the same reason
  `PartyLine.Agents.Complexity` is: the server never runs inference, so it
  cannot ask a model what you meant. It reads the obvious phrasings and
  ignores the rest — a missed ask costs you a default route, not an error.
  """

  @type t :: %{
          optional(:persona) => String.t(),
          optional(:model) => String.t(),
          optional(:min_params_b) => float(),
          optional(:min_quant_bits) => non_neg_integer(),
          optional(:min_tokens_per_s) => float()
        }

  @doc """
  Read an ask out of a message. `%{}` when nobody asked for anything, which is
  the overwhelmingly common case and must stay free.

      iex> Target.parse("is there something that's 24B or more?")
      %{min_params_b: 24.0}

      iex> Target.parse("ask horse dentist what he thinks")
      %{persona: "horse dentist"}
  """
  @spec parse(String.t(), [String.t()]) :: t()
  def parse(message, known_personas \\ []) when is_binary(message) do
    down = String.downcase(message)

    %{}
    |> put(:min_params_b, size_floor(down))
    |> put(:min_quant_bits, quant_floor(down))
    |> put(:min_tokens_per_s, speed_floor(down))
    |> put(:model, model_name(down))
    |> put(:persona, persona(down, known_personas))
  end

  @doc "Does this card satisfy the ask? All stated constraints must hold."
  @spec satisfies?(PartyLine.Agents.Card.t(), t()) :: boolean()
  def satisfies?(card, target) do
    Enum.all?(target, fn
      {:persona, name} -> String.downcase(card.persona) == String.downcase(name)
      {:model, model} -> String.contains?(String.downcase(card.model), model)
      {:min_params_b, b} -> card.params_b >= b
      # An unclaimed quant (0) fails every floor: a host that won't say how
      # badly it squashed its model doesn't get the job someone asked to be
      # unsquashed. Silence loses, here as everywhere.
      {:min_quant_bits, q} -> card.quant_bits >= q
      {:min_tokens_per_s, t} -> card.tokens_per_s >= t
      {_unknown, _} -> false
    end)
  end

  @doc "How to tell a person what they asked for, when we couldn't find it."
  @spec describe(t()) :: String.t()
  def describe(target) when map_size(target) == 0, do: "anything"

  def describe(target) do
    target
    |> Enum.map(fn
      {:persona, name} -> name
      {:model, model} -> "a #{model} model"
      {:min_params_b, b} -> "#{trim(b)}B or bigger"
      {:min_quant_bits, q} -> "#{quant_word(q)} or better"
      {:min_tokens_per_s, t} -> "#{trim(t)} tok/s or faster"
    end)
    |> Enum.join(", ")
  end

  # ── reading the ask ──────────────────────────────────────────────────────

  # "24B or more", "24b+", "at least 24B", "bigger than 24b", "70B model"
  defp size_floor(down) do
    cond do
      m = Regex.run(~r/(\d+(?:\.\d+)?)\s*b\b\s*(?:or (?:more|bigger|above|higher)|\+|plus)/, down) ->
        num(m)

      m =
          Regex.run(
            ~r/(?:at least|minimum|min|bigger than|larger than|more than|over)\s+(\d+(?:\.\d+)?)\s*b\b/,
            down
          ) ->
        num(m)

      m = Regex.run(~r/\b(\d+(?:\.\d+)?)\s*b\b\s+(?:model|machine|parameter)/, down) ->
        num(m)

      true ->
        nil
    end
  end

  # Quantization is a quality ask, not a size one: a 20B squashed to 4-bit and
  # the same 20B at 8-bit are different products, so "8bit or better" has to be
  # sayable independently of "20B or more".
  #
  # "8bit or better", "at least 8-bit", "fp16", "not quantized", "unquantized"
  defp quant_floor(down) do
    cond do
      Regex.match?(~r/\b(?:un(?:-|\s)?quantized|not quantized|full[- ]precision)\b/, down) ->
        16

      Regex.match?(~r/\b(?:fp32|float32)\b/, down) ->
        32

      Regex.match?(~r/\b(?:fp16|bf16|f16|float16|half[- ]precision)\b/, down) ->
        16

      m = Regex.run(~r/(\d+)[-\s]?bits?\b\s*(?:or (?:better|higher|above|more)|\+)/, down) ->
        bits(m)

      m = Regex.run(~r/(?:at least|minimum|min)\s+(\d+)[-\s]?bits?\b/, down) ->
        bits(m)

      m = Regex.run(~r/\b(?:q|int)(\d)\b\s*(?:or (?:better|higher))/, down) ->
        bits(m)

      true ->
        nil
    end
  end

  defp bits([_, n]), do: String.to_integer(n)

  defp quant_word(32), do: "fp32"
  defp quant_word(16), do: "fp16"
  defp quant_word(q), do: "#{q}bit"

  # "at least 30 tok/s", "faster than 30 tokens/s"
  defp speed_floor(down) do
    case Regex.run(
           ~r/(?:at least|faster than|over|more than)\s+(\d+(?:\.\d+)?)\s*(?:tok|tokens?)\s*\/?\s*s/,
           down
         ) do
      nil -> nil
      m -> num(m)
    end
  end

  # "a gpt-oss model", "use llama", "on gemma"
  defp model_name(down) do
    case Regex.run(
           ~r/\b(?:use|using|on|with|a|an)\s+(gpt-oss|gemma|llama|qwen|mistral|phi)\b/,
           down
         ) do
      [_, name] -> name
      _ -> nil
    end
  end

  # Only names we actually know: matching arbitrary capitalized words would
  # turn every mention of a proper noun into a routing constraint.
  defp persona(down, known) do
    Enum.find(known, fn name -> String.contains?(down, String.downcase(name)) end)
  end

  defp num([_, n]), do: String.to_float(if String.contains?(n, "."), do: n, else: n <> ".0")

  defp put(target, _key, nil), do: target
  defp put(target, key, value), do: Map.put(target, key, value)

  defp trim(f) do
    if f == Float.round(f), do: f |> trunc() |> Integer.to_string(), else: Float.to_string(f)
  end
end
