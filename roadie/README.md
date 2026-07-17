# Roadie

Guided product tours for Phoenix LiveView — a spotlight that rides on top of
your real UI.

Roadie doesn't build you a tour page. It dims your actual app, cuts a hole
around a real element, and floats a card next to it. The thing being explained
is the thing on screen.

```elixir
def mount(_params, _session, socket) do
  {:ok,
   Roadie.attach(socket, :onboarding, [
     Roadie.step(nil, title: "This is the line", body: "Ten seconds, tops."),
     Roadie.step("#speak-form",
       title: "Say something",
       body: "Type here. The room answers.",
       placement: :top,
       clicks: true
     ),
     Roadie.step("#buddy-list", title: "Who's on", body: "@ any of them and they turn.", placement: :left)
   ])}
end

def handle_event("show_me", _params, socket) do
  {:noreply, Roadie.start(socket, :onboarding)}
end
```

```heex
<%!-- anywhere; it's fixed-position --%>
<Roadie.Components.roadie roadie={@roadie} />
```

That's the whole integration. There is no `use Roadie`, and you don't write
`handle_event` clauses for Next/Back/Skip: `attach/4` installs a `handle_event`
lifecycle hook that answers Roadie's own events and passes everything else
through untouched, so the library stays out of your LiveView's namespace.

## Install

```elixir
def deps do
  [{:roadie, "~> 0.1"}]
end
```

One import in `assets/js/app.js`:

```js
import {hooks as roadieHooks} from "phoenix-colocated/roadie"

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: {...roadieHooks}
})
```

and one in `assets/css/app.css`:

```css
@import "../../deps/roadie/priv/static/roadie.css";
```

Roadie's hook is colocated with its component, so it lands in the same
`phoenix-colocated` tree as your app's own hooks. No bundler config.

## Steps

| option | default | |
|---|---|---|
| `:title` | — | required; a step with no title is caught at boot |
| `:body` | `nil` | the sentence under the title |
| `:placement` | `:auto` | `:top`, `:bottom`, `:left`, `:right`. Every placement flips rather than run off the viewport |
| `:pad` | `8` | px of room the spotlight leaves around the element |
| `:radius` | `8` | px corner radius of the spotlight |
| `:clicks` | `false` | let the highlighted element stay clickable — tell someone to press the thing and let them press it |

A step with `target: nil` is a card in the middle of the screen, for opening
("here's what this place is") and closing ("that's it — go") a tour.

Targets are plain CSS selectors, so they can be as loose as the markup needs:

```elixir
# the window index is assigned at runtime; match the prefix
Roadie.step("[id^='speak-form-']", title: "Say something")
```

## Multiple tours

Attach as many as you like; one runs at a time, and starting one stops
whichever was running.

```elixir
socket
|> Roadie.attach(:landing, Tours.landing())
|> Roadie.attach(:boards, Tours.boards())
```

## Controlling it

```elixir
Roadie.start(socket, :onboarding)   # begin (or restart a finished tour)
Roadie.next(socket)                 # on the last step, this finishes it
Roadie.back(socket)
Roadie.stop(socket)                 # bail; does not mark it done
Roadie.running(socket)              # the running tour, or nil
Roadie.done?(socket, :onboarding)   # ran to the end?
```

`attach(socket, :id, steps, start: true)` opens a tour on mount. Pair it with
your own "seen it" flag if you only want that once — Roadie deliberately keeps
no cookies and no storage.

## Theming

Everything is a custom property, so themes don't fight the library's
selectors:

```css
.roadie {
  --roadie-veil: rgba(17, 20, 28, 0.62);
  --roadie-surface: #fff;
  --roadie-ink: #1e2230;
  --roadie-ink-soft: #6b7280;
  --roadie-accent: #4f46e5;
  --roadie-accent-ink: #fff;
  --roadie-radius: 10px;
  --roadie-shadow: 0 20px 50px -12px rgba(17, 20, 28, 0.45);
  --roadie-font: ui-sans-serif, system-ui, sans-serif;
  --roadie-ease: cubic-bezier(0.22, 1, 0.36, 1);
  --roadie-speed: 0.42s;
}
```

Pass `class` to scope a theme to one tour:
`<Roadie.Components.roadie roadie={@roadie} class="roadie--mine" />`.

Button text is `labels`:
`<Roadie.Components.roadie roadie={@roadie} labels={%{done: "Got it"}} />`

## How it's split

The server owns *which* step you're on; the browser owns *where* things are.
Step order is a pure function over `Roadie.Tour`, testable without a browser.
Geometry — measuring, flipping, scrolling, keyboard — belongs to the only
process that can actually measure, and lives in the hook.

The dimming is one element: the spotlight casts a `box-shadow` big enough to
cover any viewport, so moving the hole *is* the transition. Nothing cross-fades
and nothing repaints the screen.

## Keyboard and motion

`Esc` skips, `←`/`→` walk. The card takes focus on each step and is a
`role="dialog"`. `prefers-reduced-motion` drops the glide and the smooth scroll.

## Known limits

- One tour at a time, by design.
- `clicks: true` punches the veil with `clip-path`, which needs `path()`
  support (every current browser; not IE).
- Roadie doesn't remember anything between visits. Persisting "already saw it"
  is your app's call, since only your app knows who the user is.

## License

MIT
