defmodule PartyLine.API.Client do
  @moduledoc """
  A first-class client for our own completion API — the dogfood.

  It's `LangChain.ChatModels.ChatOpenAI` pointed at *our* `/v1/chat/completions`
  with a `pl-…` key. Because a real OpenAI client library drives it, this both
  proves the endpoint is genuinely OpenAI-compatible and gives the rest of the
  app (and scripts, and tests) a clean way to ask the exchange over HTTP rather
  than reaching into `Asks` directly.

      {:ok, text} =
        PartyLine.API.Client.chat("why do cats knead?", api_key: "pl-…")
  """
  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Message
  alias LangChain.Message.ContentPart

  @doc """
  Send a prompt (a string, or a list of `%{role:, content:}` maps) to the API.

  Options:

    * `:api_key` — a `pl-…` bearer token (required)
    * `:model` — the model/persona to target (default `"party-line-auto"`)
    * `:endpoint` — full URL to the completions route (default: this app's)

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec chat(String.t() | [map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(prompt, opts) do
    model =
      ChatOpenAI.new!(%{
        endpoint: Keyword.get(opts, :endpoint, default_endpoint()),
        api_key: Keyword.fetch!(opts, :api_key),
        model: Keyword.get(opts, :model, "party-line-auto"),
        stream: false
      })

    case ChatOpenAI.call(model, to_messages(prompt), []) do
      {:ok, reply} -> {:ok, extract(reply)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_messages(prompt) when is_binary(prompt), do: [Message.new_user!(prompt)]

  defp to_messages(messages) when is_list(messages) do
    Enum.map(messages, fn
      %Message{} = m -> m
      %{role: "system", content: c} -> Message.new_system!(c)
      %{role: "assistant", content: c} -> Message.new_assistant!(c)
      %{role: _, content: c} -> Message.new_user!(c)
    end)
  end

  defp extract(%Message{content: content}),
    do: content |> ContentPart.content_to_string() |> to_string()

  defp extract([%Message{} = m | _]), do: extract(m)
  defp extract(other), do: to_string(other)

  defp default_endpoint do
    Application.get_env(:party_line, :api_client_endpoint) ||
      PartyLineWeb.Endpoint.url() <> "/v1/chat/completions"
  end
end
