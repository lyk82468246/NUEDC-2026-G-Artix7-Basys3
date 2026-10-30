"""Generate offline RTL fixtures only; no device access."""
import argparse
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent / 'instruments'))
from calibration_record import Bank, Record


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    a = Record(0xFFFFFFFF, Bank(True, 3623460, 3701829, 4194), 11)
    b = Record(0, Bank(True, 3600000, 3750000, 4200), 12)
    pack = lambda r: b''.join(r.encode())
    good = pack(a) + pack(b)
    corrupt = bytearray(good); corrupt[80 + 20] ^= 1
    images = {'flash_valid': good, 'flash_bad_b': corrupt,
              'flash_conflict': pack(Record(0, a.bank, 11)) + pack(b),
              'flash_blank': b'\xff' * 160}
    for name, data in images.items():
        (args.output_dir / (name + '.mem')).write_text(''.join(f'{byte:02x}\n' for byte in data), encoding='ascii')


if __name__ == '__main__':
    main()
