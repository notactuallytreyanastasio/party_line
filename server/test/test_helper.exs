ExUnit.start()

# The boards and the clip wall persist to Postgres; run every test inside a
# rolled-back sandbox transaction. Manual mode means a test (or its case) has
# to check a connection out explicitly — nothing auto-commits.
Ecto.Adapters.SQL.Sandbox.mode(PartyLine.Repo, :manual)
