defmodule Tour.Step do
  @moduledoc """
  One stop on a tour: a thing on the page, and what to say about it.

  A step points at a real element with a CSS `:target` selector. The element
  is found in the browser, not here — the server never knows the geometry, it
  only knows which selector to hand the client.

  A step with no target is a card in the middle of the screen, which is how
  you open ("here's what this place is") or close ("that's it — go") a tour
  without pointing at anything.
  """

  @enforce_keys [:title]
  defstruct target: nil,
            title: nil,
            body: nil,
            placement: :auto,
            pad: 8,
            radius: 8,
            clicks: false

  @type placement :: :auto | :top | :bottom | :left | :right

  @type t :: %__MODULE__{
          target: String.t() | nil,
          title: String.t(),
          body: String.t() | nil,
          placement: placement(),
          pad: non_neg_integer(),
          radius: non_neg_integer(),
          clicks: boolean()
        }

  @placements ~w(auto top bottom left right)a

  @doc """
  Build a step.

      Tour.Step.new("#speak-form", title: "Say something", body: "Type here.")
      Tour.Step.new(nil, title: "Welcome", body: "Ten seconds, tops.")

  Options:

    * `:body` — the sentence under the title
    * `:placement` — `:auto` (default), `:top`, `:bottom`, `:left`, `:right`.
      `:auto` lets the browser pick whichever side has room; every placement
      flips to its opposite rather than run off the viewport.
    * `:pad` — px of breathing room the spotlight leaves around the element
    * `:radius` — px corner radius of the spotlight
    * `:clicks` — when true the highlighted element stays clickable, so you
      can tell someone to press the thing and let them press it

  Raises `ArgumentError` on an unknown placement or a missing title, because a
  tour that is wrong is better caught at boot than in front of a newcomer.
  """
  @spec new(String.t() | nil, keyword()) :: t()
  def new(target, opts \\ []) do
    {title, opts} = Keyword.pop(opts, :title)

    unless is_binary(title) and title != "" do
      raise ArgumentError, "a Tour step needs a :title (target: #{inspect(target)})"
    end

    placement = Keyword.get(opts, :placement, :auto)

    unless placement in @placements do
      raise ArgumentError,
            "unknown placement #{inspect(placement)}, expected one of #{inspect(@placements)}"
    end

    %__MODULE__{
      target: target,
      title: title,
      body: Keyword.get(opts, :body),
      placement: placement,
      pad: Keyword.get(opts, :pad, 8),
      radius: Keyword.get(opts, :radius, 8),
      clicks: Keyword.get(opts, :clicks, false)
    }
  end

  @doc "A step with no target floats in the middle of the screen."
  @spec centered?(t()) :: boolean()
  def centered?(%__MODULE__{target: target}), do: is_nil(target)
end
