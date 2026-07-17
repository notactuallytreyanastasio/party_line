defmodule RoadieTest do
  @moduledoc """
  The socket-level API. These drive `Roadie` the way a LiveView does, but with
  a bare socket — the lifecycle hook is exercised directly, so no endpoint or
  browser is involved.
  """
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.{Lifecycle, Socket}
  alias Roadie.Tour

  # LiveView fills :lifecycle in during mount; a bare %Socket{} has no hook
  # registry, so attach_hook/4 would have nothing to attach to.
  defp socket, do: %Socket{private: %{lifecycle: %Lifecycle{}, live_temp: %{}}}

  defp steps do
    [
      Roadie.step(nil, title: "Welcome"),
      Roadie.step("#speak-form", title: "Say something", placement: :top),
      Roadie.step("#buddy-list", title: "Who's on", placement: :left)
    ]
  end

  describe "attaching" do
    test "an attached tour is registered but idle until started" do
      s = Roadie.attach(socket(), :onboarding, steps())

      assert Roadie.running(s) == nil
      assert %Tour{running?: false} = s.assigns.roadie.tours[:onboarding]
    end

    test "start: true opens the tour on mount" do
      s = Roadie.attach(socket(), :onboarding, steps(), start: true)

      assert %Tour{id: :onboarding, running?: true} = Roadie.running(s)
    end

    test "starting an unknown tour says so, and names the ones that exist" do
      s = Roadie.attach(socket(), :onboarding, steps())

      assert_raise ArgumentError, ~r/no tour :nope attached.*onboarding/s, fn ->
        Roadie.start(s, :nope)
      end
    end
  end

  describe "multiple tours" do
    test "one runs at a time: starting a second stops the first" do
      s =
        socket()
        |> Roadie.attach(:landing, steps())
        |> Roadie.attach(:boards, steps())
        |> Roadie.start(:landing)

      assert %Tour{id: :landing} = Roadie.running(s)

      s = Roadie.start(s, :boards)
      assert %Tour{id: :boards} = Roadie.running(s)
      refute s.assigns.roadie.tours[:landing].running?
    end

    test "attaching twice does not attach the hook twice (which would raise)" do
      s =
        socket()
        |> Roadie.attach(:a, steps())
        |> Roadie.attach(:b, steps())
        |> Roadie.attach(:c, steps())

      assert map_size(s.assigns.roadie.tours) == 3
    end
  end

  describe "the lifecycle hook" do
    setup do
      %{socket: Roadie.attach(socket(), :onboarding, steps(), start: true)}
    end

    test "roadie's own events are handled and halted", %{socket: s} do
      assert {:halt, s} = Roadie.on_event("roadie:next", %{}, s)
      assert Tour.position(Roadie.running(s)) == 2

      assert {:halt, s} = Roadie.on_event("roadie:back", %{}, s)
      assert Tour.position(Roadie.running(s)) == 1

      assert {:halt, s} = Roadie.on_event("roadie:stop", %{}, s)
      assert Roadie.running(s) == nil
    end

    test "the host LiveView's own events pass straight through", %{socket: s} do
      # this is the whole point of attach_hook over `use`: an app event Roadie
      # has never heard of must continue to the LiveView untouched
      assert {:cont, ^s} = Roadie.on_event("speak", %{"body" => "hi"}, s)
      assert {:cont, ^s} = Roadie.on_event("toggle_start", %{}, s)
    end

    test "goto accepts the string the DOM would actually send", %{socket: s} do
      assert {:halt, s} = Roadie.on_event("roadie:goto", %{"index" => "2"}, s)
      assert Tour.position(Roadie.running(s)) == 3
    end

    test "walking off the end finishes and marks it done", %{socket: s} do
      {:halt, s} = Roadie.on_event("roadie:next", %{}, s)
      {:halt, s} = Roadie.on_event("roadie:next", %{}, s)
      {:halt, s} = Roadie.on_event("roadie:next", %{}, s)

      assert Roadie.running(s) == nil
      assert Roadie.done?(s, :onboarding)
    end

    test "events with nothing running are a no-op, not a crash" do
      s = Roadie.attach(socket(), :onboarding, steps())

      assert {:halt, s} = Roadie.on_event("roadie:next", %{}, s)
      assert Roadie.running(s) == nil
    end
  end

  test "done? is false for a tour nobody has finished or attached" do
    s = Roadie.attach(socket(), :onboarding, steps())

    refute Roadie.done?(s, :onboarding)
    refute Roadie.done?(s, :never_heard_of_it)
  end
end
