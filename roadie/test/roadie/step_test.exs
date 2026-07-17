defmodule Roadie.StepTest do
  use ExUnit.Case, async: true

  alias Roadie.Step

  test "a step points at a selector and says something about it" do
    step = Step.new("#speak-form", title: "Say something", body: "Type here.", placement: :top)

    assert step.target == "#speak-form"
    assert step.title == "Say something"
    assert step.placement == :top
  end

  test "defaults are the boring safe ones" do
    step = Step.new("#x", title: "t")

    assert step.placement == :auto
    assert step.body == nil
    assert step.clicks == false
    assert step.pad == 8
  end

  test "no target means a card in the middle of the screen" do
    assert Step.new(nil, title: "Welcome") |> Step.centered?()
    refute Step.new("#x", title: "t") |> Step.centered?()
  end

  test "a title is required — a card with no title is a mistake, caught at boot" do
    assert_raise ArgumentError, ~r/needs a :title/, fn -> Step.new("#x", []) end
    assert_raise ArgumentError, ~r/needs a :title/, fn -> Step.new("#x", title: "") end
  end

  test "an unknown placement is caught at boot, not in front of a newcomer" do
    assert_raise ArgumentError, ~r/unknown placement/, fn ->
      Step.new("#x", title: "t", placement: :sideways)
    end
  end

  test "clicks lets the highlighted element stay pressable" do
    assert Step.new("#x", title: "t", clicks: true).clicks
  end
end
