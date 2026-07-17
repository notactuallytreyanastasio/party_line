defmodule Roadie.TourTest do
  use ExUnit.Case, async: true

  alias Roadie.{Step, Tour}

  defp steps(n), do: for(i <- 1..n, do: Step.new("#e#{i}", title: "step #{i}"))
  defp tour(n \\ 3), do: Tour.new(:demo, steps(n))

  describe "defining" do
    test "a tour with no steps is a bug, not an empty tour" do
      assert_raise ArgumentError, ~r/no steps/, fn -> Tour.new(:demo, []) end
    end

    test "a fresh tour is not running, so the component renders nothing" do
      t = tour()
      refute t.running?
      assert Tour.current(t) == nil
    end
  end

  describe "walking" do
    test "start puts you on the first step" do
      t = tour() |> Tour.start()
      assert t.running?
      assert %Step{title: "step 1"} = Tour.current(t)
      assert Tour.position(t) == 1
    end

    test "next advances and back returns" do
      t = tour() |> Tour.start() |> Tour.next() |> Tour.next()
      assert %Step{title: "step 3"} = Tour.current(t)

      t = Tour.back(t)
      assert %Step{title: "step 2"} = Tour.current(t)
    end

    test "back on the first step stays put rather than underflowing" do
      t = tour() |> Tour.start() |> Tour.back() |> Tour.back()
      assert Tour.position(t) == 1
      assert t.running?
    end

    test "next on the last step finishes the tour — that's how tours end" do
      t = tour(2) |> Tour.start() |> Tour.next() |> Tour.next()

      refute t.running?
      assert t.done?
      assert Tour.current(t) == nil
    end

    test "stop bails without marking it done, so it can be offered again" do
      t = tour() |> Tour.start() |> Tour.next() |> Tour.stop()

      refute t.running?
      refute t.done?
    end

    test "restarting a finished tour runs it from the top" do
      t = tour(1) |> Tour.start() |> Tour.next()
      assert t.done?

      t = Tour.start(t)
      assert t.running?
      refute t.done?
      assert Tour.position(t) == 1
    end

    test "goto clamps instead of pointing at a step that isn't there" do
      t = tour(3) |> Tour.start()

      assert t |> Tour.goto(99) |> Tour.position() == 3
      assert t |> Tour.goto(-5) |> Tour.position() == 1
      assert t |> Tour.goto(1) |> Tour.current() |> Map.fetch!(:title) == "step 2"
    end
  end

  describe "edges the buttons ask about" do
    test "first?/last? drive Back's visibility and Next's label" do
      t = tour(2) |> Tour.start()
      assert Tour.first?(t)
      refute Tour.last?(t)

      t = Tour.next(t)
      refute Tour.first?(t)
      assert Tour.last?(t)
    end

    test "a one-step tour is both first and last at once" do
      t = tour(1) |> Tour.start()
      assert Tour.first?(t)
      assert Tour.last?(t)
    end
  end
end
