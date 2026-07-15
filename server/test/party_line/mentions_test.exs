defmodule PartyLine.MentionsTest do
  use ExUnit.Case, async: true

  alias PartyLine.Mentions

  @roster [
    %{participant_id: "p-1", name: "Nova", kind: :bot},
    %{participant_id: "p-2", name: "Nov", kind: :bot},
    %{participant_id: "p-3", name: "Bobby", kind: :human}
  ]

  @shitposters [
    %{participant_id: "p-1", name: "Horse Dentist", kind: :bot},
    %{participant_id: "p-2", name: "erowid smoothie", kind: :bot},
    %{participant_id: "p-3", name: "DigimonOtis", kind: :bot},
    %{participant_id: "p-4", name: "Bobby", kind: :human}
  ]

  test "multi-word names match with spaces" do
    assert [%{name: "Horse Dentist"}] =
             Mentions.parse("@horse dentist how bad is it", @shitposters)
  end

  test "multi-word lowercase names match with trailing punctuation" do
    assert [%{name: "erowid smoothie"}] =
             Mentions.parse("what was the dose @erowid smoothie?", @shitposters)
  end

  test "a longer word does not shadow a multi-word name" do
    assert [] = Mentions.parse("@Horse Dentistry is a growing field", @shitposters)
  end

  test "several mentions including multi-word names" do
    assert [%{name: "DigimonOtis"}, %{name: "Horse Dentist"}] =
             Mentions.parse("@DigimonOtis tell @horse dentist about the moon", @shitposters)
  end

  test "matches case-insensitively" do
    assert [%{name: "Nova"}] = Mentions.parse("hey @nova what do you think", @roster)
  end

  test "longest roster name wins" do
    assert [%{name: "Nova"}] = Mentions.parse("@Nova!", @roster)
    assert [%{name: "Nov"}] = Mentions.parse("@nov, thoughts?", @roster)
  end

  test "trailing punctuation does not break the match" do
    assert [%{name: "Bobby"}] = Mentions.parse("did you see it @Bobby?", @roster)
  end

  test "does not match a longer word containing a roster name" do
    assert [] = Mentions.parse("@novak is a different person", @roster)
  end

  test "unknown names yield nothing" do
    assert [] = Mentions.parse("@stranger hello", @roster)
  end

  test "dedupes and preserves order of first appearance" do
    assert [%{name: "Bobby"}, %{name: "Nova"}] =
             Mentions.parse("@bobby meet @nova; @Bobby knows", @roster)
  end

  test "hyphenated over-capture still finds the prefix name" do
    assert [%{name: "Nova"}] = Mentions.parse("@nova-wait no", @roster)
  end
end
