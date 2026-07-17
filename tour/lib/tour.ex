defmodule Tour do
  @moduledoc """
  Guided product tours for Phoenix LiveView — a spotlight that rides on top of
  your real UI.

  Tour does not build you a tour page. It dims your actual app, cuts a hole
  around a real element, and floats a card next to it. The thing being
  explained is the thing on screen.

  ## Using it

  Register tours in `mount/3`, render the component once, start it whenever:

      def mount(_params, _session, socket) do
        {:ok,
         Tour.attach(socket, :onboarding, [
           Tour.step(nil, title: "This is the line", body: "Ten seconds, tops."),
           Tour.step("#speak-form", title: "Say something", body: "Type here. The room answers.", placement: :top),
           Tour.step("#buddy-list", title: "Who's on", body: "@ any of them and they turn.", placement: :left)
         ])}
      end

      def handle_event("help", _params, socket) do
        {:noreply, Tour.start(socket, :onboarding)}
      end

      def render(assigns) do
        ~H\"""
        ...your app...
        <Tour.Components.tour tour={@tour} />
        \"""
      end

  There is no `use Tour`, and you do not write `handle_event` clauses for
  Next/Back/Skip. `attach/4` installs a `handle_event` lifecycle hook that
  answers Tour's own events and passes everything else through untouched, so
  the library stays out of your LiveView's namespace.

  ## Where the work happens

  The server owns *which* step you're on; the browser owns *where* things are.
  That split is deliberate — geometry belongs to the only process that can
  measure it, and step order belongs to the only process you can test without
  a browser. Positioning, flipping, scrolling and keyboard live in the
  colocated hook; everything in Elixir is a pure function over `Tour.Walk`.

  ## Multiple tours

  Register as many as you like; one runs at a time. Starting a tour stops
  whichever was running.
  """

  alias Phoenix.LiveView
  alias Tour.{Step, Walk}

  @assign :tour
  @hook :tour

  defdelegate step(target, opts \\ []), to: Step, as: :new

  @doc """
  Register a tour on the socket. Call once per tour, in `mount/3`.

  Options:

    * `:start` — start it immediately (default `false`)
  """
  @spec attach(LiveView.Socket.t(), atom(), [Step.t()], keyword()) :: LiveView.Socket.t()
  def attach(socket, id, steps, opts \\ []) when is_atom(id) and is_list(steps) do
    tour = Walk.new(id, steps)
    tour = if Keyword.get(opts, :start, false), do: Walk.start(tour), else: tour

    state = state(socket)
    active = if tour.running?, do: id, else: state.active

    socket
    |> ensure_hook()
    |> put_state(%{state | tours: Map.put(state.tours, id, tour), active: active})
  end

  @doc "Start a registered tour, stopping whatever else was running."
  @spec start(LiveView.Socket.t(), atom()) :: LiveView.Socket.t()
  def start(socket, id) do
    state = state(socket)

    case Map.fetch(state.tours, id) do
      {:ok, tour} ->
        tours =
          state.tours
          |> halt(state.active)
          |> Map.put(id, Walk.start(tour))

        put_state(socket, %{state | tours: tours, active: id})

      :error ->
        raise ArgumentError,
              "no tour #{inspect(id)} attached; known: #{inspect(Map.keys(state.tours))}"
    end
  end

  # Two spotlights at once would fight over the screen, so whatever was running
  # steps down when something else starts.
  defp halt(tours, nil), do: tours

  defp halt(tours, id) do
    case Map.get(tours, id) do
      %Walk{running?: true} = tour -> Map.put(tours, id, Walk.stop(tour))
      _ -> tours
    end
  end

  @doc "Stop the running tour, if any. Safe to call when nothing is running."
  @spec stop(LiveView.Socket.t()) :: LiveView.Socket.t()
  def stop(socket), do: update_active(socket, &Walk.stop/1)

  @doc "Advance the running tour. On the last step, this finishes it."
  @spec next(LiveView.Socket.t()) :: LiveView.Socket.t()
  def next(socket), do: update_active(socket, &Walk.next/1)

  @doc "Step the running tour back."
  @spec back(LiveView.Socket.t()) :: LiveView.Socket.t()
  def back(socket), do: update_active(socket, &Walk.back/1)

  @doc """
  The running tour, or nil.

  `:active` only names the tour that ran most recently — it survives a stop so
  the state stays inspectable. Whether a tour is *running* is the tour's own
  business, so this asks it rather than trusting the pointer.
  """
  @spec running(LiveView.Socket.t() | map() | nil) :: Walk.t() | nil
  def running(%LiveView.Socket{} = socket), do: socket |> state() |> running()
  def running(%{active: nil}), do: nil

  def running(%{active: id, tours: tours}) do
    case Map.get(tours, id) do
      %Walk{running?: true} = tour -> tour
      _ -> nil
    end
  end

  def running(_), do: nil

  @doc "Has this tour been run to the end?"
  @spec done?(LiveView.Socket.t(), atom()) :: boolean()
  def done?(socket, id) do
    case socket |> state() |> Map.fetch!(:tours) |> Map.fetch(id) do
      {:ok, tour} -> tour.done?
      :error -> false
    end
  end

  # ── The lifecycle hook ──────────────────────────────────────────────────
  #
  # Attached once. Tour's own events halt here; everything else continues to
  # the host LiveView, which never learns this happened.
  @doc false
  def on_event("tour:next", _params, socket), do: {:halt, next(socket)}
  def on_event("tour:back", _params, socket), do: {:halt, back(socket)}
  def on_event("tour:stop", _params, socket), do: {:halt, stop(socket)}

  def on_event("tour:goto", %{"index" => index}, socket) do
    {:halt, update_active(socket, &Walk.goto(&1, to_int(index)))}
  end

  def on_event(_event, _params, socket), do: {:cont, socket}

  defp ensure_hook(socket) do
    if socket.assigns[:__tour_hooked__] do
      socket
    else
      socket
      |> LiveView.attach_hook(@hook, :handle_event, &on_event/3)
      |> Phoenix.Component.assign(:__tour_hooked__, true)
    end
  end

  defp update_active(socket, fun) do
    state = state(socket)

    case running(state) do
      nil -> socket
      tour -> put_state(socket, %{state | tours: Map.put(state.tours, tour.id, fun.(tour))})
    end
  end

  defp state(%LiveView.Socket{} = socket) do
    socket.assigns[@assign] || %{tours: %{}, active: nil}
  end

  defp put_state(socket, state), do: Phoenix.Component.assign(socket, @assign, state)

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end
end
