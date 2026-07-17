defmodule PartyLine.API.Chat do
  @moduledoc """
  The bridge from a chat-completion request to the federated exchange.

  A request is a list of `LangChain.Message`s and a requested `model`. This
  flattens the conversation into a single prompt, turns the model field into a
  routing `Agents.Target`, hands it to `Asks`, and blocks the calling process
  until the answer (or a failure) lands — `Asks` guarantees every ask ends in
  a message, so the wait always terminates.

  The reply is a persona on a stranger's laptop, not a faceless model: the
  `decision` rides back so the caller can attribute the answer (which persona,
  which model, running where) and admit any routing note.
  """
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias PartyLine.Asks

  @families ~w(gpt-oss gemma llama qwen mistral phi)
  @auto ~w(auto default party-line party-line-auto)
  # a little past the Asks correlator's own 90s timeout — Asks always sends a
  # terminal message, so this only fires if the correlator itself went away
  @receive_timeout 120_000

  @type result :: %{content: String.t(), decision: map(), prompt_tokens: non_neg_integer()}
  @type handle :: %{ask_id: String.t(), decision: map(), prompt_tokens: non_neg_integer()}

  @doc """
  Kick off a completion without waiting. The calling process becomes the asker,
  so it will receive `{:answer_delta, ask_id, delta}` messages (if the host
  streams) and exactly one terminal `{:answered, ask_id, body, decision}` or
  `{:ask_failed, ask_id, reason}`. Returns a `handle` (ask id, routing
  decision, prompt-token estimate) or `{:error, :nobody_online}`.

  Use this for streaming, where the controller drives its own relay loop; use
  `complete/2` for the blocking, non-streaming case.
  """
  @spec start([Message.t()], keyword()) :: {:ok, handle()} | {:error, :nobody_online}
  def start(messages, opts \\ []) do
    asks = Keyword.get(opts, :asks, Asks)
    prompt = flatten(messages)

    case Asks.ask(asks, self(), prompt, target: target_for(opts[:model])) do
      {:error, :nobody_online} ->
        {:error, :nobody_online}

      {:ok, ask_id, decision} ->
        {:ok, %{ask_id: ask_id, decision: decision, prompt_tokens: estimate_tokens(prompt)}}
    end
  end

  @doc """
  Run a completion and block for the answer. `messages` is a list of
  `LangChain.Message`. Options:

    * `:model` — the requested model string (persona, family, or an "auto" alias)
    * `:asks` — the correlator server (default `PartyLine.Asks`), injectable for tests
    * `:timeout` — receive-side safety timeout in ms

  Returns `{:ok, result}`, or `{:error, :nobody_online | :timeout | :agent_gone}`.
  Any streamed deltas are consumed and ignored — the final `answered` body is
  authoritative for the non-streaming shape.
  """
  @spec complete([Message.t()], keyword()) :: {:ok, result()} | {:error, atom()}
  def complete(messages, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @receive_timeout)

    with {:ok, handle} <- start(messages, opts) do
      await(handle, timeout)
    end
  end

  @doc "Turn a requested model string into a routing target."
  @spec target_for(String.t() | nil) :: PartyLine.Agents.Target.t()
  def target_for(nil), do: %{}

  def target_for(model) when is_binary(model) do
    down = String.downcase(String.trim(model))

    cond do
      down == "" or down in @auto -> %{}
      family = Enum.find(@families, &String.contains?(down, &1)) -> %{model: family}
      true -> %{persona: model}
    end
  end

  # ── waiting ────────────────────────────────────────────────────────────────

  defp await(%{ask_id: ask_id} = handle, timeout) do
    receive do
      # a streamed token in the non-streaming path: swallow it, the final
      # answered body is authoritative
      {:answer_delta, ^ask_id, _delta} ->
        await(handle, timeout)

      {:answered, ^ask_id, body, decision} ->
        {:ok, %{content: body, decision: decision, prompt_tokens: handle.prompt_tokens}}

      {:ask_failed, ^ask_id, reason} ->
        {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end

  # ── prompt shaping ───────────────────────────────────────────────────────

  # Flatten a chat into one prompt the persona can answer. System turns become
  # a leading instruction block; the rest is a labelled transcript ending on the
  # latest user turn, which is what the model is being asked to continue.
  defp flatten(messages) do
    {system, turns} = Enum.split_with(messages, &(&1.role == :system))

    system_block =
      system
      |> Enum.map(&text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    transcript = Enum.map_join(turns, "\n", fn m -> "#{label(m.role)}: #{text(m)}" end)

    [system_block, transcript]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp label(:assistant), do: "Assistant"
  defp label(:tool), do: "Tool"
  defp label(_), do: "User"

  defp text(%Message{content: content}),
    do: content |> ContentPart.content_to_string() |> to_string()

  # rough, honest: we don't get real token counts back from a stranger's laptop,
  # so usage is a ~4-chars-per-token estimate, not a billing figure
  defp estimate_tokens(text), do: max(1, div(String.length(text), 4))

  @doc "The same rough estimate, exposed for rendering completion usage."
  @spec estimate_tokens_public(String.t()) :: non_neg_integer()
  def estimate_tokens_public(text), do: estimate_tokens(text)
end
