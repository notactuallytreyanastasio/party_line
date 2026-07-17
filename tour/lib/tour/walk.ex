defmodule Tour.Walk do
  @moduledoc """
  A named sequence of steps and where you are in it.

  This is the whole state machine, and it is pure: no socket, no DOM, no
  process. Everything the UI does — advance, go back, finish, bail — is a
  function from a tour to a tour, so the interesting behavior is testable
  without a browser.

  Walking off the end finishes the tour rather than crashing or wrapping:
  `next/1` on the last step is how a tour normally ends.
  """

  alias Tour.Step

  @enforce_keys [:id, :steps]
  defstruct [:id, :steps, index: 0, running?: false, done?: false]

  @type t :: %__MODULE__{
          id: atom(),
          steps: [Step.t()],
          index: non_neg_integer(),
          running?: boolean(),
          done?: boolean()
        }

  @doc "Define a tour. Raises on an empty step list — an empty tour is a bug."
  @spec new(atom(), [Step.t()]) :: t()
  def new(id, steps) when is_atom(id) and is_list(steps) do
    if steps == [], do: raise(ArgumentError, "tour #{inspect(id)} has no steps")

    %__MODULE__{id: id, steps: steps}
  end

  @doc "Begin at the first step. Starting a finished tour runs it again."
  @spec start(t()) :: t()
  def start(%__MODULE__{} = tour), do: %{tour | index: 0, running?: true, done?: false}

  @doc "Advance. On the last step this finishes the tour."
  @spec next(t()) :: t()
  def next(%__MODULE__{} = tour) do
    if last?(tour), do: finish(tour), else: %{tour | index: tour.index + 1}
  end

  @doc "Step back. Already at the first step, this stays put."
  @spec back(t()) :: t()
  def back(%__MODULE__{index: 0} = tour), do: tour
  def back(%__MODULE__{} = tour), do: %{tour | index: tour.index - 1}

  @doc "Bail out. Unlike `finish/1` this does not mark the tour done, so a
  `once: true` tour will offer itself again."
  @spec stop(t()) :: t()
  def stop(%__MODULE__{} = tour), do: %{tour | running?: false}

  @doc "Reached the end honestly."
  @spec finish(t()) :: t()
  def finish(%__MODULE__{} = tour), do: %{tour | running?: false, done?: true}

  @doc "Jump to a step, clamped into range."
  @spec goto(t(), integer()) :: t()
  def goto(%__MODULE__{} = tour, index) when is_integer(index) do
    %{tour | index: index |> max(0) |> min(size(tour) - 1)}
  end

  @doc "The step being shown, or nil when the tour isn't running."
  @spec current(t()) :: Step.t() | nil
  def current(%__MODULE__{running?: false}), do: nil
  def current(%__MODULE__{steps: steps, index: index}), do: Enum.at(steps, index)

  @spec size(t()) :: pos_integer()
  def size(%__MODULE__{steps: steps}), do: length(steps)

  @doc "1-based, for humans: \"2 of 5\"."
  @spec position(t()) :: pos_integer()
  def position(%__MODULE__{index: index}), do: index + 1

  @spec first?(t()) :: boolean()
  def first?(%__MODULE__{index: 0}), do: true
  def first?(%__MODULE__{}), do: false

  @spec last?(t()) :: boolean()
  def last?(%__MODULE__{} = tour), do: tour.index >= size(tour) - 1
end
