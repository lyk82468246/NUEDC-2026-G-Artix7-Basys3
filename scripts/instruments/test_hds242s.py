"""Offline checks; no USB device, waveform output, or Vivado connection."""
import copy
import csv
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from hds242s import HDS242S, generator_setting_to_si, parse_ila_csv, validate_plan
import hds242s


class FakeUSB:
    def __init__(self, chunks):
        self.chunks = iter(chunks)

    def read(self, *args, **kwargs):
        try:
            return next(self.chunks)
        except StopIteration:
            raise TimeoutError("simulated incomplete USB transfer")


class TestHDS(unittest.TestCase):
    def receiver(self, chunks):
        instance = HDS242S.__new__(HDS242S)
        instance.device = FakeUSB(chunks)
        instance.timeout_ms = 300
        instance.pending = bytearray()
        instance.broken = False
        return instance

    def test_fragmented_binary_preserves_newline_in_payload(self):
        payload = bytes((10, 0, 255, 13)) * 170
        data = len(payload).to_bytes(4, "little") + payload
        instrument = self.receiver([data[:2], data[2:64], data[64:]])
        self.assertEqual(instrument._receive(True), payload)
        self.assertFalse(instrument.pending)

    def test_fragmented_text(self):
        instrument = self.receiver([b"OWON,HDS", b"242S\r\n"])
        self.assertEqual(instrument._receive(False), b"OWON,HDS242S")

    def test_bad_frame_poison_session(self):
        instrument = self.receiver([b"\xff\xff\xff\xff"])
        with self.assertRaises(ValueError):
            instrument._receive(True)
        self.assertTrue(instrument.broken)

    def test_timeout_poison_session(self):
        instrument = self.receiver([])
        with self.assertRaises(TimeoutError):
            instrument._receive(False)
        self.assertTrue(instrument.broken)

    def test_actual_firmware_units(self):
        identity = "OWON,HDS242S,serial,V8.1.0"
        self.assertEqual(generator_setting_to_si(identity, "FREQuency", "1e9"), 1000)
        self.assertEqual(generator_setting_to_si(identity, "FREQuency", "1e11"), 100000)
        self.assertEqual(generator_setting_to_si(identity, "AMPLitude", "1000"), 1)
        self.assertEqual(generator_setting_to_si(identity, "AMPLitude", "100"), .1)
        self.assertEqual(generator_setting_to_si(identity, "OFFSet", "0"), 0)
        with self.assertRaises(ValueError):
            generator_setting_to_si(identity, "OFFSet", "10")
        with self.assertRaises(ValueError):
            generator_setting_to_si(identity.replace("8.1.0", "9.9.9"), "AMPLitude", "1")

    def test_plan_limits(self):
        plan = json.loads(Path(__file__).with_name("sweep_example.json").read_text())
        validate_plan(plan)
        for key, invalid in (("hz", 1000000), ("vpp", .2), ("offset_v", .01),
                             ("hz", float("nan"))):
            changed = copy.deepcopy(plan)
            changed["points"][0][key] = invalid
            with self.assertRaises(ValueError):
                validate_plan(changed)

    def test_legacy_cli_rejects_service_only_plan_before_opening_usb(self):
        with tempfile.TemporaryDirectory() as directory:
            plan = json.loads(Path(__file__).with_name("sweep_fpga_only.json").read_text())
            plan["connections_confirmed"] = True
            path = Path(directory) / "plan.json"
            path.write_text(json.dumps(plan))
            with patch.object(hds242s, "HDS242S") as instrument, patch("sys.argv", [
                    "hds242s.py", "sweep", str(path), "--execute"]):
                with self.assertRaises(SystemExit):
                    hds242s.main()
                instrument.assert_not_called()

    def test_ila_radix_and_event(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ila.csv"
            with path.open("w", newline="", encoding="utf-8") as stream:
                writer = csv.writer(stream)
                writer.writerow(["Sample in Buffer", "measurement_valid", "vpp_out[15:0]",
                                 "vrms_out[15:0]", "amp_f1_out[30:0]", "max_index_out[11:0]"])
                writer.writerow(["Radix - UNSIGNED", "BIN", "HEX", "UNSIGNED", "HEX", "HEX"])
                writer.writerow([0, 0, "0", "0", "0", "0"])
                writer.writerow([1, 1, "100", "90", "abcd", "c8"])
            result = parse_ila_csv(path)
            self.assertEqual(result["frequency_hz"], 100000)
            self.assertEqual(result["vpp_out"], 256)
            self.assertEqual(result["amp_f1_out"], 43981)
            self.assertEqual(result["vrms_out"], 90)

    def test_sweep_readback_mismatch_never_enables_output(self):
        class Instrument:
            commands = []
            log = []
            broken = False
            identity = "OWON,HDS242S,serial,V8.1.0"
            def identify(self):
                return self.identity
            def generator_settings(self):
                return {"si": {"hz": 1000, "vpp": 1, "offset_v": 0}}
            def output_off(self):
                self.set(":CHANnel OFF")
            def set(self, command):
                self.commands.append(command)
            def query(self, command, framed=False):
                if "HEAD" in command:
                    return json.dumps({"CHANNEL": [{"NAME": "CH1", "DISPLAY": "ON"},
                                                     {"NAME": "CH2", "DISPLAY": "ON"}]}).encode()
                if command == ":CHANnel?":
                    return "OFF"
                return "0"  # Wrong frequency; must abort BEFORE output ON.
            def close(self):
                pass
            def emergency_off(self):
                self.set(":CHANnel OFF")
                return {"sent": True, "acknowledged": True}
        with tempfile.TemporaryDirectory() as directory:
            plan = json.loads(Path(__file__).with_name("sweep_example.json").read_text())
            plan["connections_confirmed"] = True
            path = Path(directory) / "plan.json"
            path.write_text(json.dumps(plan))
            output = Path(directory) / "result"
            with patch.object(hds242s, "HDS242S", Instrument), patch("sys.argv", [
                "hds242s.py", "--output", str(output), "sweep", str(path), "--execute"]):
                with self.assertRaisesRegex(RuntimeError, "readback mismatch"):
                    hds242s.main()
            self.assertNotIn(":CHANnel ON", Instrument.commands)
            self.assertEqual(Instrument.commands[-1], ":CHANnel OFF")
            result = json.loads((output / "session.json").read_text())
            self.assertEqual(result["status"], "failed")
            self.assertTrue(result["output_off_acknowledged"])


if __name__ == "__main__":
    unittest.main()
