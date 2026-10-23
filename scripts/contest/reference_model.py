"""Offline G-contest reference vectors. Standard library only, NO USB/JTAG.

Units are mV peak for Tone. RAW_PER_MV is an artificial fixture scale, NOT a
hardware calibration. FFT uses exact floating butterflies after quantized input
and Q1.15 window multiplication; it is not a bit-exact Xilinx FFT/CORDIC model.
"""
from dataclasses import dataclass, asdict
import argparse
import cmath
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
N, FS, RAW_PER_MV = 8192, 4_096_000, 32
WINDOW = (0.21557895, -0.41663158, 0.277263158, -0.083578947, 0.006947368)


@dataclass(frozen=True)
class Tone:
    hz: float
    peak_mv: float
    phase: float = 0.0


def waveform(tones, count=N, sample_rate=FS):
    return [sum(t.peak_mv * math.sin(2*math.pi*t.hz*i/sample_rate+t.phase)
                for t in tones) for i in range(count)]


def normalize(tones, vpp_mv):
    dense = waveform(tones, N*16, FS*16)
    gain = vpp_mv / (max(dense)-min(dense))
    return [Tone(t.hz, t.peak_mv*gain, t.phase) for t in tones]


def fft(values):
    """Unscaled forward FFT, independently executable without numpy."""
    a = [complex(x) for x in values]
    n = len(a)
    if n < 2 or n & (n-1):
        raise ValueError("FFT length must be a power of two >=2")
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    size = 2
    while size <= n:
        step = cmath.exp(-2j*math.pi/size)
        for first in range(0, n, size):
            phase = 1+0j
            for k in range(size//2):
                left, right = a[first+k], phase*a[first+k+size//2]
                a[first+k], a[first+k+size//2] = left+right, left-right
                phase *= step
        size *= 2
    return a


def window_q15():
    return [max(-32768, min(32767, round(32768*sum(
        c*math.cos(j*2*math.pi*i/(N-1)) for j, c in enumerate(WINDOW)))))
        for i in range(N)]


def adc_fixture(samples_mv):
    # Offset-binary 12 bit -> signed 16 bit, exactly as the existing AFE shift.
    codes = [max(0, min(4095, round(x*RAW_PER_MV/16)+2048)) for x in samples_mv]
    return [(c-2048)*16 for c in codes]


def spectrum(raw):
    q = window_q15()
    windowed = [max(-32768, min(32767, (int(x)*w) >> 15)) for x, w in zip(raw, q)]
    # RTL shifts I/Q by one, BUT CORDIC SignedFraction 30 -> 31 adds
    # one fractional bit (Q2.28 -> Q2.29), doubling the output raw codes.
    # These factors cancel: magnitude RAW is approximately abs(unscaled FFT).
    # CORDIC integer rounding and XFFT butterfly truncation are not modeled.
    mags = [abs(x) for x in fft(windowed)[:N//2]]
    return mags, sum(q)/32768


def components(mags, mode="B", relative_floor=0.005, exclude_bins=6):
    lo, hi = 20, (400 if mode == "A" else 1000)
    floor = max(1, max(mags[lo:hi+1])*relative_floor)
    remaining = set(range(lo, hi+1))
    peaks = []
    for _ in range(3):
        if not remaining:
            break
        k = max(remaining, key=lambda i: (mags[i], -i))
        if mags[k] < floor:
            break
        peaks.append(k)
        remaining.difference_update(range(k-exclude_bins, k+exclude_bins+1))
    return sorted(peaks)


def fir_response(hz):
    text = (ROOT/"sources/coeffs/fir_lp_600k_95t.coe").read_text(encoding="utf-8")
    vector = text.split("memory_initialization_vector=", 1)[1].split(";", 1)[0]
    coefficients = [round(float(x.strip())*32768)/32768 for x in vector.split(",")]
    return sum(c*cmath.exp(-2j*math.pi*hz*i/FS) for i, c in enumerate(coefficients))


def filtered_tones(tones):
    return [Tone(t.hz, t.peak_mv*abs(fir_response(t.hz)),
                 t.phase+cmath.phase(fir_response(t.hz))) for t in tones]


def cases():
    # Harmonic 3 is deliberately larger than the fundamental in the first case.
    definitions = [
        ("A_10500_weak_fundamental", "A", 100, [(10500,.25,0),(31500,1,.3),(42000,.4,1)]),
        ("A_upper_edge", "A", 250, [(50000,1,0),(150000,.5,.7),(200000,.3,1.2)]),
        ("B_upper_edge", "B", 50, [(125000,1,0),(375000,.5,.7),(500000,.3,1.2)]),
        ("B_off_bin", "B", 100, [(10250,.25,0),(30750,1,.3),(41000,.4,1)]),
        ("B_two_components", "B", 250, [(20000,.2,.6),(100000,1,0)]),
        ("B_phase_zero", "B", 100, [(10000,1,0),(30000,.5,0),(40000,.25,0)]),
        ("B_phase_shift", "B", 100, [(10000,1,0),(30000,.5,1.3),(40000,.25,.7)]),
    ]
    return [(name, mode, normalize([Tone(*t) for t in tones], pp))
            for name, mode, pp, tones in definitions]


def analyse(name, mode, tones):
    samples = waveform(tones)
    raw = adc_fixture(samples)
    mags, coherent_sum = spectrum(raw)
    indices = components(mags, mode)
    report = dict(name=name, simulated=True, mode=mode, n=N, fs_hz=FS,
                  fixture_raw_per_mv=RAW_PER_MV, tones=[asdict(t) for t in tones],
                  vpp_mv=max(samples)-min(samples),
                  rms_record_mv=math.sqrt(sum(x*x for x in samples)/N),
                  rms_full_period_mv=math.sqrt(sum(t.peak_mv**2 for t in tones)/2),
                  vpp_raw=max(raw)-min(raw), rms_raw=math.isqrt(sum(x*x for x in raw)//N),
                  components=[dict(bin=k, hz=k*FS/N,
                                   peak_mv=2*mags[k]/coherent_sum/RAW_PER_MV) for k in indices])
    return report, raw, mags


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT/"test_results/contest_reference")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    reports = []
    for name, mode, tones in cases():
        report, raw, mags = analyse(name, mode, tones)
        reports.append(report)
        expected = [len(report['components'])]
        for c in report['components']:
            expected += [c['bin'], round(mags[c['bin']])]
        expected += [0] * (7-len(expected))
        (args.output_dir/f"{name}_expected.mem").write_text("\n".join(f"{x:08x}" for x in expected)+"\n", encoding="ascii")
        (args.output_dir/f"{name}_time.mem").write_text("\n".join(f"{x&65535:04x}" for x in raw)+"\n", encoding="ascii")
        (args.output_dir/f"{name}_mag.mem").write_text("\n".join(f"{round(x):08x}" for x in mags)+"\n", encoding="ascii")
    (args.output_dir/"reference.json").write_text(json.dumps(reports, indent=2)+"\n", encoding="utf-8")
    print(f"Generated {len(reports)} OFFLINE cases in {args.output_dir}; no hardware calibration implied")


if __name__ == "__main__":
    main()
