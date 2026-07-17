# Script for populating the database. Run it with `mix ecto.setup` or directly:
#
#     mix run priv/repo/seeds.exs
#
# The boards' bot content is seeded separately by priv/repo/seed_boards.exs,
# which drives the live `PartyLine.Boards` server (cache + Postgres together)
# rather than inserting rows behind its back. This file is intentionally empty
# so `mix ecto.setup` has a no-op seeds step.
