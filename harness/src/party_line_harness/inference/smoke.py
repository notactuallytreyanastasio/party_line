"""Standalone MLX smoke check — iterate on prompts here, where the loop is
seconds, before anything touches a live room.

    uv run python -m party_line_harness.inference.smoke [model_id]

Loads the model, renders a fixture transcript for each shipped persona,
generates, and reports tok/s plus the post-processed message. Fails loudly
if output leaks other speakers' lines or a self-prefix.
"""

from __future__ import annotations

import asyncio
import sys
import time
from pathlib import Path

from ..persona import load_persona
from .engine import DEFAULT_MODEL, MlxEngine

FIXTURE = [
    {"sender": {"name": "Bobby", "kind": "human"}, "body": "ok so my building's raccoons figured out the motion-sensor lights. they wait for the dark cycle.", "mentions": []},
    {"sender": {"name": "Priya", "kind": "human"}, "body": "that's ominous. how long until they're organized", "mentions": []},
]

TOPIC = "whether cities are accidentally breeding smarter raccoons"


async def main() -> int:
    model_id = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_MODEL
    cards = sorted((Path(__file__).resolve().parents[4] / "personas").glob("*.yaml"))
    personas = [load_persona(c) for c in cards]
    roster = ["Bobby", "Priya"] + [p.name for p in personas]

    engine = MlxEngine(model_id)
    print(f"loading {model_id} …", flush=True)
    started = time.monotonic()
    warm_tok_s = await engine.warmup()
    print(f"loaded + warm in {time.monotonic() - started:.1f}s ({warm_tok_s:.1f} tok/s warm)\n")

    failures = 0
    for persona in personas:
        cancel = asyncio.Event()
        t0 = time.monotonic()
        out = await engine.generate(persona, TOPIC, roster, FIXTURE, cancel)
        dt = time.monotonic() - t0

        problems = []
        if not out:
            problems.append("empty output")
        else:
            if out.lower().startswith(persona.name.lower() + ":"):
                problems.append("self prefix survived")
            for name in roster:
                if f"\n{name}:" in out or out.startswith(f"{name}:"):
                    problems.append(f"leaked speaker line for {name}")
            if "<|channel" in out or "<channel|" in out or "<|message|>" in out:
                problems.append("thinking-channel markers leaked into output")
            if out.lower().startswith(("thinking process", "here's a plan", "analysis")):
                problems.append("chain-of-thought leaked into output")

        status = "OK " if not problems else "FAIL"
        failures += bool(problems)
        print(f"[{status}] {persona.name} ({dt:.1f}s): {out!r}")
        for p in problems:
            print(f"       ! {p}")

    # opener check: empty transcript must produce a topic opener
    cancel = asyncio.Event()
    t0 = time.monotonic()
    opener = await engine.generate(personas[0], TOPIC, roster, [], cancel)
    print(f"\n[opener] {personas[0].name} ({time.monotonic() - t0:.1f}s): {opener!r}")
    if not opener:
        failures += 1

    print(f"\n{'all good' if failures == 0 else f'{failures} failure(s)'}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
