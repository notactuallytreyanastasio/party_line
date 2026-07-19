"""The frame two pipeline stages speak: a JSON header plus one optional tensor.

    ┌────────┬───────────────┬──────────────┬───────────────────────┐
    │ "PLPS" │ header len u32 │ header (JSON) │ tensor (.npy) optional │
    └────────┴───────────────┴──────────────┴───────────────────────┘

The header carries the request/response metadata (session, what's wanted,
sampling knobs, or the resulting token). The tensor, when present, is a hidden
state ``[batch, seq, hidden]`` serialized as a self-describing NumPy ``.npy``
blob. Only NumPy is used here — no MLX — so the wire format is unit-tested on
its own; a stage converts to/from ``mx.array`` at the edges.

Hidden states cross the wire as float32: the model may compute in bfloat16
(which NumPy can't represent), and float32 holds every bf16/fp16 value exactly,
so the round-trip is lossless.
"""

from __future__ import annotations

import io
import json
import struct
from typing import Any

import numpy as np

MAGIC = b"PLPS"
_LEN = struct.Struct(">I")
WIRE_DTYPE = np.float32


def encode_frame(header: dict[str, Any], tensor: np.ndarray | None = None) -> bytes:
    """Pack a header (and optional tensor) into one binary frame."""
    body = json.dumps(header, separators=(",", ":")).encode("utf-8")
    parts = [MAGIC, _LEN.pack(len(body)), body]
    if tensor is not None:
        buf = io.BytesIO()
        np.save(buf, np.ascontiguousarray(tensor, dtype=WIRE_DTYPE), allow_pickle=False)
        parts.append(buf.getvalue())
    return b"".join(parts)


def decode_frame(raw: bytes) -> tuple[dict[str, Any], np.ndarray | None]:
    """Unpack a frame into ``(header, tensor|None)``. Raises ``ValueError`` on a
    corrupt or truncated frame."""
    if len(raw) < 8 or raw[:4] != MAGIC:
        raise ValueError("not a pipeline frame")
    (hlen,) = _LEN.unpack_from(raw, 4)
    start = 8
    end = start + hlen
    if end > len(raw):
        raise ValueError("truncated header")
    try:
        header = json.loads(raw[start:end])
    except json.JSONDecodeError as exc:
        raise ValueError(f"bad header json: {exc}") from exc
    rest = raw[end:]
    if not rest:
        return header, None
    try:
        tensor = np.load(io.BytesIO(rest), allow_pickle=False)
    except (ValueError, OSError, EOFError) as exc:
        raise ValueError(f"bad tensor payload: {exc}") from exc
    return header, tensor
