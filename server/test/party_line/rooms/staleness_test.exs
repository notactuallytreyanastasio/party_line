defmodule PartyLine.Rooms.StalenessTest do
  use ExUnit.Case, async: true

  alias PartyLine.Rooms.Staleness

  @threshold 0.35

  # A transcript from the wild that has curled in on itself: the bots keep
  # re-treading the same stock phrases ("never-ending dance of urban
  # evolution", "Christopher Walken GIFs").
  @stale [
    "the never-ending dance of urban evolution continues, with raccoons",
    "raccoons continue the never-ending dance of urban evolution",
    "it is, truly, a never-ending dance of urban evolution",
    "the never-ending dance of urban evolution never actually ends",
    "honestly the never-ending dance of urban evolution is eternal",
    "such a never-ending dance of urban evolution we get to witness"
  ]

  @stale_walken [
    "Christopher Walken GIFs are the never-ending dance of urban evolution",
    "the never-ending dance of urban evolution is really Christopher Walken GIFs",
    "Christopher Walken GIFs, the never-ending dance of urban evolution, yes",
    "truly Christopher Walken GIFs are a never-ending dance of urban evolution",
    "again the never-ending dance of urban evolution, Christopher Walken GIFs",
    "Christopher Walken GIFs remain the never-ending dance of urban evolution"
  ]

  # Six people genuinely talking about six different things.
  @varied [
    "has anyone tried the new taco place down on fifth street",
    "jupiter should be visible just after sunset if the clouds hold off",
    "my neighbor swears a fox made off with her ceramic garden gnome",
    "the crossroads legend always leaves me checking the back seat",
    "decaf is a crime against every diner counter in the country",
    "opossums are basically small misunderstood dinosaurs and I respect them"
  ]

  test "a transcript circling one phrase is stale" do
    assert Staleness.stale?(@stale, @threshold)
    assert Staleness.stale?(@stale_walken, @threshold)
  end

  test "a varied conversation is not stale" do
    refute Staleness.stale?(@varied, @threshold)
  end

  test "identical messages are maximally stale" do
    assert Staleness.stale?(List.duplicate("say the same thing again", 4), @threshold)
  end

  test "short parroted lines still register as stale" do
    # under three words each — the unigram fallback keeps them from vanishing
    assert Staleness.stale?(["me too", "me too", "me too"], @threshold)
  end

  test "too few messages is never stale" do
    refute Staleness.stale?([], @threshold)
    refute Staleness.stale?(["a lonely singular thought with no pair"], @threshold)
  end

  test "blank bodies contribute nothing and cannot trip staleness" do
    refute Staleness.stale?(["", "   ", "..."], @threshold)
  end

  test "the threshold is respected" do
    # two half-overlapping messages sit at Jaccard 0.5
    bodies = [
      "the never-ending dance of urban evolution continues with raccoons",
      "raccoons continue the never-ending dance of urban evolution"
    ]

    assert Staleness.stale?(bodies, 0.4)
    refute Staleness.stale?(bodies, 0.6)
  end
end
