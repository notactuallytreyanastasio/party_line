defmodule Tour.WalkTest do
  use ExUnit.Case, async: true

  alias Tour.{Step, Walk}

  defp steps(n), do: for(i <- 1..n, do: Step.new("#e#{i}", title: "step #{i}"))
  defp tour(n \\ 3), do: Walk.new(:demo, steps(n))

  describe "defining" do
    test "a tour with no steps is a bug, not an empty tour" do
      # via a variable: passing [] inline lets the type checker prove the
      # clause raises, and it reports the very thing this test asserts
      none = Enum.take(steps(1), 0)
      assert_raise ArgumentError, ~r/no steps/, fn -> Walk.new(:demo, none) end
    end

    test "a fresh tour is not running, so the component renders nothing" do
      t = tour()
      refute t.running?
      assert Walk.current(t) == nil
    end
  end

  describe "walking" do
    test "start puts you on the first step" do
      t = tour() |> Walk.start()
      assert t.running?
      assert %Step{title: "step 1"} = Walk.current(t)
      assert Walk.position(t) == 1
    end

    test "next advances and back returns" do
      t = tour() |> Walk.start() |> Walk.next() |> Walk.next()
      assert %Step{title: "step 3"} = Walk.current(t)

      t = Walk.back(t)
      assert %Step{title: "step 2"} = Walk.current(t)
    end

    test "back on the first step stays put rather than underflowing" do
      t = tour() |> Walk.start() |> Walk.back() |> Walk.back()
      assert Walk.position(t) == 1
      assert t.running?
    end

    test "next on the last step finishes the tour — that's how tours end" do
      t = tour(2) |> Walk.start() |> Walk.next() |> Walk.next()

      refute t.running?
      assert t.done?
      assert Walk.current(t) == nil
    end

    test "stop bails without marking it done, so it can be offered again" do
      t = tour() |> Walk.start() |> Walk.next() |> Walk.stop()

      refute t.running?
      refute t.done?
    end

    test "restarting a finished tour runs it from the top" do
      t = tour(1) |> Walk.start() |> Walk.next()
      assert t.done?

      t = Walk.start(t)
      assert t.running?
      refute t.done?
      assert Walk.position(t) == 1
    end

    test "goto clamps instead of pointing at a step that isn't there" do
      t = tour(3) |> Walk.start()

      assert t |> Walk.goto(99) |> Walk.position() == 3
      assert t |> Walk.goto(-5) |> Walk.position() == 1
      assert t |> Walk.goto(1) |> Walk.current() |> Map.fetch!(:title) == "step 2"
    end
  end

  describe "edges the buttons ask about" do
    test "first?/last? drive Back's visibility and Next's label" do
      t = tour(2) |> Walk.start()
      assert Walk.first?(t)
      refute Walk.last?(t)

      t = Walk.next(t)
      refute Walk.first?(t)
      assert Walk.last?(t)
    end

    test "a one-step tour is both first and last at once" do
      t = tour(1) |> Walk.start()
      assert Walk.first?(t)
      assert Walk.last?(t)
    end
  end
end
