"""Pipeline-split smoke: prove the layer split is lossless.

    uv run python -m party_line_harness.pipeline.smoke [model_id] [n_stages...]

Loads a model once, generates greedily with the *whole* model (mlx-lm's own
``generate_step`` — the independent reference), then generates the same prompt
through an N-way in-process split (and a seeded temperature>0 run) and asserts
the token ids match exactly. Split hidden states cross as float32, which holds
every bf16/fp16 value exactly, so a correct split is bit-for-bit identical to
the whole model — any drift means the surgery is wrong.

The in-process phases use ``LocalTransport`` (direct ``PipelineStage.step``
calls), so they prove the layer surgery + sampling, not the HTTP frame — the
``PLPS`` encode/decode is covered model-free in ``test_pipeline.py``. The final
phase is the real ``serve-shard`` load path (``PipelineStage.load``, each shard
holding only its own weights).

This is the harness's answer to "the MLX path is smoke-verified, not
unit-tested": run it on Apple hardware to trust the split.
"""

from __future__ import annotations

import sys

from ..inference.engine import DEFAULT_MODEL
from . import driver
from .shard import partition_layers
from .stage import PipelineStage, _trunk

PROMPT = "In one sentence, why do cats knead soft blankets?"
N_TOKENS = 24


def _reference(model, tokenizer, prompt_ids: list[int], n: int) -> list[int]:
    """Greedy tokens from the whole model — the independent oracle."""
    import mlx.core as mx
    from mlx_lm.generate import generate_step
    from mlx_lm.sample_utils import make_sampler

    greedy = make_sampler(temp=0.0)
    out: list[int] = []
    for (token, _logprobs), _ in zip(
        generate_step(mx.array(prompt_ids), model, sampler=greedy), range(n)
    ):
        out.append(int(token.item()) if hasattr(token, "item") else int(token))
    return out


def _split(model, prompt_ids: list[int], n_stages: int, eos: set[int], n: int) -> list[int]:
    """Greedy tokens through an ``n_stages``-way in-process split, over one
    shared full model (proves the layer-slicing math)."""
    n_layers = len(_trunk(model).layers)
    stages = [PipelineStage(model, shard) for shard in partition_layers(n_layers, n_stages)]
    transport = driver.LocalTransport(stages)
    return driver.generate(
        transport, prompt_ids, max_tokens=n, eos_ids=eos, sample=False, session="smoke"
    )


def _reference_sampled(model, prompt_ids: list[int], n: int, temp: float, seed: int) -> list[int]:
    """Sampled tokens from the whole model under a fixed seed — the oracle for
    the temperature>0 path (the pipeline-host default, which greedy never hits)."""
    import mlx.core as mx
    from mlx_lm.generate import generate_step
    from mlx_lm.sample_utils import make_sampler

    mx.random.seed(seed)
    sampler = make_sampler(temp=temp, top_p=0.95)
    out: list[int] = []
    for (token, _lp), _ in zip(generate_step(mx.array(prompt_ids), model, sampler=sampler), range(n)):
        out.append(int(token.item()) if hasattr(token, "item") else int(token))
    return out


def _split_sampled(model, prompt_ids: list[int], n_stages: int, eos: set[int], n: int, temp: float, seed: int) -> list[int]:
    """Sampled tokens through the split under the same seed — must match the
    whole model, so a broken sampler/top_p/logprobs path can't ship green."""
    import mlx.core as mx

    n_layers = len(_trunk(model).layers)
    stages = [PipelineStage(model, shard) for shard in partition_layers(n_layers, n_stages)]
    mx.random.seed(seed)
    return driver.generate(
        driver.LocalTransport(stages), prompt_ids, max_tokens=n, eos_ids=eos,
        sample=True, temperature=temp, top_p=0.95, session="sampled",
    )


def _sharded_split(model_id: str, prompt_ids: list[int], n_stages: int, eos: set[int], n: int):
    """Greedy tokens through a real partial-load split — each shard is loaded via
    ``PipelineStage.load``, holding only its own weights (the ``serve-shard``
    path). Returns ``(tokens, rss_gb)`` where rss is this process's peak."""
    import resource

    stages = [PipelineStage.load(model_id, f"{i}/{n_stages}") for i in range(n_stages)]
    transport = driver.LocalTransport(stages)
    got = driver.generate(
        transport, prompt_ids, max_tokens=n, eos_ids=eos, sample=False, session="sharded"
    )
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9
    return got, rss


def main() -> int:
    model_id = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_MODEL
    stage_counts = [int(a) for a in sys.argv[2:]] or [2, 3]

    from mlx_lm import load

    print(f"loading {model_id} …", flush=True)
    model, tokenizer = load(model_id)
    n_layers = len(_trunk(model).layers)
    print(f"model has {n_layers} layers\n", flush=True)

    messages = [{"role": "user", "content": PROMPT}]
    prompt_ids = list(tokenizer.apply_chat_template(messages, add_generation_prompt=True))
    eos = driver.eos_token_ids(tokenizer)

    print("reference (whole model, greedy) …", flush=True)
    ref = _reference(model, tokenizer, prompt_ids, N_TOKENS)
    print(f"  {ref}")
    print(f"  {tokenizer.detokenizer.__class__.__name__}: {_decode(tokenizer, ref)!r}\n")

    ok = True
    for count in stage_counts:
        if count > n_layers:
            print(f"skip {count}-way: only {n_layers} layers")
            continue
        print(f"{count}-way split (layers {[s.label for s in partition_layers(n_layers, count)]}) …", flush=True)
        got = _split(model, prompt_ids, count, eos, N_TOKENS)
        match = got == ref
        ok = ok and match
        mark = "OK — identical to the whole model" if match else "MISMATCH"
        print(f"  {got}")
        print(f"  {mark}\n")

    # temperature>0 sampling — the pipeline-host default, which greedy never
    # exercises. Same seed → the lossless split must sample identically.
    print("2-way split, temperature 0.8 (seeded sampling path) …", flush=True)
    ref_s = _reference_sampled(model, prompt_ids, N_TOKENS, temp=0.8, seed=1234)
    got_s = _split_sampled(model, prompt_ids, 2, eos, N_TOKENS, temp=0.8, seed=1234)
    match = got_s == ref_s
    ok = ok and match
    print(f"  whole: {ref_s}")
    print(f"  split: {got_s}")
    print(f"  {'OK — identical sampled sequence' if match else 'MISMATCH'}\n")

    # the real serve-shard path: each shard loads only its own weights.
    del model  # free the whole model before measuring a shard's footprint
    print("partial-load 2-way split (each shard holds only its weights) …", flush=True)
    got, rss = _sharded_split(model_id, prompt_ids, 2, eos, N_TOKENS)
    match = got == ref
    ok = ok and match
    print(f"  {got}")
    print(f"  {'OK — identical to the whole model' if match else 'MISMATCH'}")
    print(f"  peak RSS holding both shards in this process: {rss:.2f} GB\n")

    print("PASS: the split is lossless" if ok else "FAIL: a split diverged from the whole model")
    return 0 if ok else 1


def _decode(tokenizer, ids: list[int]) -> str:
    detok = tokenizer.detokenizer
    detok.reset()
    for tid in ids:
        detok.add_token(tid)
    detok.finalize()
    return detok.text


if __name__ == "__main__":
    raise SystemExit(main())
