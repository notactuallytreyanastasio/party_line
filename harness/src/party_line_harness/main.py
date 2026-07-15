"""CLI: dial one or more personas into a party line server.

    party-line-harness --server http://127.0.0.1:4000 personas/*.yaml
    party-line-harness --engine fake personas/nova.yaml     # no model needed
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import re
import sys

from .client import PersonaClient
from .inference.fake import FakeEngine
from .memory.client import DeciduousMemory
from .persona import load_persona


def slug(name: str) -> str:
    """A graph-id-safe slug: lowercase, spaces to '-', drop the rest."""
    return re.sub(r"[^a-z0-9_-]", "", name.lower().replace(" ", "-"))


def cli() -> None:
    parser = argparse.ArgumentParser(description="Run LLM personas on a party line")
    parser.add_argument("personas", nargs="+", help="persona YAML card paths")
    parser.add_argument("--server", default="http://127.0.0.1:4000")
    parser.add_argument("--engine", choices=["mlx", "fake"], default="mlx")
    parser.add_argument("--model", default=None, help="mlx-community model id override")
    parser.add_argument("--fake-delay", type=float, default=3.0, help="fake engine max latency (s)")
    parser.add_argument("--memory-url", default=None, help="deciduous memory API base url")
    parser.add_argument("--memory-token", default=None, help="deciduous memory API bearer token")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(message)s",
        datefmt="%H:%M:%S",
    )

    personas = [load_persona(path) for path in args.personas]
    names = [p.name for p in personas]
    if len(set(n.lower() for n in names)) != len(names):
        sys.exit("persona names must be unique on one harness")

    asyncio.run(_run(args, personas))


async def _run(args: argparse.Namespace, personas: list) -> None:
    log = logging.getLogger("party_line")

    if args.engine == "fake":
        engine = FakeEngine(min_delay=min(1.0, args.fake_delay), max_delay=args.fake_delay)
    else:
        from .inference.engine import DEFAULT_MODEL, MlxEngine

        engine = MlxEngine(args.model or DEFAULT_MODEL)
        log.info("loading %s (first run downloads the weights)…", engine.model_id)
        tok_s = await engine.warmup()
        log.info("model warm: %.1f tok/s", tok_s)

    def _memory_for(persona) -> DeciduousMemory | None:
        if not args.memory_url:
            return None
        return DeciduousMemory(
            args.memory_url, args.memory_token or "", graph_id="bot-" + slug(persona.name)
        )

    if args.memory_url:
        log.info("per-bot memory on: %s", args.memory_url)
    clients = [
        PersonaClient(p, engine, args.server, memory=_memory_for(p)) for p in personas
    ]
    log.info("dialing %d persona(s) into %s", len(clients), args.server)
    await asyncio.gather(*(c.run() for c in clients))


if __name__ == "__main__":
    cli()
