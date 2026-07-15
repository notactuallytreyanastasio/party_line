defmodule PartyLine.Mentions do
  @moduledoc """
  Server-side @-mention parsing. The server is the only mention parser in
  the system: bodies arrive as raw text and every consumer (bots, LiveView)
  receives the structured `mentions` list, so nobody re-parses strings.

  Roster names may contain spaces ("Horse Dentist", "erowid smoothie"), so
  this is not a token matcher: at each `@` the roster is tried longest name
  first, case-insensitively, and a match must end at a word boundary —
  `@horse dentist,` matches Horse Dentist; `@Horse Dentistry` does not.
  """

  @doc """
  Returns the roster entries mentioned in `body`, in order of first
  appearance, deduplicated.

  `roster` is a list of maps with `:name` (and whatever else — entries are
  returned as given).
  """
  def parse(body, roster) do
    by_length = Enum.sort_by(roster, &(-String.length(&1.name)))

    case String.split(body, "@") do
      [_no_ats] ->
        []

      [_before | segments] ->
        segments
        |> Enum.map(&match_roster(&1, by_length))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.name)
    end
  end

  defp match_roster(segment, by_length) do
    Enum.find(by_length, fn entry -> prefix_match?(segment, entry.name) end)
  end

  defp prefix_match?(segment, name) do
    len = String.length(name)
    candidate = String.slice(segment, 0, len)

    String.downcase(candidate) == String.downcase(name) and
      boundary?(String.slice(segment, len, 1))
  end

  # the char right after the name must not continue a word
  defp boundary?(""), do: true
  defp boundary?(char), do: not (char =~ ~r/[\p{L}\p{N}_]/u)
end
