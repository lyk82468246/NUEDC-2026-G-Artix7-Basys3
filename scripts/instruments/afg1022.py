"""Tektronix AFG1022 USBTMC control. No reset; output ON is always explicit."""
from __future__ import annotations

import argparse
import csv
import json
import math
from pathlib import Path
import struct
import sys
import threading

from resource_lock import ResourceLock
from utg932 import boolean, channel_number, number, resource_manager, serialized

ROOT = Path(__file__).resolve().parents[2]
WAVES = {"sine": "SIN", "square": "SQU", "pulse": "PULS", "ramp": "RAMP", "dc": "DC", "arb": "EMEM"}
LIMITS = {"sine": 25e6, "square": 1e6, "pulse": 1e6, "ramp": 100e3, "dc": 1e6, "arb": 1e6}


def is_afg_resource(resource):
    parts = resource.upper().split("::")
    try:
        return (parts[0].startswith("USB") and parts[-1] == "INSTR"
                and int(parts[1], 16 if parts[1].startswith("0X") else 10) == 0x0699
                and int(parts[2], 16 if parts[2].startswith("0X") else 10) == 0x0353)
    except (IndexError, ValueError):
        return False


def validate_settings(*, waveform="sine", hz=1000, vpp=0.1, offset_v=0, load="HIGHZ"):
    if waveform not in WAVES or load not in ("HIGHZ", "50"):
        raise ValueError("Unsupported waveform/load")
    hz, vpp, offset_v = map(number, (hz, vpp, offset_v))
    if not 1e-6 <= hz <= LIMITS[waveform]:
        raise ValueError(f"{waveform} automation frequency: 1 uHz..{LIMITS[waveform]:g} Hz")
    if not 0.002 <= vpp <= 5:
        raise ValueError("Automation amplitude: 0.002..5 Vpp")
    if (2 if load == "50" else 1) * (abs(offset_v) + vpp / 2) > 5:
        raise ValueError("Open-circuit voltage exceeds automation +/-5 V envelope")
    return dict(waveform=waveform, hz=hz, vpp=vpp, offset_v=offset_v, load=load)


def sample_codes(samples):
    samples = list(samples)
    if not 2 <= len(samples) <= 8192:
        raise ValueError("Expected 2..8192 normalized samples")
    values = [number(x) for x in samples]
    if any(not -1 <= x <= 1 for x in values):
        raise ValueError("Samples must be in [-1, 1]; no clipping or normalization")
    return [round((x + 1) * 16383 / 2) for x in values]


def load_samples(path):
    path = Path(path)
    if path.stat().st_size > 2_000_000:
        raise ValueError("Waveform file exceeds 2 MB")
    if path.suffix.lower() == ".json":
        data = json.loads(path.read_text(encoding="utf-8-sig"))
        return data["samples"] if isinstance(data, dict) else data
    with path.open(encoding="utf-8-sig", newline="") as stream:
        rows = [row for row in csv.reader(stream) if row and row[0].strip() and not row[0].lstrip().startswith("#")]
    if any(len(row) != 1 for row in rows):
        raise ValueError("CSV/TXT requires one sample per row, no header")
    return [row[0] for row in rows]


class AFG1022:
    def __init__(self, resource=None, *, timeout_ms=5000, visa_library=None):
        self._io_lock = threading.RLock()
        self._lease = ResourceLock(ROOT / ".lab_locks/afg1022.lock").acquire()
        self.rm = self.device = None
        self.broken = False
        try:
            self.rm = resource_manager(visa_library)
            if resource is None:
                resources = [r for r in self.rm.list_resources("USB?*::INSTR") if is_afg_resource(r)]
                if len(resources) != 1:
                    raise RuntimeError(f"Expected one AFG1022, found {len(resources)}; use --resource")
                resource = resources[0]
            if not is_afg_resource(resource):
                raise ValueError("Expected AFG1022 USB 0699:0353 resource")
            self.resource = resource
            self.device = self.rm.open_resource(resource, open_timeout=timeout_ms)
            self.device.timeout = timeout_ms
            self.device.read_termination = None
            self.device.write_termination = "\n"
            self.identity = self.query("*IDN?")
            fields = [x.strip().upper() for x in self.identity.split(",")]
            if len(fields) < 4 or fields[:2] != ["TEKTRONIX", "AFG1022"]:
                raise RuntimeError(f"Unexpected identity: {self.identity}")
        except BaseException:
            self.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    @serialized
    def close(self):
        try:
            try:
                if self.device is not None:
                    self.device.close()
            finally:
                if self.rm is not None:
                    self.rm.close()
        finally:
            self.device = self.rm = None
            self._lease.release()

    def _io(self, command, query=False, emergency=False):
        if any(c in command for c in ("\r", "\n", ";", "\0")):
            raise ValueError("One SCPI command per transaction")
        if self.broken and not emergency:
            raise RuntimeError("Failed session; reconnect before further commands")
        try:
            if query:
                result = self.device.query(command).strip()
                if not result:
                    raise RuntimeError(f"Empty reply: {command}")
                return result
            if self.device.write(command) != len(command.encode("ascii")) + 1:
                raise IOError("Short VISA write")
        except BaseException:
            self.broken = True
            raise

    @serialized
    def query(self, command):
        if "?" not in command.split()[0]:
            raise ValueError("Expected query")
        return self._io(command, query=True)

    def _write(self, command):
        self._io(command)

    def identify(self):
        return self.identity

    @serialized
    def settings(self, channel=1):
        ch = channel_number(channel)
        p = f"SOUR{ch}:"
        result = dict(channel=ch, output=boolean(self.query(f"OUTP{ch}?")),
                      waveform=self.query(p + "FUNC?"), hz=number(self.query(p + "FREQ?")),
                      amplitude=number(self.query(p + "VOLT?")),
                      offset_v=number(self.query(p + "VOLT:OFFS?")),
                      load_ohm=number(self.query(f"OUTP{ch}:IMP?")),
                      concurrent=boolean(self.query(p + "FREQ:CONC?")))
        # Firmware does not support VOLT:UNIT?; do not label arbitrary panel units Vpp.
        if ch == 1:
            result["mode"] = self.query(p + "FREQ:MODE?")
            result["modulation"] = {mode: boolean(self.query(p + mode + ":STAT?"))
                                    for mode in ("AM", "FM", "PM", "FSK", "BURS")}
        return result

    def _check_error(self):
        error = self.query("SYST:ERR?")
        if int(error.split(",")[0]) != 0:
            raise RuntimeError(f"Instrument error (queue consumed): {error}")

    @serialized
    def output_off(self, channel=1):
        ch = channel_number(channel)
        self._write(f"OUTP{ch} OFF")
        if boolean(self.query(f"OUTP{ch}?")):
            raise RuntimeError(f"CH{ch} OFF not acknowledged")

    def _emergency_off(self):
        for ch in (1, 2):
            try:
                self._io(f"OUTP{ch} OFF", emergency=True)
            except BaseException:
                pass

    @serialized
    def configure(self, channel=1, **kwargs):
        ch = channel_number(channel)
        config = validate_settings(**kwargs)
        try:
            self.output_off(ch)
            # Avoid changing the other channel through frequency coupling.
            for other in (1, 2):
                self._write(f"SOUR{other}:FREQ:CONC OFF")
            p = f"SOUR{ch}:"
            if ch == 1:
                for mode in ("AM", "FM", "PM", "FSK", "BURS"):
                    self._write(p + mode + ":STAT OFF")
                self._write(p + "FREQ:MODE CW")
            self._write(f"OUTP{ch}:IMP " + ("INF" if config["load"] == "HIGHZ" else "50"))
            self._write(p + "VOLT:OFFS 0")
            self._write(p + "FUNC " + WAVES[config["waveform"]])
            self._write(p + f"VOLT {config['vpp']:.12g}VPP")
            self._write(p + f"VOLT:OFFS {config['offset_v']:.12g}")
            if config["waveform"] != "dc":
                self._write(p + f"FREQ {config['hz']:.12g}")
            self._write("*WAI")
            self._check_error()
            state = self.settings(ch)
            self._verify(config, state)
            return dict(state, requested=config)
        except BaseException as error:
            self._emergency_off()
            error.add_note("OFF sent to both channels; if communication failed, confirm OFF on panel")
            raise

    @staticmethod
    def _verify(config, state):
        if state["output"] or state["waveform"] != WAVES[config["waveform"]] or state["concurrent"]:
            raise RuntimeError("Unexpected output, waveform or coupling state")
        if state.get("mode", "CW") not in ("CW", "FIX") or any(state.get("modulation", {}).values()):
            raise RuntimeError("Continuous mode not acknowledged")
        for key, value in (("amplitude", config["vpp"]), ("offset_v", config["offset_v"])):
            if not math.isclose(state[key], value, rel_tol=1e-4, abs_tol=1e-4):
                raise RuntimeError(f"Readback mismatch: {key}")
        if config["waveform"] != "dc" and not math.isclose(state["hz"], config["hz"], rel_tol=1e-6, abs_tol=1e-6):
            raise RuntimeError("Frequency readback mismatch")
        if not (state["load_ohm"] > 1e6 if config["load"] == "HIGHZ" else state["load_ohm"] == 50):
            raise RuntimeError("Load readback mismatch")

    def configure_sine(self, point, channel=1):
        return self.configure(channel, waveform="sine", **point)

    @serialized
    def output_on(self, channel=1, **kwargs):
        # Fresh explicit configuration avoids trusting panel amplitude units or stale settings.
        self.configure(channel, **kwargs)
        try:
            self._write(f"OUTP{channel} ON")
            self._check_error()
            if not boolean(self.query(f"OUTP{channel}?")):
                raise RuntimeError("ON not acknowledged")
            return self.settings(channel)
        except BaseException:
            self._emergency_off()
            raise

    @serialized
    def upload_arb(self, samples):
        """Overwrite shared volatile EMEM only; full DAC-code readback required."""
        codes = sample_codes(samples)
        payload = struct.pack(f"<{len(codes)}H", *codes)
        count = str(len(payload)).encode("ascii")
        packet = b"DATA:DATA EMEMory,#" + str(len(count)).encode("ascii") + count + payload + b"\n"
        try:
            for ch in (1, 2):
                self.output_off(ch)
            if self.device.write_raw(packet) != len(packet):
                raise IOError("Short waveform write")
            self._write("*WAI")
            self._check_error()
            points = int(self.query("DATA:POIN? EMEMory"))
            observed = self.device.query_binary_values("DATA:DATA? EMEMory", datatype="H", is_big_endian=False,
                                                      expect_termination=False)
            if points != len(codes) or list(observed) != codes:
                raise RuntimeError("Waveform DAC-code readback mismatch")
            return dict(points=points, memory="EMEM", verification="all DAC codes matched", outputs="OFF")
        except BaseException:
            self.broken = True
            self._emergency_off()
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resource")
    parser.add_argument("--visa-library")
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("diagnose", "identify", "status", "configure", "output", "arb"):
        p = sub.add_parser(command)
        if command in ("status", "configure", "output", "arb"):
            p.add_argument("--channel", type=int, choices=(1, 2), default=1)
        if command == "output":
            p.add_argument("state", choices=("on", "off"))
        if command == "arb":
            p.add_argument("file")
        if command in ("configure", "output", "arb"):
            p.add_argument("--waveform", choices=WAVES, default="sine")
            p.add_argument("--hz", type=float, default=1000)
            p.add_argument("--vpp", type=float, default=0.1)
            p.add_argument("--offset-v", type=float, default=0)
            p.add_argument("--load", choices=("HIGHZ", "50"), default="HIGHZ")
            p.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    config = None
    samples = None
    if args.command in ("configure", "output", "arb"):
        config = validate_settings(waveform="arb" if args.command == "arb" else args.waveform,
                                   hz=args.hz, vpp=args.vpp, offset_v=args.offset_v, load=args.load)
        if args.command == "arb":
            samples = load_samples(args.file)
            sample_codes(samples)
        if args.dry_run:
            print(json.dumps(dict(command=args.command, config=config, points=len(samples) if samples is not None else None)))
            return 0
    if args.command == "diagnose":
        rm = resource_manager(args.visa_library)
        try:
            resources = [r for r in rm.list_resources("USB?*::INSTR") if is_afg_resource(r)]
            print(json.dumps(dict(resources=resources)))
            return 0 if resources else 1
        finally:
            rm.close()
    with AFG1022(args.resource, visa_library=args.visa_library) as device:
        if args.command == "identify":
            result = dict(identity=device.identify(), resource=device.resource)
        elif args.command == "status":
            result = device.settings(args.channel)
        elif args.command == "output":
            result = (device.output_on(args.channel, **config) if args.state == "on"
                      else device.output_off(args.channel))
        else:
            upload = device.upload_arb(samples) if samples is not None else None
            result = dict(settings=device.configure(args.channel, **config), upload=upload)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"AFG1022: {error}", file=sys.stderr)
        for note in getattr(error, "__notes__", ()):
            print(note, file=sys.stderr)
        sys.exit(1)
