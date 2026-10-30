"""Offline NOR semantics and power-cut reference model; never opens hardware.

The model profile is fictional, with 256B pages and 64KiB erase units. It is
NOT a supported-device declaration for the unknown physical Basys 3 flash.
"""
from calibration_record import (SLOT_A, SLOT_B, SLOT_SIZE, COMMIT_OFFSET, COMMIT_SIZE,
                                BODY_SIZE, Record, InvalidRecord, choose,
                                decode_record, decode_body, in_parameter_partition)


class PowerCut(RuntimeError):
    pass


class NorModel:
    page_size = 256
    erase_size = SLOT_SIZE

    def __init__(self, image=None):
        self.memory = bytearray(b'\xff' * 0x400000) if image is None else bytearray(image)
        self.wel = False
        self.busy = False
        self.protected = False
        self.profile_confirmed = False
        self.trace = []
        self.cut_after = None
        self.steps = 0

    def checkpoint(self, name):
        self.trace.append(name)
        self.steps += 1
        if self.cut_after == self.steps:
            raise PowerCut(name)

    def read(self, address, count):
        if self.busy:
            raise RuntimeError('read while WIP')
        if address < 0 or count < 0 or address + count > len(self.memory):
            raise ValueError('read range')
        return bytes(self.memory[address:address + count])

    def write_enable(self):
        if self.busy or self.protected or not self.profile_confirmed:
            raise RuntimeError('busy/protected/unknown device')
        self.wel = True

    def begin_write(self, address, count):
        if not in_parameter_partition(address, count):
            raise ValueError('write outside parameter partition')
        if not self.wel or self.busy or self.protected or not self.profile_confirmed:
            raise RuntimeError('write precondition')
        self.wel = False
        self.busy = True

    def erase(self, address):
        if address % self.erase_size:
            raise ValueError('unaligned erase')
        self.begin_write(address, self.erase_size)
        # Partial erase is intentionally visible to power-cut recovery tests.
        for pos in range(address, address + self.erase_size, 256):
            self.memory[pos:pos + 256] = b'\xff' * 256
            self.checkpoint('erase-granule')

    def program(self, address, data):
        if not data or address // self.page_size != (address + len(data) - 1) // self.page_size:
            raise ValueError('page crossing/empty program')
        if any((old & new) != new for old, new in zip(self.memory[address:address + len(data)], data)):
            raise ValueError('NOR programming may only clear bits')
        self.begin_write(address, len(data))
        for i, byte in enumerate(data):
            self.memory[address + i] &= byte
            self.checkpoint('program-byte')

    def poll_ready(self):
        self.busy = False
        self.checkpoint('WIP-clear')

    def power_cycle(self):
        self.wel = self.busy = False
        self.cut_after = None


def recover(flash):
    records = {}
    for name, address in [('A', SLOT_A), ('B', SLOT_B)]:
        try:
            records[name] = decode_record(flash.read(address, BODY_SIZE),
                                          flash.read(address + COMMIT_OFFSET, COMMIT_SIZE))
        except InvalidRecord:
            records[name] = None
    selected = choose(records['A'], records['B'])
    return selected, records.get(selected)


def save_applied(flash, bank, epoch):
    """Immutable applied snapshot in; commits only after body readback succeeds."""
    bank.validate()
    selected, previous = recover(flash)
    if previous is not None and previous.bank == bank:
        return 'UNCHANGED', previous
    target = SLOT_B if selected == 'A' else SLOT_A
    record = Record(0 if previous is None else (previous.sequence + 1) & 0xFFFFFFFF, bank, epoch)
    body, commit = record.encode()
    flash.write_enable(); flash.erase(target); flash.poll_ready()
    flash.write_enable(); flash.program(target, body); flash.poll_ready()
    readback = flash.read(target, BODY_SIZE)
    flash.checkpoint('body-readback')
    if readback != body or decode_body(readback) != record:
        raise InvalidRecord('body readback mismatch')
    # Commit has its OWN page: never rely on repeated programming in one page.
    flash.write_enable(); flash.program(target + COMMIT_OFFSET, commit); flash.poll_ready()
    restored = decode_record(flash.read(target, BODY_SIZE), flash.read(target + COMMIT_OFFSET, COMMIT_SIZE))
    flash.checkpoint('committed-readback')
    if restored != record:
        raise InvalidRecord('committed readback mismatch')
    return 'SAVED', restored
