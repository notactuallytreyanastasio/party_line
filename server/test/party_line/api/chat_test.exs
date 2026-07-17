defmodule PartyLine.API.ChatTest do
  use ExUnit.Case, async: true

  alias LangChain.Message
  alias PartyLine.API.Chat
  alias PartyLine.Test.ExchangeFake

  describe "target_for" do
    test "auto aliases route to nobody in particular" do
      assert Chat.target_for(nil) == %{}
      assert Chat.target_for("party-line-auto") == %{}
      assert Chat.target_for("auto") == %{}
      assert Chat.target_for("") == %{}
    end

    test "a model family becomes a model constraint" do
      assert Chat.target_for("gemma") == %{model: "gemma"}
      assert Chat.target_for("gpt-oss-20b") == %{model: "gpt-oss"}
    end

    test "anything else is treated as a persona" do
      assert Chat.target_for("Horse Dentist") == %{persona: "Horse Dentist"}
    end
  end

  describe "complete" do
    test "routes the conversation and returns the answer with attribution" do
      %{asks: asks} =
        ExchangeFake.start!(
          [ExchangeFake.card("Horse Dentist", "gemma-4-e4b-8bit")],
          fn prompt -> "you asked: #{prompt}" end
        )

      messages = [
        Message.new_system!("be terse"),
        Message.new_user!("why do cats knead")
      ]

      assert {:ok, result} = Chat.complete(messages, asks: asks)
      assert result.content =~ "why do cats knead"
      assert result.decision.card.persona == "Horse Dentist"
      assert result.prompt_tokens > 0
    end

    test "an empty exchange is :nobody_online, not a hang" do
      %{asks: asks} = ExchangeFake.start!([])

      assert Chat.complete([Message.new_user!("anyone home?")], asks: asks) ==
               {:error, :nobody_online}
    end

    test "the flattened prompt carries system and the latest turn to routing" do
      %{asks: asks, bots: bots} = ExchangeFake.start!([ExchangeFake.card("ada")])

      Chat.complete(
        [Message.new_system!("SYSTEM RULE"), Message.new_user!("the actual question")],
        asks: asks
      )

      assert {_persona, prompt} = ExchangeFake.last(bots)
      assert prompt =~ "SYSTEM RULE"
      assert prompt =~ "the actual question"
    end
  end
end
