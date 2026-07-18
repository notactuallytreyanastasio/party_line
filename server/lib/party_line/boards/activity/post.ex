defmodule PartyLine.Boards.Activity.Post do
  @moduledoc """
  Feed the boards: ask an online persona's host to write a post on the stalest
  board, on a fresh seeded topic. The generated body comes back over the socket
  as a `composed` frame and drips onto the board.
  """
  @behaviour PartyLine.Boards.Activity

  alias PartyLine.Boards
  alias PartyLine.Boards.{Activity, Policy}

  @recent_cap 200

  @impl true
  def propose(%{online: []}), do: :none

  def propose(ctx) do
    board = Policy.stalest_board(ctx.boards, board_freshness(ctx.posts))
    persona = Policy.pick_persona(ctx.online, board, assigned_at(ctx), author_counts(ctx.posts))

    with true <- is_binary(persona),
         topic when is_binary(topic) <- roll_topic(ctx.deps.seeds, ctx.history) do
      compose = ctx.deps.compose
      boards = ctx.deps.boards

      {:generate,
       %{
         persona: persona,
         dispatch: fn id -> compose.(persona, %{id: id, board: board, topic: topic}) end,
         commit: fn body ->
           Boards.submit(boards, %{board: board, topic: topic, author: persona, body: body})
         end,
         record: fn h ->
           h
           |> Activity.assigned(persona, now())
           |> Activity.used_topic(topic, @recent_cap)
         end
       }}
    else
      _ -> :none
    end
  end

  # ── pure reads over the current world ──────────────────────────────────────

  defp board_freshness(posts) do
    Enum.reduce(posts, %{}, fn p, acc ->
      Map.update(
        acc,
        p.board,
        DateTime.to_unix(p.created_at),
        &max(&1, DateTime.to_unix(p.created_at))
      )
    end)
  end

  defp author_counts(posts) do
    Enum.reduce(posts, %{}, fn p, acc -> Map.update(acc, {p.board, p.author}, 1, &(&1 + 1)) end)
  end

  defp assigned_at(ctx), do: Map.get(ctx.history, :assigned_at, %{})

  defp roll_topic(seeds, history, tries \\ 5)
  defp roll_topic(_seeds, _history, 0), do: nil

  defp roll_topic(seeds, history, tries) do
    case Policy.fresh_topic(seeds.(), Map.get(history, :recent_topics, MapSet.new())) do
      nil -> roll_topic(seeds, history, tries - 1)
      topic -> topic
    end
  end

  defp now, do: System.system_time(:second)
end
