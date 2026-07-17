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

    test "size and quantization are read off the model id the host named" do
      # the host said "...-8B-Instruct-4bit" — that IS the claim, spelled differently
      c = Card.new("a", %{"model" => "Meta-Llama-3.1-8B-Instruct-4bit"})
      assert c.params_b == 8.0
      assert c.quant_bits == 4

      # gemma names its size inside a token: "e4b" = effective 4B
      assert Card.new("b", %{"model" => "mlx-community/gemma-4-e4b-it-8bit"}).params_b == 4.0
      assert Card.new("b", %{"model" => "mlx-community/gemma-4-e4b-it-8bit"}).quant_bits == 8
    end

    test "a mixed quant reads as its weakest link, not its flattering half" do
      # MXFP4 weights with 8-bit something-else is a 4-bit model
      assert Card.new("a", %{"model" => "gpt-oss-20b-MXFP4-Q8"}).quant_bits == 4
    end

    test "a bare version number is not a size claim" do
      assert Card.new("a", %{"model" => "gemma-4"}).params_b == 0.0
      assert Card.new("a", %{"model" => "mystery"}).quant_bits == 0
    end

    test "an explicit claim beats us squinting at the model string" do
      c = Card.new("a", %{"model" => "foo-70b-4bit", "params_b" => 8, "quant" => "8bit"})
      assert c.params_b == 8.0
      assert c.quant_bits == 8
    end

    test "the byline says which machine answered you" do
      assert Card.byline(card("Horse Dentist", 8, model: "gemma-4", tps: 42, hw: "M4 Pro")) ==
               "Horse Dentist · gemma-4 · 42 tok/s · M4 Pro"
    end

    test "the byline omits what the host never claimed" do
      assert Card.byline(Card.new("ghost")) == "ghost · unknown"
    end

    test "the byline names the quantization, because it's the quality claim" do
      card = Card.new("DigimonOtis", %{"model" => "gpt-oss-20b-MXFP4-Q8", "tokens_per_s" => 18})
      assert Card.byline(card) =~ "MXFP4"
      assert Card.byline(card) =~ "18 tok/s"
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

  describe "asks are tried, not enforced" do
    test "asking for 24B or more gets you 24B or more when it's on" do
      pool = [small(), medium(), card("DigimonOtis", 24)]

      assert {:ok, %{card: %{persona: "DigimonOtis"}, honored?: true}} =
               Router.route(pool, "is there something that's 24B or more?")
    end

    test "asking for 24B when nothing that big is on still answers, and says so" do
      assert {:ok, decision} = Router.route([small(), medium()], "anything 24B or more around?")

      assert decision.honored? == false
      assert decision.card.persona in ["erowid smoothie", "Horse Dentist"]
      assert Router.note(decision) =~ "nothing 24B or bigger is on the exchange right now"
      assert Router.note(decision) =~ "asking"
    end

    test "an unmet ask never empties the exchange" do
      assert {:ok, %{card: %{}}} = Router.route([small()], "got a 400B model?")
    end

    test "reading the ask out of the message needs no explicit target" do
      pool = [small(), card("DigimonOtis", 24)]

      assert {:ok, %{card: %{persona: "DigimonOtis"}, asked: %{min_params_b: 24.0}}} =
               Router.route(pool, "at least 24b please")
    end

    test "an explicit target beats parsing the message" do
      pool = [small(), medium()]

      assert {:ok, %{card: %{persona: "Horse Dentist"}, honored?: true}} =
               Router.route(pool, "hey", target: %{persona: "Horse Dentist"})
    end

    test "asking by persona finds them" do
      pool = [small(), medium(), large()]

      assert {:ok, %{card: %{persona: "Horse Dentist"}, honored?: true}} =
               Router.route(pool, "ask horse dentist about molars")
    end

    test "nobody asked for anything, so nothing to apologize for" do
      assert {:ok, decision} = Router.route([medium()], "hey")
      assert decision.asked == %{}
      assert decision.honored?
      assert Router.note(decision) == nil
    end

    test "asking for 8bit or better skips the 4bit machines" do
      pool = [
        card("squashed", 20, model: "big-20b-4bit"),
        card("roomy", 20, model: "big-20b-8bit")
      ]

      assert {:ok, %{card: %{persona: "roomy"}, honored?: true, asked: %{min_quant_bits: 8}}} =
               Router.route(pool, "8bit or better please")
    end

    test "asking for 8bit when everything on is 4bit still answers, and says so" do
      pool = [card("squashed", 20, model: "big-20b-4bit")]

      assert {:ok, decision} = Router.route(pool, "anything 8bit or better?")
      assert decision.honored? == false
      assert Router.note(decision) =~ "nothing 8bit or better is on the exchange right now"
    end

    test "a host that won't say how squashed it is loses a quantization ask" do
      pool = [card("shy", 20, model: "mystery-20b"), card("honest", 20, model: "big-20b-8bit")]

      assert {:ok, %{card: %{persona: "honest"}, honored?: true}} =
               Router.route(pool, "8bit or better")
    end

    test "size and quantization can be asked for together" do
      pool = [
        card("small-good", 4, model: "tiny-4b-8bit"),
        card("big-bad", 24, model: "huge-24b-4bit"),
        card("big-good", 24, model: "huge-24b-8bit")
      ]

      assert {:ok, %{card: %{persona: "big-good"}, honored?: true}} =
               Router.route(pool, "is there something thats 24B or more, 8bit or better?")
    end

    test "the note explains a downshift too" do
      assert {:ok, decision} = Router.route([small()], "```\ncode\n```")
      assert decision.downshifted?
      assert Router.note(decision) =~ "nobody online is big enough"
    end
  end
end
