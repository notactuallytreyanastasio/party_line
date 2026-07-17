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

  describe "rephrased corpus ({topic, label} lines)" do
    setup do
      lines = [
        %{topic: "what would you rename the moon", label: "none"},
        %{topic: "the exchange rules on: borrowed lawnmowers", label: "none"},
        %{topic: "a spicy one", label: "nsfw"},
        %{topic: "a grim one", label: "heavy"}
      ]

      seeds = seeds_from_lines(Enum.map_join(lines, "\n", &Jason.encode!/1))
      %{seeds: seeds}
    end

    test "default topic/2 serves only label none — nsfw/heavy stay out", %{seeds: seeds} do
      drawn = for _ <- 1..40, do: Seeds.topic(seeds)

      assert drawn |> Enum.uniq() |> Enum.sort() ==
               ["the exchange rules on: borrowed lawnmowers", "what would you rename the moon"]
    end

    test "label filters: :all, a list, and count", %{seeds: seeds} do
      assert Seeds.count(seeds) == 4
      assert Seeds.count(seeds, labels: [:none]) == 2
      assert Seeds.count(seeds, labels: ["none", "heavy"]) == 3
      assert Seeds.topic(seeds, labels: ["nsfw"]) == "a spicy one"
    end

    test "topic is nil when no topic matches the requested labels", %{seeds: seeds} do
      assert Seeds.topic(seeds, labels: ["mystery"]) == nil
    end

    test "a rephrased topic that still names the source is dropped, not served" do
      lines = [
        %{topic: "my pregnant wife found my secret reddit account", label: "none"},
        %{topic: "tried pivoting a cynicism subreddit toward wholesomeness", label: "none"},
        %{topic: "what if r/somewhere and u/someone had a baby", label: "none"},
        %{topic: "the exchange rules on: AITA for eating the last tamale", label: "none"},
        %{topic: "chased clout for upvotes on the front page", label: "none"},
        %{topic: "the one clean survivor", label: "none"}
      ]

      seeds = seeds_from_lines(Enum.map_join(lines, "\n", &Jason.encode!/1))

      assert Seeds.count(seeds, labels: :all) == 1
      assert Seeds.topic(seeds) == "the one clean survivor"
    end

    test "prose that merely looks like an acronym survives the source-tell guard" do
      # "'til"/"til" is until, and "co-op" is not a poster callout — a
      # case-insensitive \bTIL\b / \bOP\b guard would eat both
      lines = [
        %{topic: "nobody noticed til the very end of the party", label: "none"},
        %{topic: "the co-op intern invented fake bus stops", label: "none"},
        %{topic: "most insane real-world karma you ever watched land", label: "none"}
      ]

      seeds = seeds_from_lines(Enum.map_join(lines, "\n", &Jason.encode!/1))

      assert Seeds.count(seeds, labels: :all) == 3
    end
  end

  describe "corpus loading edge cases" do
    test "topics differing only by case dedupe to one" do
      lines = [
        %{topic: "The Moon Is A Lie", label: "none"},
        %{topic: "the moon is a lie", label: "none"}
      ]

      seeds = seeds_from_lines(Enum.map_join(lines, "\n", &Jason.encode!/1))
      assert Seeds.count(seeds) == 1
    end

    test "malformed lines are skipped without crashing" do
      contents =
        Enum.join(
          [
            "this is not json {",
            Jason.encode!(%{unrelated: "shape"}),
            Jason.encode!(%{topic: 123, label: "none"}),
            Jason.encode!(%{topic: "the one survivor", label: "none"})
          ],
          "\n"
        )

      seeds = seeds_from_lines(contents)
      assert Seeds.count(seeds) == 1
      assert Seeds.topic(seeds) == "the one survivor"
    end

    test "BestofRedditorUpdates twists into whatever happened with" do
      line = Jason.encode!(%{subreddit: "BestofRedditorUpdates", title: "the wedding cake saga"})
      seeds = seeds_from_lines(line)

      assert Seeds.topic(seeds) == "whatever happened with: the wedding cake saga"
    end

    test "a raw title that launders to nothing is dropped, not loaded empty" do
      line = Jason.encode!(%{subreddit: "AskReddit", title: "AMA [deleted]"})
      seeds = seeds_from_lines(line)

      assert Seeds.count(seeds) == 0
      assert Seeds.topic(seeds) == nil
    end
  end

  defp seeds_from_lines(contents) do
    path =
      Path.join(System.tmp_dir!(), "seeds-case-#{System.unique_integer([:positive])}.jsonl")

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    {:ok, seeds} = Seeds.start_link(name: nil, path: path)
    seeds
  end
end
