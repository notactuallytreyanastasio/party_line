defmodule PartyLine.Agents.RouterTest do
  use ExUnit.Case, async: true

  alias PartyLine.Agents.{Card, Router}

  defp card(persona, params_b, opts \\ []) do
    Card.new(persona, %{
      "model" => Keyword.get(opts, :model, "model-#{params_b}b"),
      "params_b" => params_b,
      "tokens_per_s" => Keyword.get(opts, :tps, 30),
      "hardware" => Keyword.get(opts, :hw, "MacBook")
    })
  end

  defp small, do: card("erowid smoothie", 4)
  defp medium, do: card("Horse Dentist", 8)
  defp large, do: card("DigimonOtis", 20)

  describe "the card" do
    test "power is bucketed by size, and a card claiming nothing gets the easy work" do
      assert Card.power(small()) == :small
      assert Card.power(medium()) == :medium
      assert Card.power(large()) == :large
      assert Card.power(Card.new("mystery")) == :small
    end

    test "a big model may answer banter — idling a 20B on 'hi' helps nobody" do
      assert Card.can_take?(large(), :chatty)
      assert Card.can_take?(large(), :hard)
      assert Card.can_take?(small(), :chatty)
      refute Card.can_take?(small(), :hard)
      refute Card.can_take?(medium(), :hard)
    end

    test "host claims are clamped, not believed" do
      liar = Card.new("liar", %{"params_b" => -5, "tokens_per_s" => 10_000_000})
      assert liar.params_b == 0.0
      assert liar.tokens_per_s == 100_000.0
    end

    test "the byline says which machine answered you" do
      assert Card.byline(card("Horse Dentist", 8, model: "gemma-4", tps: 42, hw: "M4 Pro")) ==
               "Horse Dentist · gemma-4 · 42 tok/s · M4 Pro"
    end

    test "the byline omits what the host never claimed" do
      assert Card.byline(Card.new("ghost")) == "ghost · unknown"
    end
  end

  describe "nobody home" do
    test "an empty exchange is an error, not a crash" do
      assert {:error, :nobody_online} = Router.route([], "hey")
    end
  end

  describe "sizing" do
    test "banter can land on the small machine" do
      assert {:ok, %{tier: :chatty, downshifted?: false, card: %{persona: "erowid smoothie"}}} =
               Router.route([small()], "hey")
    end

    test "a hard question skips the machines that can't hold it" do
      assert {:ok, %{tier: :hard, downshifted?: false, card: card}} =
               Router.route([small(), medium(), large()], "```\ndef f, do: 1\n```")

      assert card.persona == "DigimonOtis"
    end

    test "when nobody is big enough it downshifts and admits it" do
      assert {:ok, %{tier: :hard, downshifted?: true, card: card}} =
               Router.route([small()], "```\ndef f, do: 1\n```")

      assert card.persona == "erowid smoothie",
             "a 4B answering a hard question beats a spinner waiting for a 70B"
    end
  end

  describe "round robin" do
    test "the cursor deals each eligible agent in turn, and wraps" do
      pool = [large(), card("Beef Inspector", 20), card("coupon warlock", 20)]
      # sorted by persona: Beef Inspector, DigimonOtis, coupon warlock
      names =
        Enum.map_reduce(0..5, 0, fn _i, cursor ->
          {:ok, %{card: c, cursor: next}} = Router.route(pool, "hey", cursor: cursor)
          {c.persona, next}
        end)
        |> elem(0)

      assert names == [
               "Beef Inspector",
               "DigimonOtis",
               "coupon warlock",
               "Beef Inspector",
               "DigimonOtis",
               "coupon warlock"
             ]
    end

    test "the ring is stable, not map order" do
      pool = [card("zed", 20), card("ada", 20)]
      {:ok, %{card: first}} = Router.route(pool, "hey", cursor: 0)
      {:ok, %{card: same}} = Router.route(Enum.reverse(pool), "hey", cursor: 0)

      assert first.persona == same.persona,
             "the same cursor must deal the same agent regardless of directory order"
    end
  end

  describe "targeting" do
    test "asking for a persona gets that persona" do
      assert {:ok, %{card: %{persona: "Horse Dentist"}}} =
               Router.route([small(), medium(), large()], "hey",
                 target: %{persona: "horse dentist"}
               )
    end

    test "asking for a class of machine gets that class" do
      assert {:ok, %{card: %{persona: "DigimonOtis"}}} =
               Router.route([small(), medium(), large()], "hey", target: %{power: :large})
    end

    test "asking for a model matches on the model string" do
      pool = [card("a", 8, model: "gpt-oss-20b"), card("b", 8, model: "gemma-4-e4b")]

      assert {:ok, %{card: %{persona: "a"}}} =
               Router.route(pool, "hey", target: %{model: "gpt-oss"})
    end

    test "targeting nobody says so rather than quietly serving someone else" do
      assert {:error, {:no_match, %{persona: "nobody"}}} =
               Router.route([small()], "hey", target: %{persona: "nobody"})
    end

    test "a target you asked for wins even when it's too small for the question" do
      # you asked for the 4B. you get the 4B, and the downshift is flagged.
      assert {:ok, %{card: %{persona: "erowid smoothie"}, downshifted?: true}} =
               Router.route([small(), large()], "```\ncode\n```",
                 target: %{persona: "erowid smoothie"}
               )
    end
  end
end
