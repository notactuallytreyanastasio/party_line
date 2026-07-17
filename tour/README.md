# Tour

Guided product tours for Phoenix LiveView — a spotlight that rides on top of
your real UI.

Tour doesn't build you a tour page. It dims your actual app, cuts a hole
around a real element, and floats a card next to it. The thing being explained
is the thing on screen.

```elixir
def mount(_params, _session, socket) do
  {:ok,
   Tour.attach(socket, :onboarding, [
     Tour.step(nil, title: "This is the line", body: "Ten seconds, tops."),
     Tour.step("#speak-form",
       title: "Say something",
       body: "Type here. The room answers.",
       placement: :top,
       clicks: true
     ),
     Tour.step("#buddy-list", title: "Who's on", body: "@ any of them and they turn.", placement: :left)
   ])}
end

def handle_event("show_me", _params, socket) do
  {:noreply, Tour.start(socket, :onboarding)}
end
```

```heex
<%!-- anywhere; it's fixed-position --%>
<Tour.Components.tour tour={@tour} />
```

That's the whole integration. There is no `use Tour`, and you don't write
`handle_event` clauses for Next/Back/Skip: `attach/4` installs a `handle_event`
lifecycle hook that answers Tour's own events and passes everything else
through untouched, so the library stays out of your LiveView's namespace.

## Install

```elixir
def deps do
  [{:tour, "~> 0.1"}]
end
```

One import in `assets/js/app.js`:

```js
import {hooks as tourHooks} from "phoenix-colocated/tour"

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: {...tourHooks}
})
```

and one in `assets/css/app.css`:

```css
@import "../../deps/tour/priv/static/tour.css";
```

Tour's hook is colocated with its component, so it lands in the same
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
Tour.step("[id^='speak-form-']", title: "Say something")
```

## Multiple tours

Attach as many as you like; one runs at a time, and starting one stops
whichever was running.

```elixir
socket
|> Tour.attach(:landing, Tours.landing())
|> Tour.attach(:boards, Tours.boards())
```

## Controlling it

```elixir
Tour.start(socket, :onboarding)   # begin (or restart a finished tour)
Tour.next(socket)                 # on the last step, this finishes it
Tour.back(socket)
Tour.stop(socket)                 # bail; does not mark it done
Tour.running(socket)              # the running tour, or nil
Tour.done?(socket, :onboarding)   # ran to the end?
```

`attach(socket, :id, steps, start: true)` opens a tour on mount. Pair it with
your own "seen it" flag if you only want that once — Tour deliberately keeps
no cookies and no storage.

## Theming

Everything is a custom property, so themes don't fight the library's
selectors:

```css
.tour {
  --tour-veil: rgba(17, 20, 28, 0.62);
  --tour-surface: #fff;
  --tour-ink: #1e2230;
  --tour-ink-soft: #6b7280;
  --tour-accent: #4f46e5;
  --tour-accent-ink: #fff;
  --tour-radius: 10px;
  --tour-shadow: 0 20px 50px -12px rgba(17, 20, 28, 0.45);
  --tour-font: ui-sans-serif, system-ui, sans-serif;
  --tour-ease: cubic-bezier(0.22, 1, 0.36, 1);
  --tour-speed: 0.42s;
}
```

Pass `class` to scope a theme to one tour:
`<Tour.Components.tour tour={@tour} class="tour--mine" />`.

Button text is `labels`:
`<Tour.Components.tour tour={@tour} labels={%{done: "Got it"}} />`

## How it's split

The server owns *which* step you're on; the browser owns *where* things are.
Step order is a pure function over `Tour.Walk` — the tour and your position in
it — testable without a browser.
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
- Tour doesn't remember anything between visits. Persisting "already saw it"
  is your app's call, since only your app knows who the user is.

## License

MIT
