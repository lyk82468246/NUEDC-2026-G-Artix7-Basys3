"""UTG900 user-wave encoding and coherent multi-tone synthesis (stdlib only).

BSV layout checked against the independent MIT-licensed device implementation:
https://github.com/renaatd/utg962/blob/main/utg962/utg962.py
Protocol facts: ASCII HEAD/DATA sections, signed little-endian 16-bit points.
No third-party implementation is bundled.
"""
from __future__ import annotations

import csv
from fractions import Fraction
from functools import reduce
import hashlib
import json
import math
from pathlib import Path
import struct

MAX_POINTS = 4000
HEADER = b"VPP:0\r\nOFFSET:0\r\nRATEPOS:0\r\nRATENEG:0\r\nMAX:32767\r\nMIN:-32767\r\n"


def validate_samples(samples):
    values = list(samples)
    if not 2 <= len(values) <= MAX_POINTS:
        raise ValueError(f"Expected 2..{MAX_POINTS} samples per repeating period")
    for value in values:
        if isinstance(value, bool) or not math.isfinite(float(value)) or not -1 <= float(value) <= 1:
            raise ValueError("Samples must be finite normalized values in [-1, 1]; no automatic clipping")
    return [float(value) for value in values]


def encode_bsv(samples):
    values = validate_samples(samples)
    codes = [round(value * 32767) for value in values]
    return (f"[HEAD]:{len(HEADER)}\r\n".encode("ascii") + HEADER
            + f"[DATA]:{len(codes)}\r\n".encode("ascii")
            + struct.pack(f"<{len(codes)}h", *codes))


def decode_bsv(payload):
    """Accept this script's normalized BSV variant only, not unknown scaling."""
    prefix = f"[HEAD]:{len(HEADER)}\r\n".encode("ascii") + HEADER + b"[DATA]:"
    if not payload.startswith(prefix):
        raise ValueError("Unsupported BSV header/scaling; use normalized JSON/CSV or this tool's BSV")
    count_raw, separator, data = payload[len(prefix):].partition(b"\r\n")
    if not separator or not count_raw.isdigit():
        raise ValueError("Invalid BSV data length")
    count = int(count_raw)
    if not 2 <= count <= MAX_POINTS or len(data) != count * 2:
        raise ValueError("Truncated/oversized BSV or trailing bytes")
    codes = struct.unpack(f"<{count}h", data)
    return validate_samples([code / 32767 for code in codes])


def sample_summary(samples):
    values = validate_samples(samples)
    payload = encode_bsv(values)
    return {"points": len(values), "min": min(values), "max": max(values),
            "mean": math.fsum(values) / len(values),
            "rms": math.sqrt(math.fsum(value * value for value in values) / len(values)),
            "bsv_bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}


def load_samples(path):
    path = Path(path)
    if path.stat().st_size > 2_000_000:
        raise ValueError("Waveform file exceeds 2 MB")
    if path.suffix.lower() == ".bsv":
        return decode_bsv(path.read_bytes())
    if path.suffix.lower() == ".json":
        content = json.loads(path.read_text(encoding="utf-8-sig"))
        return validate_samples(content["samples"] if isinstance(content, dict) else content)
    values = []
    with path.open(encoding="utf-8-sig", newline="") as stream:
        for row in csv.reader(stream):
            if not row or not row[0].strip() or row[0].lstrip().startswith("#"):
                continue
            if len(row) != 1:
                raise ValueError("CSV/TXT must have one normalized value per row, without a header")
            values.append(float(row[0]))
    return validate_samples(values)


def synthesize_multitone(plan):
    """Keep requested voltages/ratios; reject aliasing or hidden rescaling.

    hz on the instrument is the repetition frequency of the entire table, not
    a tone frequency. With N points, equivalent table sampling is N*repeat_hz.
    """
    tones = plan["tones"]
    points = plan.get("points", MAX_POINTS)
    if type(points) is not int or not 2 <= points <= MAX_POINTS or not isinstance(tones, list) or not 1 <= len(tones) <= 64:
        raise ValueError("Expected 1..64 tones and 2..4000 integer points")
    parsed = []
    for tone in tones:
        hz, vpp, phase = (float(tone[key]) for key in ("hz", "vpp", "phase_deg")) if "phase_deg" in tone else (float(tone["hz"]), float(tone["vpp"]), 0.0)
        if not all(math.isfinite(x) for x in (hz, vpp, phase)) or not 0 < hz <= 500e3 or vpp <= 0:
            raise ValueError("Tone frequencies must be (0, 500 kHz], amplitude >0, all values finite")
        # Bound exact decimal arithmetic to micro-Hz resolution.
        fraction = Fraction(str(tone["hz"]))
        micro = fraction * 1_000_000
        if micro.denominator != 1:
            raise ValueError("Tone frequencies must be exact multiples of 1 micro-Hz")
        parsed.append((int(micro), hz, vpp, phase))
    repeat = reduce(math.gcd, (tone[0] for tone in parsed)) / 1_000_000
    if "repeat_hz" in plan:
        repeat = float(plan["repeat_hz"])
    if not math.isfinite(repeat) or not 1e-6 <= repeat <= 1e6:
        raise ValueError("Invalid waveform repetition frequency")
    harmonics = []
    for _, hz, _, _ in parsed:
        harmonic = hz / repeat
        if not math.isclose(harmonic, round(harmonic), rel_tol=0, abs_tol=1e-8):
            raise ValueError("Each tone frequency must be an integer multiple of repeat_hz")
        harmonic = round(harmonic)
        if not 0 < harmonic < points / 2:
            raise ValueError("Tone reaches table Nyquist limit; increase repeat_hz or sample count")
        harmonics.append(harmonic)
    vpp = float(plan.get("vpp", math.fsum(tone[2] for tone in parsed)))
    offset = float(plan.get("offset_v", 0))
    if not math.isfinite(vpp) or not math.isfinite(offset) or not 0.002 <= vpp <= 5 or abs(offset) + vpp / 2 > 5:
        raise ValueError("Invalid output scale/envelope")
    # An upper bound valid between samples as well as at sampled instants.
    if math.fsum(tone[2] for tone in parsed) > vpp * (1 + 1e-12):
        raise ValueError("Sum of tone amplitudes exceeds Vpp scale; no implicit normalization")
    values = [math.fsum(tone[2] / vpp * math.sin(2 * math.pi * harmonic * i / points + math.radians(tone[3]))
                        for tone, harmonic in zip(parsed, harmonics)) for i in range(points)]
    values = validate_samples(values)
    return {"samples": values, "repeat_hz": repeat, "vpp": vpp, "offset_v": offset,
            "tones": [dict(hz=t[1], vpp=t[2], phase_deg=t[3], harmonic=h) for t, h in zip(parsed, harmonics)],
            "table_sample_rate_hz": repeat * points, "summary": sample_summary(values)}
