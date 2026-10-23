"""UNI-T UTG932(E)/UTG900 USBTMC control using the vendor's VISA SCPI manual.

No reset or driver changes. identify/status are read-only. configure leaves the
selected channel OFF; output ON is explicit and rechecks the complete settings.
The transport is separate from the OWON HDS242S libusb driver.
"""
from __future__ import annotations

import argparse
from collections import deque
from datetime import datetime
from functools import wraps
import hashlib
import json
from importlib.metadata import PackageNotFoundError, version
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time

from resource_lock import ResourceLock
from utg932_waveform import encode_bsv, load_samples, sample_summary, synthesize_multitone, validate_samples

ROOT = Path(__file__).resolve().parents[2]
MANUAL = "https://events.uni-trend.com/hubfs/Instrument%20Product%20documentation/Waveform%20Generators/UTG900E/UTG900E%20Programming%20Manual%20V1.0.pdf"
WAVES = {"sine": "SINE", "square": "SQUARE", "pulse": "PULSE", "ramp": "RAMP", "dc": "DC", "arb": "ARB"}
# Conservative automation envelope, not the instrument's full specifications.
MAX_HZ = {"sine": 30e6, "square": 1e6, "pulse": 1e6, "ramp": 100e3, "dc": 30e6, "arb": 1e6}


def serialized(method):
    @wraps(method)
    def wrapped(self, *args, **kwargs):
        with self._io_lock:
            return method(self, *args, **kwargs)
    return wrapped


def number(value):
    """Parse SI/scientific notation; tolerate panel digit grouping, never units."""
    if isinstance(value, bool):
        raise ValueError("Boolean is not a numeric setting")
    result = float(str(value).strip().replace(",", "").replace(" ", ""))
    if not math.isfinite(result):
        raise ValueError(f"Expected finite number: {value!r}")
    return result


def channel_number(channel):
    if type(channel) is not int or channel not in (1, 2):
        raise ValueError("channel must be 1 or 2")
    return channel


def boolean(raw):
    value = raw.strip().upper()
    if value not in ("ON", "OFF", "0", "1"):
        raise ValueError(f"Invalid output state: {raw!r}")
    return value in ("ON", "1")


def validate_settings(*, waveform="sine", hz=100e3, vpp=0.1, offset_v=0,
                      phase_deg=0, load="HIGHZ", duty=50, symmetry=50, arb_slot=None):
    waveform = waveform.lower()
    load = str(load).upper()
    if waveform not in WAVES or load not in ("HIGHZ", "50"):
        raise ValueError("Unsupported waveform or load (HIGHZ/50)")
    values = dict(hz=number(hz), vpp=number(vpp), offset_v=number(offset_v),
                  phase_deg=number(phase_deg), duty=number(duty), symmetry=number(symmetry))
    if not 1e-6 <= values["hz"] <= MAX_HZ[waveform]:
        raise ValueError(f"{waveform} automation frequency: 1 uHz..{MAX_HZ[waveform]:g} Hz")
    if not 0.002 <= values["vpp"] <= 5:
        raise ValueError("Automation amplitude: 0.002..5 Vpp")
    # Bound open-circuit voltage even when the selected load is 50 ohms.
    factor = 2 if load == "50" else 1
    peak = 0 if waveform == "dc" else values["vpp"] / 2
    if factor * (abs(values["offset_v"]) + peak) > 5:
        raise ValueError("Open-circuit extrema exceed the automation +/-5 V envelope")
    if not -360 <= values["phase_deg"] <= 360:
        raise ValueError("Phase must be -360..360 degrees")
    if not 1 <= values["duty"] <= 99 or not 1 <= values["symmetry"] <= 99:
        raise ValueError("Duty/symmetry must be 1..99 percent")
    if waveform == "arb" and (type(arb_slot) is not int or arb_slot not in (0, 1)):
        raise ValueError("ARB requires arb_slot=0 or 1 (external user waveform)")
    if waveform != "arb" and arb_slot is not None:
        raise ValueError("arb_slot is only valid for ARB")
    return dict(waveform=waveform, load=load, arb_slot=arb_slot, **values)


def is_utg_resource(resource):
    parts = resource.upper().split("::")
    try:
        return (parts[0].startswith("USB") and parts[-1] == "INSTR"
                and int(parts[1], 0 if parts[1].startswith("0X") else 10) == 0x6656
                and int(parts[2], 0 if parts[2].startswith("0X") else 10) == 0x0834)
    except (ValueError, IndexError):
        return False


def resource_manager(library=None):
    try:
        import pyvisa
    except ImportError as error:
        raise RuntimeError("Install Python dependency: .venv-hds/Scripts/python.exe -m pip install -r scripts/instruments/requirements-utg932.txt") from error
    try:
        return pyvisa.ResourceManager(library) if library else pyvisa.ResourceManager()
    except Exception as error:
        raise RuntimeError(f"VISA runtime cannot open: {error}. If NI-VISA is installed, retry outside the restricted process; check VISA DLL dependencies/permissions before reinstalling.") from error


class UTG932:
    def __init__(self, resource=None, *, timeout_ms=3000, visa_library=None):
        self._io_lock = threading.RLock()
        self._lease = ResourceLock(ROOT / ".lab_locks/utg932.lock").acquire()
        self.device = self.rm = None
        self.broken = False
        self.log = deque(maxlen=4096)
        try:
            self.rm = resource_manager(visa_library)
            resources = [r for r in self.rm.list_resources("USB?*::INSTR") if is_utg_resource(r)]
            if resource is None:
                if len(resources) != 1:
                    raise RuntimeError(f"Expected one UTG900 USBTMC device, found {len(resources)}. Run diagnose; use --resource with multiple units.")
                resource = resources[0]
            if not is_utg_resource(resource):
                raise ValueError("Resource must be UTG900 USB 6656:0834, not an OWON or other instrument")
            self.resource = resource
            self.device = self.rm.open_resource(resource, open_timeout=timeout_ms)
            self.device.timeout = timeout_ms
            # UTG900 V1.09 ends replies with USBTMC EOM, without LF.
            # A VISA LF read terminator waits for bytes that never arrive.
            self.device.read_termination = None
            self.device.write_termination = "\n"
            self.identify()
        except BaseException:
            self.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    @serialized
    def close(self):
        # Closing a read-only session must not change either output.
        try:
            try:
                if self.device is not None:
                    device, self.device = self.device, None
                    device.close()
            finally:
                if self.rm is not None:
                    rm, self.rm = self.rm, None
                    rm.close()
        finally:
            self._lease.release()

    def _transaction(self, command, query=False, emergency=False, binary=False):
        if not command or any(c in command for c in ("\n", "\r", ";", "\x00")):
            raise ValueError("One SCPI command per transaction")
        command.encode("ascii")
        if query != command.endswith("?") or command.count("?") != int(query):
            raise ValueError("Invalid SCPI query/write")
        if self.broken and not emergency:
            raise RuntimeError("Failed session; reconnect before another transaction")
        entry = {"time": datetime.now().astimezone().isoformat(), "command": command}
        self.log.append(entry)
        try:
            if query:
                if binary:
                    response = self.device.query_binary_values(command, datatype="B", container=bytes,
                                                               expect_termination=False)
                    entry.update(bytes=len(response), sha256=hashlib.sha256(response).hexdigest())
                    return response
                response = self.device.query(command).strip()
                entry["response"] = response
                return response
            expected = len(command.encode("ascii")) + 1  # LF added by VISA
            if self.device.write(command) != expected:
                raise IOError("Short VISA write")
            time.sleep(0.05)
        except BaseException as error:
            entry["error"] = str(error)
            self.broken = True
            raise

    @serialized
    def query(self, command, *, binary=False):
        return self._transaction(command, query=True, binary=binary)

    def screen(self):
        """Read the instrument's original BMP; does not alter output or UI locks."""
        data = self.query(":DISPlay?", binary=True)
        if not data.startswith(b"BM"):
            raise ValueError("Display reply is not a BMP; preserve SCPI log and inspect firmware")
        return data

    def _write(self, command):
        self._transaction(command)

    def identify(self):
        identity = self.query("*IDN?")
        fields = [part.strip().upper() for part in identity.split(",")]
        if (len(fields) < 4 or not re.search(r"UNI[ -]?T", fields[0])
                or fields[1] not in ("UTG900", "UTG932", "UTG932E")):
            raise RuntimeError(f"Unexpected UTG932 identity: {identity!r}")
        self.identity = identity
        return identity

    @serialized
    def settings(self, channel=1):
        channel_number(channel)
        prefix = f":CHANnel{channel}"
        commands = {"output": ":OUTPut", "mode": ":MODe", "unit": ":AMPLitude:UNIT",
                    "load_ohm": ":LOAD", "waveform": ":BASE:WAVe", "hz": ":BASE:FREQuency",
                    "vpp": ":BASE:AMPLitude", "offset_v": ":BASE:OFFSet", "phase_deg": ":BASE:PHAse"}
        raw = {key: self.query(prefix + suffix + "?") for key, suffix in commands.items()}
        result = {key: number(raw[key]) for key in ("load_ohm", "hz", "offset_v", "phase_deg")}
        unit = raw["unit"].upper()
        result.update(channel=channel, output=boolean(raw["output"]), mode=raw["mode"].upper(),
                      waveform=raw["waveform"].upper(), unit=unit, raw=raw)
        # Do not mislabel VRMS/dBm as Vpp in a read-only session.
        result["amplitude"] = number(raw["vpp"])
        result["vpp"] = result["amplitude"] if unit == "VPP" else None
        if result["waveform"] in ("SQUARE", "PULSE"):
            result["duty"] = number(self.query(prefix + ":BASE:DUTY?"))
        elif result["waveform"] == "RAMP":
            result["symmetry"] = number(self.query(prefix + ":RAMP:SYMMetry?"))
        elif result["waveform"] == "ARB":
            result["arb_source"] = self.query(prefix + ":ARB:SOURce?").upper()
            result["arb_slot"] = number(self.query(prefix + ":ARB:INDex?"))
        return result

    @serialized
    def output_off(self, channel=1):
        prefix = f":CHANnel{channel_number(channel)}:OUTPut"
        self._write(prefix + " OFF")
        deadline = time.monotonic() + 0.5
        while boolean(self.query(prefix + "?")):
            if time.monotonic() >= deadline:
                raise RuntimeError(f"CH{channel} did not acknowledge OFF")
            time.sleep(0.05)

    @serialized
    def emergency_off(self, channel=1):
        """On a failed stream send OFF only; never trust a stale query response."""
        prefix = f":CHANnel{channel_number(channel)}:OUTPut"
        result = {"sent": False, "acknowledged": False}
        try:
            was_broken = self.broken
            self._transaction(prefix + " OFF", emergency=True)
            result["sent"] = True
            if not was_broken:
                deadline = time.monotonic() + 0.5
                while True:
                    if not boolean(self.query(prefix + "?")):
                        result["acknowledged"] = True
                        break
                    if time.monotonic() >= deadline:
                        break
                    time.sleep(0.05)
        except Exception as error:
            result["error"] = str(error)
        return result

    @serialized
    def configure(self, channel=1, **kwargs):
        channel_number(channel)
        config = validate_settings(**kwargs)  # Validate before changing hardware.
        prefix = f":CHANnel{channel}"
        try:
            self.output_off(channel)
            pairs = [(":MODe", "CONTINUE"), (":AMPLitude:UNIT", "VPP"),
                     (":LOAD", "10000" if config["load"] == "HIGHZ" else "50"),
                     (":BASE:WAVe", WAVES[config["waveform"]]),
                     (":BASE:AMPLitude", config["vpp"]), (":BASE:OFFSet", config["offset_v"]),
                     (":BASE:FREQuency", config["hz"]), (":BASE:PHAse", config["phase_deg"])]
            if config["waveform"] == "arb":
                pairs[4:4] = [(":ARB:SOURce", "EXTERNAL"), (":ARB:INDex", config["arb_slot"])]
            elif config["waveform"] == "dc":
                # V1.09 can report 1 uHz after a frequency write in DC mode;
                # frequency/phase are not physical DC settings. Skip both.
                pairs = [(suffix, value) for suffix, value in pairs
                         if suffix not in (":BASE:FREQuency", ":BASE:PHAse")]
            if config["waveform"] in ("square", "pulse"):
                pairs.append((":BASE:DUTY", config["duty"]))
            elif config["waveform"] == "ramp":
                pairs.append((":RAMP:SYMMetry", config["symmetry"]))
            for suffix, value in pairs:
                self._write(f"{prefix}{suffix} {value:.12g}" if isinstance(value, float) else f"{prefix}{suffix} {value}")
                if boolean(self.query(prefix + ":OUTPut?")):
                    raise RuntimeError("Unexpected output ON during configuration")
            observed = self.settings(channel)
            self._verify(config, observed)
            return observed
        except BaseException as error:
            shutdown = self.emergency_off(channel)
            if not shutdown["acknowledged"]:
                error.add_note(f"CH{channel} OFF unconfirmed; disable on panel. {shutdown}")
            raise

    def configure_sine(self, point, channel=1):
        """Convenient adapter for existing {hz, vpp, offset_v} sweep points."""
        return self.configure(channel, waveform="sine", **point)

    def configure_arb(self, channel=1, *, slot=0, hz=1000, vpp=0.1, offset_v=0,
                      phase_deg=0, load="HIGHZ"):
        """Select a user table; hz is the repetition frequency of the whole table."""
        return self.configure(channel, waveform="arb", arb_slot=slot, hz=hz, vpp=vpp,
                              offset_v=offset_v, phase_deg=phase_deg, load=load)

    @serialized
    def upload_arb(self, samples, *, slot=0, name="Custom"):
        """Replace user slot 0/1. Upload can affect both channels: force both OFF.

        UTG900 WARB uses BSV bytes directly, not an IEEE # binary block. A full
        transport write is not a waveform checksum/readback from the device.
        """
        if type(slot) is not int or slot not in (0, 1):
            raise ValueError("slot must be 0 or 1")
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,15}", name):
            raise ValueError("Waveform name: 1..16 ASCII letters/digits/underscore, leading letter")
        samples = validate_samples(samples)
        payload = encode_bsv(samples)  # Validate everything before device writes.
        before = {ch: self.settings(ch) for ch in (1, 2)}
        try:
            for ch in (1, 2):
                self.output_off(ch)
            self._write(f":WARB{slot + 1}:CARRier {name}")
            entry = {"time": datetime.now().astimezone().isoformat(), "binary_upload": True,
                     "slot": slot, "name": name, "bytes": len(payload),
                     "sha256": hashlib.sha256(payload).hexdigest()}
            self.log.append(entry)
            try:
                count = self.device.write_raw(payload)
                if count != len(payload):
                    raise IOError(f"Short waveform upload: {count}/{len(payload)}")
                time.sleep(0.5)
            except BaseException as error:
                self.broken = True
                entry["error"] = str(error)
                raise
            # Firmware can switch both channels into ARB during upload.
            # Restore their previous wave selection while keeping both OFF.
            for ch, state in before.items():
                self.output_off(ch)
                self._write(f":CHANnel{ch}:BASE:WAVe {state['waveform']}")
                if state["waveform"] == "ARB":
                    self._write(f":CHANnel{ch}:ARB:SOURce {state['arb_source']}")
                    self._write(f":CHANnel{ch}:ARB:INDex {int(state['arb_slot'])}")
                self.output_off(ch)
            after = {ch: self.settings(ch) for ch in (1, 2)}
            for ch in (1, 2):
                for key in ("waveform", "mode", "unit", "load_ohm", "hz", "amplitude", "offset_v", "phase_deg", "duty", "symmetry", "arb_source", "arb_slot"):
                    old, new = before[ch].get(key), after[ch].get(key)
                    equal = math.isclose(old, new, rel_tol=1e-4, abs_tol=1e-6) if isinstance(old, (int, float)) and isinstance(new, (int, float)) else old == new
                    if not equal:
                        raise RuntimeError(f"CH{ch} changed during upload: {key}: {old} -> {new}; both outputs left OFF")
            return dict(slot=slot, name=name, **sample_summary(samples), channels=after,
                        verification="USB write complete; device table checksum unavailable")
        except BaseException as error:
            shutdown = {ch: self.emergency_off(ch) for ch in (1, 2)}
            if not all(result["acknowledged"] for result in shutdown.values()):
                error.add_note(f"Both outputs must be OFF; panel confirmation needed: {shutdown}")
            raise

    @staticmethod
    def _verify(config, observed):
        expected = dict(hz=config["hz"], vpp=config["vpp"], offset_v=config["offset_v"],
                        phase_deg=config["phase_deg"], load_ohm=10000 if config["load"] == "HIGHZ" else 50)
        if config["waveform"] == "dc":
            del expected["hz"], expected["phase_deg"]
        if config["waveform"] in ("square", "pulse"):
            expected["duty"] = config["duty"]
        elif config["waveform"] == "ramp":
            expected["symmetry"] = config["symmetry"]
        elif config["waveform"] == "arb":
            expected["arb_slot"] = config["arb_slot"]
            if observed.get("arb_source", "").upper() not in ("EXT", "EXTERNAL"):
                raise RuntimeError("External/user ARB source not acknowledged")
        for key, value in expected.items():
            if observed[key] is None or not math.isclose(value, observed[key], rel_tol=1e-4, abs_tol=1e-6):
                raise RuntimeError(f"Readback mismatch: {key}: requested {value}, got {observed[key]}")
        if (observed["waveform"] != WAVES[config["waveform"]] or observed["unit"] != "VPP"
                or observed["mode"] != "CONTINUE" or observed["output"]):
            raise RuntimeError(f"Unexpected waveform/mode/unit/output: {observed}")

    @serialized
    def output_on(self, channel=1):
        """Enable current settings only after validating the readback envelope."""
        channel_number(channel)
        try:
            observed = self.settings(channel)
            load = observed["load_ohm"]
            if observed["unit"] != "VPP" or load not in (50, 10000) or observed["mode"] != "CONTINUE":
                raise ValueError("Configure VPP, HIGHZ/50 and CONTINUE before output ON")
            if observed["waveform"] == "ARB" and (observed.get("arb_slot") not in (0, 1)
                    or observed.get("arb_source") not in ("EXT", "EXTERNAL")):
                raise ValueError("Select an external/user ARB slot 0/1 before output ON")
            validate_settings(waveform=observed["waveform"].lower(), hz=observed["hz"],
                              vpp=observed["vpp"], offset_v=observed["offset_v"],
                              phase_deg=observed["phase_deg"], load="50" if load == 50 else "HIGHZ",
                              duty=observed.get("duty", 50), symmetry=observed.get("symmetry", 50),
                              arb_slot=int(observed["arb_slot"]) if observed["waveform"] == "ARB" else None)
            self._write(f":CHANnel{channel}:OUTPut ON")
            if not boolean(self.query(f":CHANnel{channel}:OUTPut?")):
                raise RuntimeError("Output ON not acknowledged")
        except BaseException as error:
            shutdown = self.emergency_off(channel)
            if not shutdown["acknowledged"]:
                error.add_note(f"CH{channel} OFF unconfirmed; disable on panel. {shutdown}")
            raise


def diagnose(visa_library=None):
    result = {"manual": MANUAL, "expected_usb": "6656:0834", "visa_resources": [],
              "python_executable": sys.executable}
    try:
        result["pyvisa_version"] = version("PyVISA")
    except PackageNotFoundError:
        result["pyvisa_version"] = None
    if os.name == "nt":
        # PnPUtil works without WMI/CIM and reports only this connected device.
        proc = subprocess.run(["pnputil", "/enum-devices", "/connected", "/deviceid",
                               r"USB\VID_6656&PID_0834"], capture_output=True, timeout=20)
        import locale
        result["windows_pnp"] = proc.stdout.decode(locale.getencoding(), errors="replace")
        result["windows_pnp_exit_code"] = proc.returncode
    try:
        rm = resource_manager(visa_library)
        try:
            result["visa_resources"] = [r for r in rm.list_resources("USB?*::INSTR") if is_utg_resource(r)]
        finally:
            rm.close()
        result["visa_available"] = True
    except Exception as error:
        result.update(visa_available=False, error=str(error))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resource", help="Exact USB VISA resource; autodetected by default")
    parser.add_argument("--visa-library", help="Optional VISA library path")
    parser.add_argument("--timeout-ms", type=int, default=3000)
    parser.add_argument("--log", type=Path, help="Save session/SCPI JSON (new file only)")
    subs = parser.add_subparsers(dest="command", required=True)
    subs.add_parser("diagnose", help="Read Windows driver and VISA discovery status")
    subs.add_parser("identify", help="Read instrument identity")
    status = subs.add_parser("status", help="Read both channels (or --channel)")
    status.add_argument("--channel", type=int, choices=(1, 2))
    config = subs.add_parser("configure", help="Configure a channel and leave it OFF")
    config.add_argument("--channel", type=int, choices=(1, 2), default=1)
    config.add_argument("--waveform", choices=WAVES, default="sine")
    for name, default in (("hz", 100e3), ("vpp", 0.1), ("offset-v", 0), ("phase-deg", 0), ("duty", 50), ("symmetry", 50)):
        config.add_argument("--" + name, type=float, default=default)
    config.add_argument("--load", choices=("HIGHZ", "50"), default="HIGHZ")
    config.add_argument("--slot", dest="arb_slot", type=int, choices=(0, 1), help="Required for --waveform arb")
    config.add_argument("--dry-run", action="store_true", help="Validate settings without hardware")
    upload = subs.add_parser("upload", help="Upload normalized JSON/CSV/TXT/BSV; forces both channels OFF")
    upload.add_argument("file", type=Path)
    upload.add_argument("--slot", type=int, choices=(0, 1), default=0)
    upload.add_argument("--name", default="Custom")
    upload.add_argument("--dry-run", action="store_true")
    arb = subs.add_parser("arb", help="Upload and configure user waveform; leaves both outputs OFF")
    arb.add_argument("file", type=Path)
    arb.add_argument("--channel", type=int, choices=(1, 2), default=1)
    arb.add_argument("--slot", type=int, choices=(0, 1), default=0)
    arb.add_argument("--name", default="Custom")
    arb.add_argument("--hz", type=float, help="Table repetition Hz; defaults to JSON repeat_hz")
    arb.add_argument("--vpp", type=float, help="Full-scale Vpp; defaults to JSON vpp")
    arb.add_argument("--offset-v", type=float, help="DC offset; defaults to JSON offset_v or 0")
    arb.add_argument("--load", choices=("HIGHZ", "50"), default="HIGHZ")
    arb.add_argument("--dry-run", action="store_true")
    multitone = subs.add_parser("multitone", help="Build coherent multi-tone normalized JSON without hardware")
    multitone.add_argument("plan", type=Path)
    multitone.add_argument("--save", type=Path, required=True, help="New JSON file")
    encode = subs.add_parser("encode", help="Convert normalized JSON/CSV/TXT to BSV without hardware")
    encode.add_argument("file", type=Path)
    encode.add_argument("--save", type=Path, required=True, help="New BSV file")
    screen = subs.add_parser("screen", help="Read original instrument BMP (new file only)")
    screen.add_argument("--save", type=Path, required=True)
    output = subs.add_parser("output", help="Explicit output control; ON persists after process exit")
    output.add_argument("state", choices=("on", "off"))
    output.add_argument("--channel", choices=("1", "2", "all"), default="1")
    args = parser.parse_args(argv)
    if not 100 <= args.timeout_ms <= 30000:
        parser.error("--timeout-ms must be 100..30000")
    if args.command == "output" and args.state == "on" and args.channel == "all":
        parser.error("Enable one channel at a time")
    settings = None
    if args.command == "configure":
        settings = validate_settings(**{k: getattr(args, k) for k in ("waveform", "hz", "vpp", "offset_v", "phase_deg", "load", "duty", "symmetry", "arb_slot")})
        if args.dry_run:
            print(json.dumps({"dry_run": True, "channel": args.channel, "settings": settings, "output": False}, indent=2))
            return 0
    samples = None
    if args.command == "multitone":
        result = synthesize_multitone(json.loads(args.plan.read_text(encoding="utf-8-sig")))
        with args.save.open("x", encoding="utf-8") as stream:
            json.dump(result, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        print(json.dumps({k: v for k, v in result.items() if k != "samples"}, ensure_ascii=False, indent=2))
        return 0
    if args.command in ("upload", "encode", "arb"):
        samples = load_samples(args.file)
        if args.command == "encode":
            with args.save.open("xb") as stream:
                stream.write(encode_bsv(samples))
            print(json.dumps(sample_summary(samples), indent=2))
            return 0
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,15}", args.name):
            raise ValueError("Waveform name: 1..16 ASCII letters/digits/underscore, leading letter")
        if args.command == "arb":
            metadata = json.loads(args.file.read_text(encoding="utf-8-sig")) if args.file.suffix.lower() == ".json" else {}
            if not isinstance(metadata, dict):
                metadata = {}
            hz = args.hz if args.hz is not None else metadata.get("repeat_hz")
            vpp = args.vpp if args.vpp is not None else metadata.get("vpp")
            if hz is None or vpp is None:
                raise ValueError("Specify --hz (table repetition) and --vpp, or use generated JSON metadata")
            offset = args.offset_v if args.offset_v is not None else metadata.get("offset_v", 0)
            settings = validate_settings(waveform="arb", arb_slot=args.slot, hz=hz, vpp=vpp,
                                         offset_v=offset, load=args.load)
        if args.dry_run:
            print(json.dumps(dict(dry_run=True, slot=args.slot, name=args.name, settings=settings,
                                  **sample_summary(samples)), indent=2))
            return 0
    if args.command == "diagnose":
        result = diagnose(args.visa_library)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if result.get("visa_resources") else 1
    device = None
    report = {"started": datetime.now().astimezone().isoformat(), "command": args.command}
    # Reserve log file before any hardware mutation; never overwrite evidence.
    log_stream = args.log.open("x", encoding="utf-8") if args.log else None
    try:
        device = UTG932(args.resource, timeout_ms=args.timeout_ms, visa_library=args.visa_library)
        report.update(identity=device.identity, resource=device.resource)
        if args.command == "identify":
            result = {"identity": device.identity, "resource": device.resource}
        elif args.command == "status":
            result = {str(ch): device.settings(ch) for ch in ([args.channel] if args.channel else (1, 2))}
        elif args.command == "configure":
            result = device.configure(args.channel, **settings)
        elif args.command == "upload":
            result = device.upload_arb(samples, slot=args.slot, name=args.name)
        elif args.command == "arb":
            upload_result = device.upload_arb(samples, slot=args.slot, name=args.name)
            result = {"upload": upload_result, "configured": device.configure(args.channel, **settings)}
        elif args.command == "screen":
            with args.save.open("xb") as stream:
                data = device.screen()
                stream.write(data)
            result = {"file": str(args.save.resolve()), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        else:
            result = {}
            for ch in ((1, 2) if args.channel == "all" else (int(args.channel),)):
                if args.state == "on":
                    device.output_on(ch)
                    result[str(ch)] = {"output": True}
                else:
                    # Try both OFF writes even if the first channel poisons IO.
                    result[str(ch)] = device.emergency_off(ch)
            if args.state == "off" and not all(v["acknowledged"] for v in result.values()):
                raise RuntimeError(f"OUTPUT OFF unconfirmed; disable on panel: {result}")
        report.update(status="completed", result=result)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except BaseException as error:
        report.update(status="failed", error=str(error), notes=getattr(error, "__notes__", []))
        raise
    finally:
        try:
            if device:
                report["scpi_log"] = list(device.log)
                device.close()
        finally:
            if log_stream:
                report["finished"] = datetime.now().astimezone().isoformat()
                with log_stream:
                    json.dump(report, log_stream, ensure_ascii=False, indent=2)
                    log_stream.write("\n")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Exception, KeyboardInterrupt) as error:
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        for note in getattr(error, "__notes__", []):
            print(note, file=sys.stderr)
        sys.exit(1)
