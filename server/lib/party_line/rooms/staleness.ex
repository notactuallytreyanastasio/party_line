defmodule PartyLine.Rooms.Staleness do
  @moduledoc """
  Pure staleness detection: is the recent conversation going in circles?

  A room is "stale" when the last handful of messages keep re-treading the
  same phrases. We measure that as the mean pairwise Jaccard similarity of
  the messages' word-trigram sets — a repetitive transcript shares many
  trigrams (high overlap), a varied one shares few.

  Word-trigrams (sliding windows of three consecutive words) capture phrasing
  rather than mere vocabulary, so two messages that share topical nouns but
  say genuinely different things still read as varied.
  """

  @doc """
  True when there are at least two messages with content and the mean
  pairwise word-trigram Jaccard similarity strictly exceeds `threshold`.
  """
  @spec stale?([String.t()], number()) :: boolean()
  def stale?(bodies, threshold) when is_list(bodies) do
    sets =
      bodies
      |> Enum.map(&trigrams/1)
      |> Enum.reject(&(MapSet.size(&1) == 0))

    case pairs(sets) do
      [] ->
        false

      ps ->
        similarities = Enum.map(ps, fn {a, b} -> jaccard(a, b) end)
        mean(similarities) > threshold
    end
  end

  # Sliding windows of three words. Messages shorter than three words fall
  # back to the set of their words, so short parroted lines ("me too", "me
  # too") still register as overlapping rather than vanishing to empty.
  defp trigrams(body) do
    words =
      body
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

    case words do
      [] ->
        MapSet.new()

      ws when length(ws) < 3 ->
        MapSet.new(ws)

      ws ->
        ws
        |> Enum.chunk_every(3, 1, :discard)
        |> Enum.map(&Enum.join(&1, " "))
        |> MapSet.new()
    end
  end

  defp jaccard(a, b) do
    inter = MapSet.size(MapSet.intersection(a, b))
    union = MapSet.size(MapSet.union(a, b))
    if union == 0, do: 0.0, else: inter / union
  end

  # All unordered pairs of a list.
  defp pairs([]), do: []
  defp pairs([h | t]), do: Enum.map(t, &{h, &1}) ++ pairs(t)

  defp mean([]), do: 0.0
  defp mean(nums), do: Enum.sum(nums) / length(nums)
end
