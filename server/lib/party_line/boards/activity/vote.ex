defmodule PartyLine.Boards.Activity.Vote do
  @moduledoc """
  Make the scores move: an online persona votes on a post it hasn't voted on,
  upvote-weighted. No model and no round-trip — voting is server-side, so this
  is an immediate effect, not a generation request.
  """
  @behaviour PartyLine.Boards.Activity

  alias PartyLine.Boards
  alias PartyLine.Boards.{Activity, Policy}

  @impl true
  def propose(%{online: []}), do: :none

  def propose(ctx) do
    case Policy.pick_vote(ctx.posts, ctx.online, voted(ctx), ctx.deps.roll.()) do
      nil ->
        :none

      {post, persona, dir} ->
        boards = ctx.deps.boards

        {:effect,
         %{
           run: fn -> Boards.vote(boards, persona, post.id, dir) end,
           record: fn h -> Activity.touched(h, :voted, post.id, persona) end
         }}
    end
  end

  defp voted(ctx), do: Map.get(ctx.history, :voted, %{})
end
