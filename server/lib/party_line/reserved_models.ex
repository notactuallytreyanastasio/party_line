defmodule PartyLine.ReservedModels do
  @moduledoc """
  The model ids the exchange routes itself — the router aliases
  (`party-line-auto`, `auto`, …) and the model families (`gpt-oss`, `gemma`, …
  from `Agents.Target`).

  A lent host or a pipeline shard may not register under one of these, or it
  could shadow the default route / a family and intercept prompts. This is the
  single source of truth so the host catalog, the pipeline catalog, and the
  completion router can't drift out of agreement (a family added to two of
  three would open exactly the shadowing hole the list exists to close).
  """

  @reserved ~w(party-line-auto auto default party-line gpt-oss gemma llama qwen mistral phi)

  @doc "The reserved ids (all lowercase)."
  def all, do: @reserved

  @doc "Is `name` a reserved model id? Case-insensitive; accepts any binary."
  def reserved?(name) when is_binary(name), do: String.downcase(name) in @reserved
  def reserved?(_), do: false
end
