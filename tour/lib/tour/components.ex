defmodule Tour.Components do
  @moduledoc """
  The one component you render. Put it anywhere in your template — it's
  fixed-position, so it doesn't matter where.

      <Tour.Components.tour tour={@tour} />

  It renders nothing at all unless a tour is running.
  """

  use Phoenix.Component

  alias Tour.{Step, Walk}

  @doc """
  Renders the running tour's spotlight and card.

  Attributes:

    * `:tour` — the state Tour keeps on the socket (`@tour`)
    * `:labels` — override the button text, e.g.
      `%{next: "Next", back: "Back", done: "Got it", skip: "Skip"}`
    * `:class` — extra classes on the root, for theming
  """
  attr :tour, :map, default: nil
  attr :class, :string, default: nil
  attr :labels, :map, default: %{}

  def tour(assigns) do
    tour = Tour.running(assigns.tour)
    step = tour && Walk.current(tour)

    assigns =
      assigns
      |> assign(tour: tour, step: step)
      |> assign(:labels, Map.merge(default_labels(), assigns.labels))

    ~H"""
    <div
      :if={@step}
      id="tour"
      class={["tour", @class]}
      phx-hook=".Tour"
      data-target={@step.target}
      data-placement={@step.placement}
      data-pad={@step.pad}
      data-radius={@step.radius}
      data-clicks={to_string(@step.clicks)}
    >
      <div class="tour-veil" data-veil phx-click="tour:stop"></div>
      <div class="tour-hole" data-hole aria-hidden="true"></div>

      <div
        class="tour-card"
        data-card
        role="dialog"
        aria-modal="true"
        aria-labelledby="tour-title"
        tabindex="-1"
      >
        <p class="tour-count">{Walk.position(@tour)} of {Walk.size(@tour)}</p>
        <h2 class="tour-title" id="tour-title">{@step.title}</h2>
        <p :if={@step.body} class="tour-body">{@step.body}</p>

        <div class="tour-actions">
          <button type="button" class="tour-btn tour-btn--ghost" phx-click="tour:stop">
            {@labels.skip}
          </button>
          <span class="tour-gap"></span>
          <button
            :if={not Walk.first?(@tour)}
            type="button"
            class="tour-btn"
            phx-click="tour:back"
          >
            {@labels.back}
          </button>
          <button type="button" class="tour-btn tour-btn--go" phx-click="tour:next">
            {if Walk.last?(@tour), do: @labels.done, else: @labels.next}
          </button>
        </div>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Tour">
      // The server decides which step; this decides where everything sits.
      const GAP = 12
      const EDGE = 8

      export default {
        mounted() {
          this.reduced = matchMedia("(prefers-reduced-motion: reduce)").matches
          this.veil = this.el.querySelector("[data-veil]")
          this.hole = this.el.querySelector("[data-hole]")
          this.card = this.el.querySelector("[data-card]")

          // Re-place on anything that can move the target. The scroll listener
          // is capturing so it also hears scrolls inside nested containers,
          // which is what lets the spotlight ride a smooth scrollIntoView all
          // the way to its destination instead of measuring once and lying.
          this.track = () => this.place()
          addEventListener("resize", this.track, { passive: true })
          addEventListener("scroll", this.track, { passive: true, capture: true })

          this.onKey = (e) => {
            if (e.key === "Escape") { e.preventDefault(); this.pushEvent("tour:stop", {}) }
            else if (e.key === "ArrowRight") { this.pushEvent("tour:next", {}) }
            else if (e.key === "ArrowLeft") { this.pushEvent("tour:back", {}) }
          }
          addEventListener("keydown", this.onKey)

          this.reveal()
        },

        updated() { this.reveal() },

        destroyed() {
          removeEventListener("resize", this.track)
          removeEventListener("scroll", this.track, { capture: true })
          removeEventListener("keydown", this.onKey)
        },

        reveal() {
          const t = this.target()
          if (t) {
            t.scrollIntoView({
              block: "center", inline: "nearest",
              behavior: this.reduced ? "auto" : "smooth"
            })
          }
          this.place()
          this.card?.focus({ preventScroll: true })
        },

        target() {
          const sel = this.el.dataset.target
          if (!sel) return null
          try { return document.querySelector(sel) } catch { return null }
        },

        place() {
          const t = this.target()
          if (!t) return this.center()

          this.el.classList.remove("is-centered")
          const pad = Number(this.el.dataset.pad || 8)
          const r = t.getBoundingClientRect()
          const x = r.left - pad, y = r.top - pad
          const w = r.width + pad * 2, h = r.height + pad * 2

          this.hole.style.opacity = "1"
          this.hole.style.width = `${w}px`
          this.hole.style.height = `${h}px`
          this.hole.style.borderRadius = `${this.el.dataset.radius || 8}px`
          this.hole.style.transform = `translate3d(${x}px, ${y}px, 0)`

          // Let clicks reach the highlighted element by punching the veil.
          // Only the hole is click-through; the rest still blocks.
          if (this.el.dataset.clicks === "true") {
            this.veil.style.clipPath =
              `path(evenodd, "M0 0 H${innerWidth} V${innerHeight} H0 Z` +
              ` M${x} ${y} H${x + w} V${y + h} H${x} Z")`
          } else {
            this.veil.style.clipPath = ""
          }

          this.card.style.opacity = "1"
          const cw = this.card.offsetWidth, ch = this.card.offsetHeight
          const side = this.side({ x, y, w, h }, cw, ch)

          let cx, cy
          if (side === "top")         { cx = x + w / 2 - cw / 2; cy = y - GAP - ch }
          else if (side === "bottom") { cx = x + w / 2 - cw / 2; cy = y + h + GAP }
          else if (side === "left")   { cx = x - GAP - cw;       cy = y + h / 2 - ch / 2 }
          else                        { cx = x + w + GAP;        cy = y + h / 2 - ch / 2 }

          // never let the card leave the viewport, whatever the placement said
          cx = Math.max(EDGE, Math.min(cx, innerWidth - cw - EDGE))
          cy = Math.max(EDGE, Math.min(cy, innerHeight - ch - EDGE))

          this.el.dataset.placed = side
          this.card.style.transform = `translate3d(${cx}px, ${cy}px, 0)`
        },

        // Honor the asked-for side when it fits; otherwise take the first side
        // that does. A card half off-screen is worse than a card on the wrong side.
        side(box, cw, ch) {
          const fits = {
            top: box.y - GAP - ch > EDGE,
            bottom: box.y + box.h + GAP + ch < innerHeight - EDGE,
            left: box.x - GAP - cw > EDGE,
            right: box.x + box.w + GAP + cw < innerWidth - EDGE
          }
          const asked = this.el.dataset.placement || "auto"
          if (asked !== "auto" && fits[asked]) return asked
          return ["bottom", "top", "right", "left"].find((s) => fits[s]) || "bottom"
        },

        // A step with no target still dims the page — it just doesn't cut
        // anything out. Collapse the hole to a point rather than hiding it:
        // the veil *is* this element's shadow, so opacity 0 would take the
        // dimming with it and leave the card floating over a bright page.
        center() {
          this.el.classList.add("is-centered")
          this.el.dataset.placed = "center"
          this.veil.style.clipPath = ""
          this.hole.style.opacity = "1"
          this.hole.style.width = "0px"
          this.hole.style.height = "0px"
          this.hole.style.transform =
            `translate3d(${innerWidth / 2}px, ${innerHeight / 2}px, 0)`
          this.card.style.opacity = "1"
          this.card.style.transform = ""
        }
      }
    </script>
    """
  end

  defp default_labels do
    %{next: "Next", back: "Back", done: "Got it", skip: "Skip"}
  end

  @doc false
  def centered?(%Step{} = step), do: Step.centered?(step)
end
