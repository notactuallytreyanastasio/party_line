defmodule PartyLine.API.OpenAITest do
  use ExUnit.Case, async: true

  alias LangChain.Message
  alias PartyLine.Agents.Card
  alias PartyLine.API.OpenAI

  defp result(content, persona \\ "Horse Dentist") do
    card = Card.new(persona, %{"model" => "gemma-4-e4b-8bit"})

    %{
      content: content,
      prompt_tokens: 12,
      decision: %{card: card, honored?: true, downshifted?: false, asked: %{}}
    }
  end

  describe "parse_messages" do
    test "maps roles to LangChain messages and keeps text" do
      parsed =
        OpenAI.parse_messages([
          %{"role" => "system", "content" => "be terse"},
          %{"role" => "user", "content" => "hi"},
          %{"role" => "assistant", "content" => "hello"}
        ])

      assert [%Message{role: :system}, %Message{role: :user}, %Message{role: :assistant}] = parsed
    end

    test "flattens array (multimodal) content to its text parts" do
      [msg] =
        OpenAI.parse_messages([
          %{"role" => "user", "content" => [%{"type" => "text", "text" => "why do cats knead"}]}
        ])

      assert %Message{role: :user} = msg
    end
  end

  describe "render_completion" do
    test "produces a chat.completion with the answer and attribution" do
      body = OpenAI.render_completion(result("they're testing the couch"), "party-line-auto")

      assert body.object == "chat.completion"

      assert [%{message: %{role: "assistant", content: "they're testing the couch"}}] =
               body.choices

      assert body.choices |> hd() |> Map.get(:finish_reason) == "stop"
      # the answering persona is the honest model label
      assert body.model == "Horse Dentist"
      assert body.usage.total_tokens == body.usage.prompt_tokens + body.usage.completion_tokens
      assert body.party_line.persona == "Horse Dentist"
    end
  end

  describe "stream_frames" do
    test "emits a role delta, content, a stop, then [DONE]" do
      frames = OpenAI.stream_frames(result("hello there friend"), "party-line-auto")

      assert List.last(frames) == "data: [DONE]\n\n"
      joined = Enum.join(frames)
      assert joined =~ "chat.completion.chunk"
      assert joined =~ ~s("role":"assistant")
      assert joined =~ ~s("finish_reason":"stop")
      # the whole answer survives being chunked
      contents =
        frames
        |> Enum.filter(&String.starts_with?(&1, "data: {"))
        |> Enum.map(&(&1 |> String.trim_leading("data: ") |> String.trim() |> Jason.decode!()))
        |> Enum.flat_map(fn f -> for c <- f["choices"], do: c["delta"]["content"] end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join()

      assert contents == "hello there friend"
    end
  end
end
