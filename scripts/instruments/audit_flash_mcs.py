"""Offline Intel HEX/MCS partition auditor; never programs or erases hardware."""
import argparse
import hashlib
import json
from pathlib import Path
from calibration_record import SLOT_A


def audit(text, erase_size=65536):
    if erase_size not in (4096, 32768, 65536):
        raise ValueError('erase granularity must be verified for the actual flash')
    base = 0
    end_seen = False
    intervals = []
    for number, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        if end_seen or not line.startswith(':'):
            raise ValueError(f'line {number}: malformed/after EOF')
        try:
            data = bytes.fromhex(line[1:])
        except ValueError as error:
            raise ValueError(f'line {number}: non-hex') from error
        if len(data) < 5 or len(data) != data[0] + 5 or sum(data) & 255:
            raise ValueError(f'line {number}: length/checksum')
        count, offset, kind = data[0], int.from_bytes(data[1:3], 'big'), data[3]
        payload = data[4:-1]
        if kind == 0:
            if not count or offset + count > 65536:
                raise ValueError('empty/wrapping data record')
            start, end = base + offset, base + offset + count
            erase_start, erase_end = start // erase_size * erase_size, ((end + erase_size - 1) // erase_size) * erase_size
            if erase_start < 0 or erase_end > SLOT_A:
                raise ValueError('image/erase coverage intersects calibration partition')
            intervals.append((start, end))
        elif kind == 1:
            if count != 0 or offset:
                raise ValueError('bad EOF')
            end_seen = True
        elif kind in (2, 4):
            if count != 2 or offset:
                raise ValueError('bad extended address')
            base = int.from_bytes(payload, 'big') << (4 if kind == 2 else 16)
        else:
            raise ValueError(f'unsupported record type {kind}; fail closed')
    if not end_seen or not intervals or min(s for s, _ in intervals) != 0:
        raise ValueError('must contain EOF and boot image starting at address zero')
    intervals.sort()
    if any(a[1] > b[0] for a, b in zip(intervals, intervals[1:])):
        raise ValueError('overlapping/duplicate image records')
    maximum = max(end for _, end in intervals)
    return {'image_end_exclusive': maximum, 'erase_end_exclusive': (maximum + erase_size - 1) // erase_size * erase_size,
            'erase_size': erase_size, 'parameter_start': SLOT_A, 'data_records': len(intervals),
            'scope': 'address audit only; does NOT certify a programmer erase algorithm'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mcs', type=Path)
    parser.add_argument('--erase-size', type=int, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--bit', type=Path)
    args = parser.parse_args()
    raw = args.mcs.read_bytes()
    result = audit(raw.decode('ascii'), args.erase_size)
    result['mcs_sha256'] = hashlib.sha256(raw).hexdigest()
    if args.bit:
        result['bit_sha256'] = hashlib.sha256(args.bit.read_bytes()).hexdigest()
    result['flash_profile'] = 'MX25L3233F candidate, JEDEC C22016; verify hardware identity and erase policy'
    with args.report.open('x', encoding='utf-8') as report:
        report.write(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
