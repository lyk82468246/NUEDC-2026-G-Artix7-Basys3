#!/usr/bin/env python3
"""Generate an 8192-point Xilinx COE file for a 5-term flat-top window."""

import argparse
import math
from pathlib import Path


N = 8192
Q = 15
SCALE = 1 << Q

# Standard five-term flat-top window coefficients.
A0 = 0.21557895
A1 = 0.41663158
A2 = 0.277263158
A3 = 0.083578947
A4 = 0.006947368


def coefficient(index: int) -> int:
    phase = 2.0 * math.pi * index / (N - 1)
    value = (
        A0
        - A1 * math.cos(phase)
        + A2 * math.cos(2.0 * phase)
        - A3 * math.cos(3.0 * phase)
        + A4 * math.cos(4.0 * phase)
    )
    quantized = int(round(value * SCALE))
    return max(-32768, min(32767, quantized))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("sources/coeffs/flat_top_window_8192.coe"),
        help="output COE path (default: sources/coeffs/flat_top_window_8192.coe)",
    )
    args = parser.parse_args()

    values = [coefficient(i) for i in range(N)]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="ascii", newline="\n") as coe:
        coe.write("memory_initialization_radix=10;\n")
        coe.write("memory_initialization_vector=\n")
        coe.write(",\n".join(str(value) for value in values))
        coe.write(";\n")

    print(f"generated {N} coefficients: {args.output}")
    print(f"quantized range: {min(values)} .. {max(values)}")


if __name__ == "__main__":
    main()
