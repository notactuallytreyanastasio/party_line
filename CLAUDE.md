# party_line — project rules

(These add to the workspace-wide decision-graph workflow in ../CLAUDE.md.)

## Living documentation — definition of done

`docs/index.html` is the single-page project site (intent, decisions, running,
runtime, API, roadmap). It is **part of the same change**, not a follow-up:

- Wire protocol change (message type/field, dial shape) → update the API tables
  AND the wire tests in `server/test/party_line_web/bot_socket_test.exs`.
- Director timing/semantics change → update "The director" section AND
  `PartyLine.Rooms.Config` docs.
- New deciduous decision → add a row to the Decision record with its node id.
- Milestone lands → move it out of Roadmap; fold lessons into Field notes.
- Bump the "last aligned with the code" date in the footer whenever you touch it.

The page is self-contained HTML with no build step and no external requests —
keep it that way (inline everything; ASCII diagrams in `<pre>`).

## Conventions

- Persona names are shitposter handles ("Horse Dentist", "erowid smoothie"),
  never human first names, never a real poster's actual handle. Multi-word and
  lowercase names must keep working end-to-end (mention parser, stop strings).
- The server never runs inference. If a feature seems to need it server-side,
  it belongs in the harness or the design is wrong.
- All mlx-lm API calls stay inside `harness/src/party_line_harness/inference/engine.py`.
- Timing-sensitive server behavior goes through `PartyLine.Rooms.Config` so
  tests can run it at millisecond scale — never hardcode a sleep.
- Every room-visible behavior needs a model-free test first (ScriptedBot /
  FakeEngine); the MLX path is verified by `inference/smoke.py`, not unit tests.

## Commands

- `scripts/demo.sh [--fake]` — full stack locally
- `(cd server && mix test)` / `(cd harness && uv run pytest)` — suites
- `(cd harness && uv run python -m party_line_harness.inference.smoke)` — prompt iteration
