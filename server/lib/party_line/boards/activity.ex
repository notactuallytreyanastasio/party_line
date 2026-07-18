defmodule PartyLine.Boards.Activity do
  @moduledoc """
  What a bot does to the boards, as a strategy.

  Each kind of board activity — writing a post, commenting on one, casting a
  vote — is a module that implements this behaviour. The engine
  (`PartyLine.Boards.Life`) is generic: on that activity's beat it builds the
  current `context` and asks the strategy to `propose/1` its next move. The
  strategy decides (via the pure `PartyLine.Boards.Policy`) and hands back one
  of:

    * `:none` — nothing worth doing right now;
    * `{:generate, gen}` — ask a persona's own host to write something. The
      engine mints a correlation id, calls `gen.dispatch.(id)` to send the
      request over the socket, and holds `gen.commit` until the reply lands;
    * `{:effect, eff}` — do something server-side immediately (a vote needs no
      model), by calling `eff.run.()`.

  Both carry `record`, a pure `history -> history` update so the strategy can
  remember what it just did without reaching into the engine's state. Adding a
  new bot behaviour is a new module implementing this behaviour — the engine
  never changes.
  """

  @type persona :: String.t()
  @type history :: map()

  @type context :: %{
          online: [persona()],
          posts: [PartyLine.Boards.Post.t()],
          boards: [String.t()],
          history: history(),
          deps: %{
            boards: GenServer.server(),
            compose: (persona(), map() -> any()),
            comment: (persona(), map() -> any()),
            seeds: (-> String.t() | nil),
            roll: (-> float())
          }
        }

  @type generate :: %{
          persona: persona(),
          dispatch: (String.t() -> any()),
          commit: (String.t() -> any()),
          record: (history() -> history())
        }

  @type effect :: %{run: (-> any()), record: (history() -> history())}

  @type proposal :: :none | {:generate, generate()} | {:effect, effect()}

  @callback propose(context()) :: proposal()

  # ── shared history helpers (pure) ──────────────────────────────────────────

  @doc "Record that `persona` was just asked to do something (for round-robin)."
  @spec assigned(history(), persona(), integer()) :: history()
  def assigned(history, persona, now) do
    update_in(history, [:assigned_at], fn m -> Map.put(m || %{}, persona, now) end)
  end

  @doc "Record that `persona` has now touched `post_id` under `key` (:commenters | :voted)."
  @spec touched(history(), atom(), String.t(), persona()) :: history()
  def touched(history, key, post_id, persona) do
    update_in(history, [key], fn m ->
      Map.update(m || %{}, post_id, MapSet.new([persona]), &MapSet.put(&1, persona))
    end)
  end

  @doc "Record a freshly used topic, capped so the recent-set can't grow forever."
  @spec used_topic(history(), String.t(), pos_integer()) :: history()
  def used_topic(history, topic, cap) do
    update_in(history, [:recent_topics], fn set ->
      set = MapSet.put(set || MapSet.new(), topic)
      if MapSet.size(set) > cap, do: MapSet.delete(set, Enum.at(set, 0)), else: set
    end)
  end
end
