defmodule PartyLine.SeedsTest do
  use ExUnit.Case, async: true

  alias PartyLine.Seeds

  setup do
    path = Path.join(System.tmp_dir!(), "seeds-#{System.unique_integer([:positive])}.jsonl")

    lines = [
      %{subreddit: "AskReddit", title: "What is a lie you tell yourself"},
      %{subreddit: "AITAH", title: "AITA for eating my roommate's leftovers"},
      %{subreddit: "tifu", title: "TIFU by replying all to the whole company"},
      %{subreddit: "todayilearned", title: "TIL that octopuses have three hearts"},
      %{subreddit: "SomeOtherSub", title: "ignored"}
    ]

    File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1))
    on_exit(fn -> File.rm(path) end)
    {:ok, seeds} = Seeds.start_link(name: nil, path: path)
    %{seeds: seeds}
  end

  test "loads and twists prompts, skipping unknown subs", %{seeds: seeds} do
    # 4 known subs → 4 twisted topics (SomeOtherSub dropped)
    assert Seeds.count(seeds) == 4
  end

  test "twists read as room topics, not reposts", %{seeds: seeds} do
    topics = for _ <- 1..40, do: Seeds.topic(seeds)
    all = Enum.uniq(topics)

    assert Enum.any?(all, &String.ends_with?(&1, "?"))
    assert Enum.any?(all, &String.starts_with?(&1, "the exchange rules on:"))
    assert Enum.any?(all, &String.starts_with?(&1, "confession booth:"))
    assert Enum.any?(all, &String.starts_with?(&1, "is this even true"))
    # the AITA/TIFU/TIL prefixes are stripped before twisting
    refute Enum.any?(all, &(&1 =~ ~r/AITA|TIFU|TIL/))
  end

  test "reddit references are scrubbed from every topic" do
    path = Path.join(System.tmp_dir!(), "seeds-scrub-#{System.unique_integer([:positive])}.jsonl")

    lines = [
      %{subreddit: "AskReddit", title: "Redditors of r/AskReddit, what does u/spez think"},
      %{subreddit: "tifu", title: "TIFU by chasing karma and upvotes on this sub"},
      %{subreddit: "AITAH", title: "AITA — EDIT: OP here, the subreddit was right"}
    ]

    File.write!(path, Enum.map_join(lines, "\n", &Jason.encode!/1))
    on_exit(fn -> File.rm(path) end)
    {:ok, seeds} = Seeds.start_link(name: nil, path: path)

    topics = for _ <- 1..30, do: Seeds.topic(seeds)

    for t <- Enum.uniq(topics) do
      refute t =~ ~r/\br\//
      refute t =~ ~r/\bu\/spez/
      refute t =~ ~r/reddit/i
      refute t =~ ~r/subreddit/i
      refute t =~ ~r/karma/i
      refute t =~ ~r/upvote/i
      refute t =~ ~r/\bOP\b/
      refute t =~ ~r/EDIT:/i
    end
  end

  test "missing corpus file yields an empty, harmless seeder" do
    {:ok, empty} = Seeds.start_link(name: nil, path: "/nonexistent/prompts.jsonl")
    assert Seeds.count(empty) == 0
    assert Seeds.topic(empty) == nil
  end
end
