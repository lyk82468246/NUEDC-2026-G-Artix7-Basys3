"""Offline calibration record codec. No USB/JTAG/SPI access.

Format 1: 64-byte LE body, separate 16-byte commit at slot+0x100.
Partition addresses are candidates, not authorization to erase real hardware.
"""
from dataclasses import dataclass
import struct
import zlib

FORMAT = 1
COMPATIBILITY = 0x00010001  # unsigned Q16.16 uV/raw; FFT = sine peak
BODY_SIZE = 64
COMMIT_OFFSET = 256
COMMIT_SIZE = 16
SLOT_A, SLOT_B, SLOT_SIZE = 0x3E0000, 0x3F0000, 0x10000


class InvalidRecord(ValueError):
    pass


class SequenceConflict(ValueError):
    pass


@dataclass(frozen=True)
class Bank:
    enabled: bool
    vpp_gain: int
    rms_gain: int
    fft_gain: int

    def validate(self):
        if type(self.enabled) is not bool:
            raise InvalidRecord('enabled must be bool')
        for gain in (self.vpp_gain, self.rms_gain, self.fft_gain):
            if type(gain) is not int or not 0 < gain <= 0xFFFFFFFF:
                raise InvalidRecord('zero/out-of-range gain')


@dataclass(frozen=True)
class Record:
    sequence: int
    bank: Bank
    saved_epoch: int

    def encode(self):
        self.bank.validate()
        if not 0 <= self.sequence <= 0xFFFFFFFF or not 0 <= self.saved_epoch <= 0xFFFFFFFF:
            raise InvalidRecord('sequence/epoch out of range')
        body = bytearray(BODY_SIZE)
        struct.pack_into('<4sHH7I', body, 0, b'GCAL', FORMAT, BODY_SIZE,
                         self.sequence, COMPATIBILITY, int(self.bank.enabled),
                         self.bank.vpp_gain, self.bank.rms_gain, self.bank.fft_gain,
                         self.saved_epoch)
        crc = zlib.crc32(body[:56])
        struct.pack_into('<I', body, 56, crc)
        commit = struct.pack('<4sII', b'CMIT', self.sequence, crc)
        commit += struct.pack('<I', zlib.crc32(commit))
        return bytes(body), commit


def decode_body(body):
    """Validate body before commit programming; never use alone for restore."""
    if len(body) != BODY_SIZE:
        raise InvalidRecord('body length')
    magic, version, length, seq, compat, flags, vp, rm, ft, epoch = struct.unpack_from('<4sHH7I', body)
    if magic != b'GCAL' or version != FORMAT or length != BODY_SIZE:
        raise InvalidRecord('magic/format/length')
    if compat != COMPATIBILITY or flags & ~1:
        raise InvalidRecord('incompatible semantics/flags')
    if body[36:56] != bytes(20) or body[60:64] != bytes(4):
        raise InvalidRecord('reserved bytes')
    if struct.unpack_from('<I', body, 56)[0] != zlib.crc32(body[:56]):
        raise InvalidRecord('body CRC')
    bank = Bank(bool(flags), vp, rm, ft)
    bank.validate()
    return Record(seq, bank, epoch)


def decode_record(body, commit):
    record = decode_body(body)
    if len(commit) != COMMIT_SIZE:
        raise InvalidRecord('commit length')
    magic, seq, crc, marker_crc = struct.unpack('<4sIII', commit)
    if (magic != b'CMIT' or seq != record.sequence or crc != struct.unpack_from('<I', body, 56)[0]
            or marker_crc != zlib.crc32(commit[:12])):
        raise InvalidRecord('missing/torn/mismatched commit')
    return record


def choose(a, b):
    """Return A/B/None. Half-range ambiguity and equal-but-different fail closed."""
    if a is None:
        return 'B' if b is not None else None
    if b is None:
        return 'A'
    delta = (a.sequence - b.sequence) & 0xFFFFFFFF
    if delta == 0:
        if a != b:
            raise SequenceConflict('same sequence, different records')
        return 'A'
    if delta == 0x80000000:
        raise SequenceConflict('sequence half-range ambiguity')
    return 'A' if delta < 0x80000000 else 'B'


def in_parameter_partition(address, length):
    # End address is computed without wrapping/truncating to a 24-bit bus.
    return (type(address) is int and type(length) is int and length > 0
            and address >= SLOT_A and address + length <= SLOT_B + SLOT_SIZE)
