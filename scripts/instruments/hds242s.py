"""HDS200 USB/SCPI transport and conservative automation CLI (Python 3.12).

Uses the installed OWON libusb-win32 driver. Never resets the USB device or
changes drivers. Read-only subcommands do not change generator/scope settings.
Screen waveforms are retained as original bytes, NOT labelled full-memory ADC
samples or precision voltage measurements; firmware byte formats need validation.
"""
from __future__ import annotations

import argparse
from collections import deque
import csv
from datetime import datetime
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
from functools import wraps

from resource_lock import ResourceLock


ROOT = Path(__file__).resolve().parents[2]


def serialized(method):
    @wraps(method)
    def wrapped(self, *args, **kwargs):
        with self._io_lock:
            return method(self, *args, **kwargs)
    return wrapped


def timestamp():
    return datetime.now().astimezone().isoformat(timespec="milliseconds")


def parse_number(text):
    """Only accept finite, bare SCPI numeric settings (Hz, Vpp, V)."""
    value = float(text.strip())
    if not math.isfinite(value):
        raise ValueError(f"Nonfinite device response: {text!r}")
    return value


def generator_setting_to_si(identity, name, raw):
    # HDS242S V8.1.0 setters accept Hz/V, but getters return uHz/mV.
    # Frequency and amplitude checked OUT=OFF on the real unit 2026-10-15.
    # Nonzero offset setter did not read back correctly; restrict to zero.
    if "HDS242S" not in identity or not identity.endswith(",V8.1.0"):
        raise ValueError("Unvalidated generator firmware units; identify and validate before sweeping")
    if name == "OFFSet":
        if parse_number(raw) != 0:
            raise ValueError("Nonzero DC offset units are unvalidated on V8.1.0")
        return 0.0
    divisors = {"FREQuency": 1e6, "AMPLitude": 1e3}
    return parse_number(raw) / divisors[name]


class HDS242S:
    def __init__(self, timeout_ms=3000):
        self._io_lock = threading.RLock()
        self._lease = ResourceLock(ROOT / ".lab_locks/hds242s.lock").acquire()
        self.device = None
        try:
            self._open(timeout_ms)
        except BaseException:
            self.close()
            raise

    def _open(self, timeout_ms):
        import usb.core
        import usb.util
        import usb.backend.libusb0

        self.usb = usb
        self.timeout_ms = timeout_ms
        self.log = deque(maxlen=2048)
        if os.name == "nt":
            dll = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32/libusb0.dll"
            backend = usb.backend.libusb0.get_backend(find_library=lambda _: str(dll))
            if backend is None:
                raise RuntimeError("Cannot load 64-bit libusb0.dll; use OWON driver and 64-bit Python.")
        else:
            backend = None
        devices = list(usb.core.find(find_all=True, idVendor=0x5345,
                                     idProduct=0x1234, backend=backend))
        if len(devices) != 1:
            raise RuntimeError(f"Expected one OWON USB device, found {len(devices)}. "
                               "Check power, cable, USB mode, permissions and competing PC software.")
        self.device = devices[0]
        self.pending = bytearray()
        self.broken = False
        usb.util.claim_interface(self.device, 0)

    @serialized
    def close(self):
        try:
            if self.device is not None:
                self.usb.util.dispose_resources(self.device)
                self.device = None
        finally:
            self._lease.release()

    def _send(self, command):
        if self.broken:
            raise RuntimeError("Session lost framing. Close/reconnect before another transaction.")
        if "\n" in command or "\r" in command or ";" in command:
            raise ValueError("One SCPI command per transaction required.")
        data = (command + "\n").encode("ascii")
        self.log.append({"time": timestamp(), "command": command})
        try:
            count = self.device.write(0x01, data, timeout=self.timeout_ms)
            if count != len(data):
                raise IOError("Short USB write")
        except BaseException:
            self.broken = True
            raise

    def _receive(self, framed):
        deadline = time.monotonic() + self.timeout_ms / 1000
        try:
            while True:
                if framed and len(self.pending) >= 4:
                    length = int.from_bytes(self.pending[:4], "little")
                    if not 0 < length <= 65536:
                        raise ValueError(f"Invalid waveform length prefix: {length}")
                    if len(self.pending) >= 4 + length:
                        result = bytes(self.pending[4:4 + length])
                        del self.pending[:4 + length]
                        return result
                elif not framed and b"\n" in self.pending:
                    end = self.pending.index(10)
                    result = bytes(self.pending[:end]).rstrip(b"\r")
                    del self.pending[:end + 1]
                    return result
                remaining = deadline - time.monotonic()
                if remaining <= 0 or len(self.pending) > 65540:
                    raise TimeoutError("Incomplete SCPI response")
                # Read large blocks, including the length prefix, rather than
                # issuing a tiny 4-byte USB read that can overflow a USB packet.
                self.pending.extend(self.device.read(0x81, 16384,
                                      timeout=max(1, int(remaining * 1000))))
        except Exception:
            self.broken = True
            raise

    @serialized
    def query(self, command, framed=False):
        if not command.endswith("?"):
            raise ValueError("Read-only query must end in ?")
        if self.pending:
            self.broken = True
            raise RuntimeError("Unexpected unconsumed bytes; refusing to mislabel next response.")
        self._send(command)
        result = self._receive(framed)
        self.log[-1]["response"] = result.hex() if framed else result.decode("ascii")
        return result if framed else result.decode("ascii").strip()

    @serialized
    def set(self, command):
        if "?" in command:
            raise ValueError("Use query for a query")
        self._send(command)
        # Do not delay between query write/read; only pace setting commands.
        time.sleep(0.05)

    def identify(self):
        identity = self.query("*IDN?")
        if "HDS242S" not in identity.upper():
            raise RuntimeError(f"Unexpected model: {identity}")
        self.identity = identity
        return identity

    @serialized
    def generator_settings(self):
        raw = {name: self.query(f":FUNCtion:{name}?")
               for name in ("FREQuency", "AMPLitude", "OFFSet")}
        return {"raw": raw, "si": {
            "hz": generator_setting_to_si(self.identity, "FREQuency", raw["FREQuency"]),
            "vpp": generator_setting_to_si(self.identity, "AMPLitude", raw["AMPLitude"]),
            "offset_v": generator_setting_to_si(self.identity, "OFFSet", raw["OFFSet"]),
        }}

    @serialized
    def output_off(self):
        self.set(":CHANnel OFF")
        if self.query(":CHANnel?").upper() not in ("OFF", "0"):
            raise RuntimeError("OUT did not acknowledge OFF")

    @serialized
    def emergency_off(self):
        """Best effort OFF; a poisoned stream stays poisoned, never re-synced by fiat."""
        was_broken = self.broken
        result = {"sent": False, "acknowledged": False}
        try:
            self.broken = False  # Permit exactly the emergency write.
            self._send(":CHANnel OFF")
            result["sent"] = True
            self.broken = was_broken
            if not was_broken:
                result["acknowledged"] = self.query(":CHANnel?").upper() in ("OFF", "0")
        except Exception as error:
            result["error"] = str(error)
            self.broken = True
        finally:
            self.broken = self.broken or was_broken
        return result

    @serialized
    def snapshot(self, channels):
        header_raw = self.query(":DATa:WAVe:SCReen:HEAD?", framed=True)
        header = json.loads(header_raw.decode("utf-8").rstrip("\x00\r\n"))
        result = {"time": timestamp(), "header": header, "channels": {}}
        for channel in channels:
            raw = self.query(f":DATa:WAVe:SCReen:CH{channel}?", framed=True)
            result["channels"][str(channel)] = {
                "byte_count": len(raw), "hex": raw.hex(),
                "measurements_raw": {
                    item: self.query(f":MEASurement:CH{channel}:{item}?")
                    for item in ("PKPK", "FREQuency", "AVERage")
                },
            }
        return result


def output_dir(argument):
    result = Path(argument) if argument else ROOT / "test_results" / datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    result.mkdir(parents=True, exist_ok=False)
    return result.resolve()


def save_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def validate_plan(plan):
    limits = plan["limits"]
    low, high = float(limits["min_output_v"]), float(limits["max_output_v"])
    max_vpp = float(limits["max_vpp"])
    if not all(math.isfinite(x) for x in (low, high, max_vpp)) or low >= high or max_vpp <= 0:
        raise ValueError("Invalid output limits")
    if not plan["points"]:
        raise ValueError("Empty sweep")
    for point in plan["points"]:
        frequency, amplitude, offset = (float(point[k]) for k in ("hz", "vpp", "offset_v"))
        if not all(math.isfinite(x) for x in (frequency, amplitude, offset)):
            raise ValueError("Nonfinite test point")
        if offset != 0:
            raise ValueError("Initial validated workflow supports zero DC offset only")
        if not 10000 <= frequency <= 500000:
            raise ValueError("This sweep is restricted to 10 kHz..500 kHz")
        if not 0.02 <= amplitude <= min(5.0, max_vpp):
            raise ValueError("Amplitude exceeds plan limits or generator high-Z range")
        if offset - amplitude / 2 < low or offset + amplitude / 2 > high:
            raise ValueError("Output extrema exceed plan limits")
    settle = float(plan.get("settle_s", 2))
    if not math.isfinite(settle) or not 1 <= settle <= 30:
        raise ValueError("settle_s must be 1..30 seconds")
    if plan.get("load", "OFF") != "OFF":
        raise ValueError("This initial workflow supports high-Z load setting OFF only")
    channels = plan.get("scope_channels", [])
    if not isinstance(channels, list) or any(type(x) is not int or x not in (1, 2) for x in channels) or len(channels) != len(set(channels)):
        raise ValueError("scope_channels must be a unique list of 1/2; [] disables scope capture")


def parse_ila_csv(path):
    """Extract the fresh measurement_valid event, respecting Vivado radix row."""
    with Path(path).open(encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.reader(stream))
    if len(rows) < 3:
        raise ValueError("Incomplete ILA CSV")
    names = ("measurement_valid", "vpp_out", "vrms_out", "amp_f1_out", "max_index_out")
    columns = {}
    for name in names:
        matches = [i for i, value in enumerate(rows[0])
                   if value.split(":")[0].split("/")[-1].split("[")[0] == name]
        if len(matches) != 1:
            raise ValueError(f"Missing or ambiguous CSV column: {name}")
        columns[name] = matches[0]
    radix_row = rows[1]
    if "radix" not in ",".join(radix_row).lower():
        raise ValueError("Missing CSV radix row; refusing to guess hex vs decimal")
    def value(row, name):
        index = columns[name]
        radix = radix_row[index].upper().strip()
        if "HEX" in radix:
            base = 16
        elif "BIN" in radix:
            base = 2
        elif any(token in radix for token in ("UNSIGNED", "SIGNED", "DEC")):
            base = 10
        else:
            raise ValueError(f"Unknown radix: {radix}")
        return int(row[index].strip(), base)
    for row in rows[2:]:
        if not row or len(row) <= max(columns.values()):
            continue
        if value(row, "measurement_valid") == 1:
            result = {name: value(row, name) for name in names[1:]}
            result["frequency_hz"] = result["max_index_out"] * 500
            return result
    raise ValueError("No measurement_valid=1 sample in ILA CSV")


def _terminate_process(process):
    if process.poll() is not None:
        return
    if os.name == "nt":
        # Exact child PID only; also closes Vivado's batch-wrapper descendants.
        subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    else:
        process.kill()
    process.wait(timeout=10)


def capture_ila(vivado, directory, probes, cancel=None, timeout_s=90):
    """One fresh result trigger; do not program FPGA or synthesize anything."""
    environment = os.environ.copy()
    vivado_root = Path(vivado).resolve().parents[1]
    environment["XILINX_VIVADO"] = str(vivado_root)
    environment["PATH"] = os.pathsep.join((str(vivado_root / "lib/win64.o"),
        str(vivado_root / "bin"), str(vivado_root / "bin/unwrapped/win64.o"),
        environment.get("PATH", "")))
    cancel = cancel or threading.Event()
    directory = Path(directory)
    if (directory / "ila.csv").exists():
        raise FileExistsError("Refusing to reuse an existing ILA capture")
    with ResourceLock(ROOT / ".lab_locks/fpga_ila.lock"), (directory / "vivado_capture.txt").open("wb") as log:
        process = subprocess.Popen([
            vivado, "-mode", "batch", "-nojournal", "-nolog", "-source",
            str(ROOT / "scripts/capture_hw_ila.tcl"), "-tclargs",
            str(directory / "ila.csv"), str(Path(probes).resolve()),
        ], cwd=directory, stdout=log, stderr=subprocess.STDOUT, env=environment)
        deadline = time.monotonic() + timeout_s
        try:
            while process.poll() is None:
                if cancel.wait(0.1):
                    raise InterruptedError("ILA capture cancelled")
                if time.monotonic() >= deadline:
                    raise TimeoutError("Vivado capture exceeded deadline")
        finally:
            _terminate_process(process)
    if process.returncode or not (directory / "ila.csv").is_file():
        raise RuntimeError(f"ILA capture failed: see {directory / 'vivado_capture.txt'}")
    result = parse_ila_csv(directory / "ila.csv")
    save_json(directory / "fpga.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", help="New results directory; existing paths are refused")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("identify", help="Only query model and generator settings")
    capture = sub.add_parser("capture", help="Read scope header, channel bytes and measurements")
    capture.add_argument("--channels", nargs="+", type=int, choices=(1, 2), default=[1, 2])
    ila = sub.add_parser("ila", help="Read one FPGA result without opening the oscilloscope")
    ila.add_argument("--vivado", required=True)
    ila.add_argument("--ltx", required=True)
    sweep = sub.add_parser("sweep", help="Validate plan; no hardware access unless --execute")
    sweep.add_argument("plan", type=Path)
    sweep.add_argument("--execute", action="store_true")
    sweep.add_argument("--vivado", help="Optional path to vivado.bat for result capture")
    sweep.add_argument("--ltx", help="Matching probe file for the programmed FPGA")
    args = parser.parse_args()
    if args.command == "ila":
        if not Path(args.vivado).is_file() or not Path(args.ltx).is_file():
            parser.error("Vivado executable or probe file missing")
        directory = output_dir(args.output)
        outcome = {"started": timestamp(), "status": "running", "command": "ila"}
        try:
            outcome["fpga"] = capture_ila(args.vivado, directory, args.ltx)
            outcome["status"] = "completed"
            print(json.dumps(outcome["fpga"], indent=2))
        except BaseException as error:
            outcome["status"] = "failed"
            outcome["error"] = str(error)
            raise
        finally:
            outcome["finished"] = timestamp()
            save_json(directory / "session.json", outcome)
            print(f"Results: {directory}")
        return
    plan = None
    if args.command == "sweep":
        plan = json.loads(args.plan.read_text(encoding="utf-8-sig"))
        validate_plan(plan)
        if not args.execute:
            print(json.dumps({"dry_run": True, "plan": plan}, ensure_ascii=False, indent=2))
            return
        if plan.get("connections_confirmed") is not True:
            parser.error("Set connections_confirmed=true after checking wiring and numeric limits")
        if plan.get("samples_per_point", 1) != 1:
            parser.error("Multi-sample plans require lab_server.py run_plan; this legacy CLI captures once per point")
        if plan.get("capture_fpga") is True and not args.vivado:
            parser.error("Plan requires FPGA capture; supply --vivado and --ltx or use the lab service")
        if not plan.get("scope_channels") and not args.vivado:
            parser.error("Select FPGA and/or scope capture before executing a sweep")
        if bool(args.vivado) != bool(args.ltx):
            parser.error("--vivado and --ltx must be supplied together")
        if args.vivado and (not Path(args.vivado).is_file() or not Path(args.ltx).is_file()):
            parser.error("Vivado executable or probe file missing")
    directory = output_dir(args.output)
    device = None
    sweep_active = False
    outcome = {"started": timestamp(), "status": "running", "command": args.command}
    try:
        device = HDS242S()
        outcome["identity"] = device.identify()
        print(outcome["identity"], flush=True)
        if args.command == "identify":
            outcome["generator_raw"] = {
                cmd: device.query(cmd) for cmd in (
                    ":FUNCtion?", ":FUNCtion:FREQuency?", ":FUNCtion:AMPLitude?",
                    ":FUNCtion:OFFSet?", ":FUNCtion:LOAD?", ":CHANnel?",
                )
            }
            outcome["generator_settings"] = device.generator_settings()
            print(json.dumps(outcome["generator_settings"], indent=2))
        elif args.command == "capture":
            save_json(directory / "scope.json", device.snapshot(args.channels))
        else:
            save_json(directory / "plan.json", plan)
            settings = device.generator_settings()  # Refuse unvalidated firmware.
            save_json(directory / "initial_generator.json", settings)
            if plan.get("scope_channels"):
                header = json.loads(device.query(":DATa:WAVe:SCReen:HEAD?", framed=True))
                channels = {str(ch["NAME"]).upper(): ch for ch in header["CHANNEL"]}
                for channel in plan["scope_channels"]:
                    if channels[f"CH{channel}"]["DISPLAY"].upper() != "ON":
                        raise RuntimeError(f"CH{channel} is OFF; enable and configure scope channels first")
            # Startup always disables output before changing waveform or levels.
            sweep_active = True
            device.output_off()
            device.set(":FUNCtion SINE")
            device.set(":FUNCtion:LOAD OFF")
            device.set(":FUNCtion:OFFSet 0")
            with (directory / "index.csv").open("w", newline="", encoding="utf-8-sig") as stream:
                writer = csv.DictWriter(stream, fieldnames=("point", "hz", "vpp", "offset_v", "time", "scope", "ila", "fpga_hz", "frequency_error_hz", "vpp_raw", "vrms_raw", "amp_raw"))
                writer.writeheader()
                for index, point in enumerate(plan["points"]):
                    point_dir = directory / f"point_{index:03d}"
                    point_dir.mkdir()
                    device.output_off()
                    for name, key in (("FREQuency", "hz"), ("AMPLitude", "vpp"), ("OFFSet", "offset_v")):
                        device.set(f":FUNCtion:{name} {float(point[key]):.12g}")
                    for name, key in (("FREQuency", "hz"), ("AMPLitude", "vpp"), ("OFFSet", "offset_v")):
                        observed = generator_setting_to_si(device.identity, name, device.query(f":FUNCtion:{name}?"))
                        if not math.isclose(observed, float(point[key]), rel_tol=1e-4, abs_tol=1e-6):
                            raise RuntimeError(f"Generator readback mismatch: {name}={observed}")
                    if device.query(":FUNCtion?").upper() != "SINE":
                        raise RuntimeError("Generator is not in sine mode")
                    if device.query(":FUNCtion:LOAD?").upper() not in ("OFF", "0"):
                        raise RuntimeError("Generator load readback is not high-Z/OFF")
                    device.set(":CHANnel ON")
                    if device.query(":CHANnel?").upper() not in ("ON", "1"):
                        raise RuntimeError("OUT did not acknowledge ON")
                    time.sleep(float(plan.get("settle_s", 2)))
                    if plan.get("scope_channels"):
                        save_json(point_dir / "scope.json", device.snapshot(plan["scope_channels"]))
                    fpga = capture_ila(args.vivado, point_dir, args.ltx) if args.vivado else None
                    writer.writerow({"point": index, **point, "time": timestamp(),
                                     "scope": f"point_{index:03d}/scope.json" if plan.get("scope_channels") else "",
                                     "ila": f"point_{index:03d}/ila.csv" if args.vivado else "",
                                     "fpga_hz": fpga["frequency_hz"] if fpga else "",
                                     "frequency_error_hz": fpga["frequency_hz"] - point["hz"] if fpga else "",
                                     "vpp_raw": fpga["vpp_out"] if fpga else "",
                                     "vrms_raw": fpga["vrms_out"] if fpga else "",
                                     "amp_raw": fpga["amp_f1_out"] if fpga else ""})
                    stream.flush()
                    print(f"Point {index}: {point}", flush=True)
            outcome["fpga_capture"] = bool(args.vivado)
        outcome["status"] = "completed"
    except BaseException as error:
        outcome["status"] = "failed"
        outcome["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        if device:
            if sweep_active:
                try:
                    off = device.emergency_off()
                    outcome["output_off_sent"] = off["sent"]
                    outcome["output_off_acknowledged"] = off["acknowledged"]
                    if not outcome["output_off_acknowledged"]:
                        raise RuntimeError("OUT OFF not acknowledged")
                except Exception as error:
                    outcome["status"] = "failed"
                    outcome.setdefault("output_off_sent", False)
                    outcome["output_off_error"] = str(error)
                    print("OUTPUT OFF FAILED: disable OUT on instrument manually", file=sys.stderr)
            try:
                save_json(directory / "scpi_log.json", list(device.log))
            finally:
                device.close()
        outcome["finished"] = timestamp()
        save_json(directory / "session.json", outcome)
        print(f"Results: {directory}", flush=True)
    if outcome["status"] != "completed":
        raise RuntimeError("Run did not finish safely; inspect session.json")


if __name__ == "__main__":
    main()
