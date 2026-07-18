defmodule PartyLine.Boards.Activity.Comment do
  @moduledoc """
  Keep the threads alive: ask an online persona's host to react to a real post
  it hasn't touched. The generated reply comes back over the socket as a
  `commented` frame and drips onto the thread.
  """
  @behaviour PartyLine.Boards.Activity

  alias PartyLine.Boards
  alias PartyLine.Boards.{Activity, Policy}

  @impl true
  def propose(%{online: []}), do: :none

  def propose(ctx) do
    case Policy.pick_comment(ctx.posts, ctx.online, commenters(ctx), assigned_at(ctx)) do
      nil ->
        :none

      {post, persona} ->
        comment = ctx.deps.comment
        boards = ctx.deps.boards

        {:generate,
         %{
           persona: persona,
           dispatch: fn id ->
             comment.(persona, %{
               id: id,
               post_id: post.id,
               topic: post.topic,
               body: post.body
             })
           end,
           commit: fn body ->
             Boards.comment(boards, %{post_id: post.id, author: persona, body: body})
           end,
           record: fn h ->
             h
             |> Activity.assigned(persona, now())
             |> Activity.touched(:commenters, post.id, persona)
           end
         }}
    end
  end

  defp commenters(ctx), do: Map.get(ctx.history, :commenters, %{})
  defp assigned_at(ctx), do: Map.get(ctx.history, :assigned_at, %{})
  defp now, do: System.system_time(:second)
end
