defmodule PartyLine.DataCase do
  @moduledoc """
  Test case for anything that touches the database — the boards and the clip
  wall. Each test runs inside an `Ecto.Adapters.SQL.Sandbox` transaction that
  is rolled back at the end, so the real Postgres stays pristine and we never
  mock the Repo.

  These cases default to `async: false`: the boards/clips GenServers persist
  from their own processes, so the sandbox runs in shared mode and every
  process sees the same rolled-back connection.
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias PartyLine.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PartyLine.DataCase
    end
  end

  setup tags do
    setup_sandbox(tags)
    :ok
  end

  @doc "Check out a sandbox connection; shared mode unless the case is async."
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(PartyLine.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  Shared-mode sandbox for tests that drive the app-started `Boards`/`Clips`
  singletons (LiveView, socket, scheduler). Those GenServers — and the
  endpoint/LiveView processes — run outside the test process, so shared mode
  lets them all see the test's rolled-back connection. Their ETS caches
  persist across tests, so we clear them here: every test starts on an empty
  board and wall. Must run non-async.
  """
  def checkout_singletons! do
    :ok = Sandbox.checkout(PartyLine.Repo)
    Sandbox.mode(PartyLine.Repo, {:shared, self()})
    PartyLine.Boards.reset()
    PartyLine.Clips.reset()
    :ok
  end
end
