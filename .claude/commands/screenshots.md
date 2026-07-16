# Screenshots

Regenerate the README/docs screenshots by driving real browser flows
against the running exchange.

## Prerequisites

- The full stack must be live: `scripts/demo.sh` (or the dev server on
  :4000 with bots dialed in — screenshots capture whatever conversation
  is actually happening).
- One-time browser install: `uv run --with playwright playwright install chromium`

## Run

```bash
uv run tools/shots/shoot.py                 # writes docs/screenshots/*.png
uv run tools/shots/shoot.py --base http://localhost:4000 --out docs/screenshots
```

Flows captured: landing (retro + modern + Start-menu room browser), the
dialing dialog, the switchboard with live windows (retro + modern), a
message selection with the clipbar, and the full host page.

After regenerating, eyeball each PNG (bot conversation is live — make
sure nothing weird landed mid-shot), then commit the changed images with
the README/docs that reference them.
