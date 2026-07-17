defmodule TourTest do
  @moduledoc """
  The socket-level API. These drive `Tour` the way a LiveView does, but with
  a bare socket — the lifecycle hook is exercised directly, so no endpoint or
  browser is involved.
  """
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.{Lifecycle, Socket}
  alias Tour.Walk

  # LiveView fills :lifecycle in during mount; a bare %Socket{} has no hook
  # registry, so attach_hook/4 would have nothing to attach to.
  defp socket, do: %Socket{private: %{lifecycle: %Lifecycle{}, live_temp: %{}}}

  defp steps do
    [
      Tour.step(nil, title: "Welcome"),
      Tour.step("#speak-form", title: "Say something", placement: :top),
      Tour.step("#buddy-list", title: "Who's on", placement: :left)
    ]
  end

  describe "attaching" do
    test "an attached tour is registered but idle until started" do
      s = Tour.attach(socket(), :onboarding, steps())

      assert Tour.running(s) == nil
      assert %Walk{running?: false} = s.assigns.tour.tours[:onboarding]
    end

    test "start: true opens the tour on mount" do
      s = Tour.attach(socket(), :onboarding, steps(), start: true)

      assert %Walk{id: :onboarding, running?: true} = Tour.running(s)
    end

    test "starting an unknown tour says so, and names the ones that exist" do
      s = Tour.attach(socket(), :onboarding, steps())

      assert_raise ArgumentError, ~r/no tour :nope attached.*onboarding/s, fn ->
        Tour.start(s, :nope)
      end
    end
  end

  describe "multiple tours" do
    test "one runs at a time: starting a second stops the first" do
      s =
        socket()
        |> Tour.attach(:landing, steps())
        |> Tour.attach(:boards, steps())
        |> Tour.start(:landing)

      assert %Walk{id: :landing} = Tour.running(s)

      s = Tour.start(s, :boards)
      assert %Walk{id: :boards} = Tour.running(s)
      refute s.assigns.tour.tours[:landing].running?
    end

    test "attaching twice does not attach the hook twice (which would raise)" do
      s =
        socket()
        |> Tour.attach(:a, steps())
        |> Tour.attach(:b, steps())
        |> Tour.attach(:c, steps())

      assert map_size(s.assigns.tour.tours) == 3
    end
  end

  describe "the lifecycle hook" do
    setup do
      %{socket: Tour.attach(socket(), :onboarding, steps(), start: true)}
    end

    test "tour's own events are handled and halted", %{socket: s} do
      assert {:halt, s} = Tour.on_event("tour:next", %{}, s)
      assert Walk.position(Tour.running(s)) == 2

      assert {:halt, s} = Tour.on_event("tour:back", %{}, s)
      assert Walk.position(Tour.running(s)) == 1

      assert {:halt, s} = Tour.on_event("tour:stop", %{}, s)
      assert Tour.running(s) == nil
    end

    test "the host LiveView's own events pass straight through", %{socket: s} do
      # this is the whole point of attach_hook over `use`: an app event Tour
      # has never heard of must continue to the LiveView untouched
      assert {:cont, ^s} = Tour.on_event("speak", %{"body" => "hi"}, s)
      assert {:cont, ^s} = Tour.on_event("toggle_start", %{}, s)
    end

    test "goto accepts the string the DOM would actually send", %{socket: s} do
      assert {:halt, s} = Tour.on_event("tour:goto", %{"index" => "2"}, s)
      assert Walk.position(Tour.running(s)) == 3
    end

    test "walking off the end finishes and marks it done", %{socket: s} do
      {:halt, s} = Tour.on_event("tour:next", %{}, s)
      {:halt, s} = Tour.on_event("tour:next", %{}, s)
      {:halt, s} = Tour.on_event("tour:next", %{}, s)

      assert Tour.running(s) == nil
      assert Tour.done?(s, :onboarding)
    end

    test "events with nothing running are a no-op, not a crash" do
      s = Tour.attach(socket(), :onboarding, steps())

      assert {:halt, s} = Tour.on_event("tour:next", %{}, s)
      assert Tour.running(s) == nil
    end
  end

  test "done? is false for a tour nobody has finished or attached" do
    s = Tour.attach(socket(), :onboarding, steps())

    refute Tour.done?(s, :onboarding)
    refute Tour.done?(s, :never_heard_of_it)
  end
end
