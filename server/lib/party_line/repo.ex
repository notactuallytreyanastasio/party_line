defmodule PartyLine.Repo do
  @moduledoc """
  The durable store. Postgres is the source of truth for the boards and the
  clip wall; the in-memory ETS caches in `PartyLine.Boards`/`PartyLine.Clips`
  sit in front of it for concurrent reads. Writes go here first, then the
  cache and the PubSub broadcast follow.
  """
  use Ecto.Repo,
    otp_app: :party_line,
    adapter: Ecto.Adapters.Postgres
end
