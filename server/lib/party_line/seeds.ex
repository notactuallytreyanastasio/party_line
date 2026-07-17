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

  @doc "A random twisted topic, or nil if the corpus is empty."
  def topic(server \\ @name), do: GenServer.call(server, :topic)

  @doc "How many prompts are loaded."
  def count(server \\ @name), do: GenServer.call(server, :count)

  # ── server ──────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path) || default_path()
    {:ok, %{topics: load(path)}}
  end

  @impl true
  def handle_call(:topic, _from, %{topics: []} = state), do: {:reply, nil, state}

  def handle_call(:topic, _from, %{topics: topics} = state),
    do: {:reply, Enum.random(topics), state}

  def handle_call(:count, _from, state), do: {:reply, length(state.topics), state}

  # ── corpus ──────────────────────────────────────────────────────────────

  defp default_path do
    Application.get_env(:party_line, :seeds_path) ||
      Path.expand("../../data/seeder/prompts.jsonl", __DIR__)
  end

  defp load(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&twist_line/1)
        |> Enum.uniq()

      {:error, _} ->
        []
    end
  end

  defp twist_line(line) do
    with {:ok, %{"title" => title, "subreddit" => sub}} <- Jason.decode(line),
         true <- sub in @known,
         laundered = launder(title),
         true <- laundered != "" do
      [twist(sub, laundered)]
    else
      _ -> []
    end
  end

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
