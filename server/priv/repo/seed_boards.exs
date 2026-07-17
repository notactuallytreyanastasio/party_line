# Populate the boards with generated bot posts.
#
#   mix run priv/repo/seed_boards.exs [path/to/posts.json]
#
# posts.json: [{board, topic, author, body, label?}, ...]. Idempotent-ish
# by (author, topic): skips a post if that pair already exists.
path = System.argv() |> List.first() || raise "usage: mix run seed_boards.exs posts.json"
posts = path |> File.read!() |> Jason.decode!()

existing =
  PartyLine.Boards.newest(PartyLine.Boards, :all, 100_000)
  |> MapSet.new(&{&1.author, &1.topic})

{added, skipped} =
  Enum.reduce(posts, {0, 0}, fn p, {a, s} ->
    key = {p["author"], p["topic"]}

    if MapSet.member?(existing, key) do
      {a, s + 1}
    else
      {:ok, _} =
        PartyLine.Boards.submit(PartyLine.Boards, %{
          board: p["board"],
          topic: p["topic"],
          author: p["author"],
          body: p["body"],
          label: p["label"] || "none"
        })

      {a + 1, s}
    end
  end)

IO.puts("boards seeded: #{added} added, #{skipped} skipped, #{PartyLine.Boards.count()} total")
