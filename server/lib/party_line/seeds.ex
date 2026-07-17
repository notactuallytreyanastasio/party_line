defmodule PartyLine.Seeds do
  @moduledoc """
  Feeds the network. Loads the discussion-prompt corpus
  (`tools/seeder/harvest.py` → `data/seeder/prompts.jsonl`) and hands the
  Operator fresh topics so the lines never run dry — reddit questions "with
  a twist," so they read as party-line prompts rather than reposts.

  Loaded once at boot into memory; `topic/0` returns a random twisted
  prompt. If the corpus file is absent (fresh checkout, harvest not run),
  it's simply empty and the Operator falls back to its built-in deck.
  """
  use GenServer

  @name __MODULE__

  @known ~w(AskReddit AITAH tifu todayilearned BestofRedditorUpdates)

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))

  @doc """
  A random topic string, or nil if the corpus is empty. By default only
  `label: "none"` topics (safe for any room); pass `labels: :all` to
  include nsfw/heavy, or a list like `["none", "heavy"]`.
  """
  def topic(server \\ @name, opts \\ []),
    do: GenServer.call(server, {:topic, opts[:labels] || [:none]})

  @doc "How many prompts are loaded (optionally filtered by label)."
  def count(server \\ @name, opts \\ []),
    do: GenServer.call(server, {:count, opts[:labels] || :all})

  # ── server ──────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path) || default_path()
    {:ok, %{topics: load(path)}}
  end

  @impl true
  def handle_call({:topic, labels}, _from, state) do
    case filter(state.topics, labels) do
      [] -> {:reply, nil, state}
      picks -> {:reply, Enum.random(picks).topic, state}
    end
  end

  def handle_call({:count, labels}, _from, state),
    do: {:reply, length(filter(state.topics, labels)), state}

  defp filter(topics, :all), do: topics

  defp filter(topics, labels) do
    wanted = labels |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()
    Enum.filter(topics, &MapSet.member?(wanted, &1.label))
  end

  # ── corpus ──────────────────────────────────────────────────────────────

  # Prefer the LLM-rephrased, labelled corpus (topics.jsonl) — it's already
  # laundered and tagged. Fall back to the raw harvest (prompts.jsonl),
  # which we scrub + twist mechanically on load.
  defp default_path do
    Application.get_env(:party_line, :seeds_path) ||
      first_existing([
        Path.expand("../../../data/seeder/topics.jsonl", __DIR__),
        Path.expand("../../../data/seeder/prompts.jsonl", __DIR__)
      ])
  end

  defp first_existing(paths), do: Enum.find(paths, List.last(paths), &File.exists?/1)

  defp load(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&parse_line/1)
        |> Enum.uniq_by(&String.downcase(&1.topic))

      {:error, _} ->
        []
    end
  end

  defp parse_line(line) do
    case Jason.decode(line) do
      # Rephrased corpus: {topic, label}. The rephraser is told to strip every
      # source tell, but it's an LLM and one slips through now and then.
      # Laundering would mangle the sentence ("my secret reddit account" →
      # "my secret people account"), so a leaky topic is dropped instead — the
      # corpus is large and regenerable, and a tell in the room is worse.
      {:ok, %{"topic" => topic, "label" => label}} when is_binary(topic) ->
        if source_tell?(topic), do: [], else: [%{topic: topic, label: label}]

      # raw harvest: scrub + twist mechanically, tag as unknown-safety "none"
      {:ok, %{"title" => title, "subreddit" => sub}} when sub in @known ->
        case launder(title) do
          "" -> []
          laundered -> [%{topic: twist(sub, laundered), label: "none"}]
        end

      _ ->
        []
    end
  end

  # A rephrased topic that still names the source. Acronyms match
  # case-sensitively so prose "'til" / "co-op" don't read as TIL / OP.
  @source_tell ~r/reddit|subreddit|\br\/\w|\bu\/\w|upvote|downvote|\[(deleted|removed)\]|\bTL;?DR\b/i
  @source_acronym ~r/\b(AITA|AITAH|TIFU|OOP|BORU)\b/

  defp source_tell?(topic),
    do: Regex.match?(@source_tell, topic) or Regex.match?(@source_acronym, topic)

  # Scrub every trace of the source: no subreddit/user callouts, no reddit
  # vocabulary, no meta-cruft. The topics must read as native party-line
  # prompts, not obvious reposts.
  defp launder(title) do
    title
    |> String.replace(~r/\br\/[A-Za-z0-9_]+/, "")
    |> String.replace(~r/\bu\/[A-Za-z0-9_-]+/, "someone")
    |> String.replace(~r/\breddit(ors?)?\b/i, "people")
    |> String.replace(~r/\bsubreddit\b/i, "group")
    |> String.replace(~r/\bthis sub\b/i, "here")
    |> String.replace(~r/\bOP\b/, "the poster")
    |> String.replace(~r/\bAMA\b/i, "")
    |> String.replace(~r/\[(deleted|removed|serious)\]/i, "")
    |> String.replace(~r/\bedit\s*\d*\s*:/i, "")
    |> String.replace(~r/\bTL;?DR\b/i, "")
    |> String.replace(~r/\bkarma\b/i, "clout")
    |> String.replace(~r/\bupvote[sd]?\b/i, "")
    |> String.replace(~r/\s{2,}/, " ")
    |> String.trim()
  end

  # subreddit → how the title reads as a party-line room topic
  defp twist("AskReddit", t), do: ensure_question(t)
  defp twist("AITAH", t), do: "the exchange rules on: #{strip_aita(t)}"
  defp twist("tifu", t), do: "confession booth: #{strip_tifu(t)}"
  defp twist("todayilearned", t), do: "is this even true — #{strip_til(t)}"
  defp twist("BestofRedditorUpdates", t), do: "whatever happened with: #{t}"

  defp ensure_question(t), do: if(String.ends_with?(t, "?"), do: t, else: t <> "?")

  defp strip_aita(t), do: t |> String.replace(~r/^AITA(H)?\s*(for)?\s*/i, "") |> cap()
  defp strip_tifu(t), do: t |> String.replace(~r/^TIFU\s*(by)?\s*/i, "") |> cap()
  defp strip_til(t), do: t |> String.replace(~r/^TIL\s*(that)?\s*/i, "") |> cap()

  defp cap(""), do: ""
  defp cap(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest
end
