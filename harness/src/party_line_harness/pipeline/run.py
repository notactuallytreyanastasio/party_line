"""pipeline-run: drive a prompt across a chain of ``serve-shard`` daemons.

    party-line-harness pipeline-run --model <id> \\
      --stage http://a.ts.net=secretA,http://b.ts.net=secretB \\
      --prompt "why do cats knead?"

Stages are given in pipeline order as ``url=secret`` (secret optional for a
localhost shard). Or lease an assembled pipeline from the exchange instead of
naming shards by hand:

    party-line-harness pipeline-run --model <id> \\
      --server http://exchange:4000 --exchange-key pl-… \\
      --prompt "why do cats knead?"

The driver holds only the tokenizer; the shards hold the weights.
"""

from __future__ import annotations

import argparse
import sys

from . import driver


def _parse_stages(spec: str) -> list[tuple[str, str | None]]:
    out: list[tuple[str, str | None]] = []
    for chunk in spec.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        url, sep, secret = chunk.partition("=")
        out.append((url.strip(), secret.strip() if sep else None))
    if not out:
        raise SystemExit("--stage needs at least one url=secret")
    return out


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="party-line-harness pipeline-run",
        description="drive a prompt across a chain of serve-shard daemons",
    )
    parser.add_argument("--model", required=True, help="mlx-community model id (the shards' model)")
    parser.add_argument("--stage", default=None, help="ordered url=secret list, comma-separated (or lease from --server)")
    parser.add_argument("--server", default=None, help="party-line exchange to lease a pipeline from")
    parser.add_argument("--exchange-key", default=None, help="pl-… key for the lease request")
    parser.add_argument("--prompt", required=True, help="the user turn")
    parser.add_argument("--system", default=None, help="optional system prompt")
    parser.add_argument("--max-tokens", type=int, default=128)
    parser.add_argument("--temperature", type=float, default=0.0, help="0 = greedy")
    parser.add_argument("--top-p", type=float, default=0.95)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    messages = []
    if args.system:
        messages.append({"role": "system", "content": args.system})
    messages.append({"role": "user", "content": args.prompt})

    if args.stage:
        endpoints = _parse_stages(args.stage)
    elif args.server:
        endpoints = driver.lease_pipeline(args.server, args.model, key=args.exchange_key)
        if not endpoints:
            raise SystemExit(f"no complete pipeline for {args.model} on {args.server}")
    else:
        raise SystemExit("give --stage url=secret,… or --server <exchange> to lease a pipeline")

    tokenizer = driver.load_tokenizer(args.model)
    prompt_ids = driver.encode_prompt(tokenizer, messages)
    transport = driver.HttpTransport(endpoints)

    detok = tokenizer.detokenizer
    detok.reset()

    def on_token(tid: int) -> None:
        detok.add_token(tid)
        sys.stdout.write(detok.last_segment)
        sys.stdout.flush()

    try:
        driver.generate(
            transport,
            prompt_ids,
            max_tokens=args.max_tokens,
            eos_ids=driver.eos_token_ids(tokenizer),
            sample=args.temperature > 0,
            temperature=args.temperature,
            top_p=args.top_p,
            on_token=on_token,
        )
    finally:
        transport.close()
    detok.finalize()
    sys.stdout.write(detok.last_segment + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
