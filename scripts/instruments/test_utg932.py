"""Offline UTG control tests: no hardware, VISA runtime, or waveform output."""
import copy
import json
import math
import struct
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

import utg932
from utg932_waveform import encode_bsv, decode_bsv, load_samples, synthesize_multitone
from resource_lock import ResourceLock, ResourceBusy


class FakeVISA:
    def __init__(self):
        self.closed = False
        self.calls = []
        self.fail_query = None
        self.mismatch = None
        self.unexpected_on = False
        self.short_write = False
        self.raw_payloads = []
        self.channels = {ch: {"OUTPut": "0", "MODe": "CONTINUE", "AMPLitude:UNIT": "VPP",
                             "LOAD": "10000", "BASE:WAVe": "SINE", "BASE:FREQuency": "100000",
                             "BASE:AMPLitude": "0.1", "BASE:OFFSet": "0", "BASE:PHAse": "0",
                             "BASE:DUTY": "50", "RAMP:SYMMetry": "50", "ARB:SOURce": "EXTERNAL", "ARB:INDex": "0"} for ch in (1, 2)}

    def query(self, command):
        self.calls.append(command)
        if self.fail_query == command:
            raise TimeoutError("Simulated USB disconnect")
        if command == "*IDN?":
            return "UNI-T Technologies,UTG932E,FAKE,3.06.004"
        if self.mismatch == command:
            return "999"
        channel, suffix = command[1:].split(":", 1)
        return self.channels[int(channel[-1])][suffix[:-1]]

    def write(self, command):
        self.calls.append(command)
        if command.startswith(":WARB"):
            for state in self.channels.values():
                state["BASE:WAVe"] = "ARB"
            return len(command) + 1
        channel, suffix = command[1:].split(":", 1)
        key, value = suffix.split(" ", 1)
        state = self.channels[int(channel[-1])]
        if key == "OUTPut":
            value = "1" if value == "ON" else "0"
        state[key] = value
        if self.unexpected_on and key == "BASE:WAVe":
            state["OUTPut"] = "1"
        return len(command) if self.short_write else len(command) + 1

    def write_raw(self, payload):
        self.raw_payloads.append(payload)
        return len(payload) - 1 if self.short_write else len(payload)

    def close(self):
        self.closed = True


class FakeRM:
    resource = "USB0::0x6656::0x0834::FAKE::INSTR"

    def __init__(self):
        self.device = FakeVISA()
        self.closed = False
        self.resources = [self.resource, "USB0::0x5345::0x1234::OWON::INSTR"]

    def list_resources(self, pattern):
        return self.resources

    def open_resource(self, resource, **kwargs):
        if resource != self.resource:
            raise AssertionError("Opened wrong device")
        return self.device

    def close(self):
        self.closed = True


class TestUTG(unittest.TestCase):
    def setUp(self):
        scratch = utg932.ROOT / "test_results"
        scratch.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="utg932_test_", dir=scratch)
        self.addCleanup(self.tmp.cleanup)
        self.patches = [patch.object(utg932, "ROOT", Path(self.tmp.name)),
                        patch.object(utg932.time, "sleep")]
        for p in self.patches:
            p.start()
            self.addCleanup(p.stop)
        self.rm = FakeRM()
        p = patch.object(utg932, "resource_manager", return_value=self.rm)
        p.start()
        self.addCleanup(p.stop)

    def connect(self):
        device = utg932.UTG932()
        self.addCleanup(device.close)
        return device

    def test_identify_status_close_are_read_only(self):
        before = copy.deepcopy(self.rm.device.channels)
        with utg932.UTG932() as device:
            self.assertEqual(device.settings(1)["hz"], 100000)
            device.settings(2)
        self.assertEqual(self.rm.device.channels, before)
        self.assertTrue(all(cmd.endswith("?") for cmd in self.rm.device.calls))
        self.assertTrue(self.rm.closed and self.rm.device.closed)

    def test_vrms_is_not_mislabeled_as_vpp(self):
        self.rm.device.channels[1]["AMPLitude:UNIT"] = "VRMS"
        state = self.connect().settings()
        self.assertIsNone(state["vpp"])
        self.assertEqual(state["amplitude"], 0.1)

    def test_channel_two_configure_never_enables_or_touches_channel_one(self):
        before = copy.deepcopy(self.rm.device.channels[1])
        device = self.connect()
        state = device.configure(2, hz=50000, vpp=0.2, offset_v=0.1, phase_deg=30)
        self.assertFalse(state["output"])
        self.assertEqual(state["hz"], 50000)
        self.assertEqual(self.rm.device.channels[1], before)
        self.assertNotIn(":CHANnel2:OUTPut ON", self.rm.device.calls)

    def test_waveform_parameters_verified(self):
        device = self.connect()
        for wave, extra, key in (("square", {"duty": 20}, "duty"),
                                 ("pulse", {"duty": 25}, "duty"),
                                 ("ramp", {"symmetry": 30}, "symmetry")):
            state = device.configure(waveform=wave, hz=1000, **extra)
            self.assertEqual(state[key], extra[key])

    def test_mismatched_readback_leaves_output_off(self):
        device = self.connect()
        self.rm.device.mismatch = ":CHANnel1:BASE:AMPLitude?"
        with self.assertRaisesRegex(RuntimeError, "Readback mismatch"):
            device.configure()
        self.assertEqual(self.rm.device.channels[1]["OUTPut"], "0")
        self.assertNotIn(":CHANnel1:OUTPut ON", self.rm.device.calls)

    def test_unexpected_on_during_config_is_stopped(self):
        device = self.connect()
        self.rm.device.unexpected_on = True
        with self.assertRaisesRegex(RuntimeError, "Unexpected output ON"):
            device.configure()
        self.assertEqual(self.rm.device.channels[1]["OUTPut"], "0")
        self.assertNotIn(":CHANnel1:BASE:AMPLitude 0.1", self.rm.device.calls)

    def test_disconnect_poisoned_session_only_allows_emergency_write(self):
        device = self.connect()
        self.rm.device.fail_query = ":CHANnel1:BASE:AMPLitude?"
        with self.assertRaises(TimeoutError):
            device.configure()
        self.assertTrue(device.broken)
        self.assertEqual(self.rm.device.calls[-1], ":CHANnel1:OUTPut OFF")
        with self.assertRaisesRegex(RuntimeError, "Failed session"):
            device.query("*IDN?")
        off = device.emergency_off(2)
        self.assertTrue(off["sent"])
        self.assertFalse(off["acknowledged"])

    def test_short_write_poisoned_and_never_enables(self):
        device = self.connect()
        self.rm.device.short_write = True
        with self.assertRaises(IOError):
            device.configure()
        self.assertTrue(device.broken)
        self.assertNotIn(":CHANnel1:OUTPut ON", self.rm.device.calls)

    def test_explicit_on_and_off(self):
        device = self.connect()
        device.configure()
        device.output_on()
        self.assertEqual(self.rm.device.channels[1]["OUTPut"], "1")
        device.output_off()
        self.assertEqual(self.rm.device.channels[1]["OUTPut"], "0")

    def test_unsafe_current_settings_block_output(self):
        device = self.connect()
        self.rm.device.channels[1]["BASE:AMPLitude"] = "15"
        with self.assertRaises(ValueError):
            device.output_on()
        self.assertNotIn(":CHANnel1:OUTPut ON", self.rm.device.calls)

    def test_failure_after_on_attempt_sends_off(self):
        device = self.connect()
        original = self.rm.device.write
        def write(command):
            result = original(command)
            if command.endswith(" ON"):
                self.rm.device.fail_query = ":CHANnel1:OUTPut?"
            return result
        self.rm.device.write = write
        with self.assertRaises(TimeoutError):
            device.output_on()
        self.assertEqual(self.rm.device.channels[1]["OUTPut"], "0")

    def test_invalid_configuration_never_writes(self):
        device = self.connect()
        for kwargs in ({"hz": float("nan")}, {"vpp": 6}, {"load": "50", "vpp": 5, "offset_v": 0.1}):
            with self.assertRaises(ValueError):
                device.configure(**kwargs)
        self.assertEqual(self.rm.device.calls, ["*IDN?"])

    def test_channel_and_scpi_injection_rejected(self):
        device = self.connect()
        for channel in (True, 1.0, 0, 3, "1"):
            with self.assertRaises(ValueError):
                device.output_off(channel)
        for command in ("*IDN?;*RST", "*IDN?\n", "*RST", "*IDN??"):
            with self.assertRaises(ValueError):
                device.query(command)

    def test_wrong_identity_and_ambiguous_discovery_close_and_release(self):
        self.rm.device.query = lambda _: "OWON,HDS242S,SERIAL,V8.1.0"
        with self.assertRaisesRegex(RuntimeError, "Unexpected"):
            utg932.UTG932()
        self.assertTrue(self.rm.closed and self.rm.device.closed)
        with ResourceLock(Path(self.tmp.name) / ".lab_locks/utg932.lock"):
            pass
        self.rm.resources.append("USB0::26198::2100::OTHER::INSTR")
        with self.assertRaisesRegex(RuntimeError, "found 2"):
            utg932.UTG932()

    def test_device_exclusivity(self):
        self.connect()
        with self.assertRaises(ResourceBusy):
            utg932.UTG932()

    def test_usb_resource_filter(self):
        self.assertTrue(utg932.is_utg_resource(FakeRM.resource))
        self.assertTrue(utg932.is_utg_resource("USB0::26198::2100::S::0::INSTR"))
        for value in ("USB0::0x5345::0x1234::S::INSTR", "TCPIP0::HOST::INSTR", "USB0::oops::2100::S::INSTR"):
            self.assertFalse(utg932.is_utg_resource(value))

    def test_dry_run_never_connects(self):
        with patch.object(utg932, "UTG932") as constructor, patch("builtins.print"):
            self.assertEqual(utg932.main(["configure", "--dry-run"]), 0)
            constructor.assert_not_called()

    def test_existing_log_rejected_before_connect(self):
        path = Path(self.tmp.name) / "session.json"
        path.write_text("preserve", encoding="utf-8")
        with patch.object(utg932, "UTG932") as constructor:
            with self.assertRaises(FileExistsError):
                utg932.main(["--log", str(path), "configure"])
            constructor.assert_not_called()
        self.assertEqual(path.read_text(), "preserve")

    def test_usbtmc_read_does_not_require_absent_lf(self):
        device = self.connect()
        self.assertIsNone(device.device.read_termination)
        self.assertEqual(device.device.write_termination, "\n")

    def test_upload_restores_waveforms_both_outputs_off(self):
        device = self.connect()
        self.rm.device.channels[1]["OUTPut"] = "1"
        self.rm.device.channels[2]["BASE:WAVe"] = "SQUARE"
        result = device.upload_arb([-1, 0, 1, 0], slot=1, name="TwoTone")
        self.assertEqual(result["points"], 4)
        self.assertEqual(self.rm.device.channels[1]["BASE:WAVe"], "SINE")
        self.assertEqual(self.rm.device.channels[2]["BASE:WAVe"], "SQUARE")
        self.assertTrue(all(state["OUTPut"] == "0" for state in self.rm.device.channels.values()))
        self.assertEqual(self.rm.device.raw_payloads, [encode_bsv([-1, 0, 1, 0])])
        self.assertIn(":WARB2:CARRier TwoTone", self.rm.device.calls)
        self.assertNotIn(":CHANnel1:OUTPut ON", self.rm.device.calls)

    def test_user_arb_configuration_and_on(self):
        device = self.connect()
        state = device.configure_arb(2, slot=1, hz=500, vpp=0.2)
        self.assertEqual(state["arb_source"], "EXTERNAL")
        self.assertEqual(state["arb_slot"], 1)
        self.assertFalse(state["output"])
        device.output_on(2)
        self.assertEqual(self.rm.device.channels[2]["OUTPut"], "1")

    def test_upload_invalid_payload_and_name_do_not_write(self):
        device = self.connect()
        for samples, name in (([0, float("nan")], "A"), ([0, 2], "A"), ([0, 1], "A;RST"), ([0], "A")):
            with self.assertRaises(ValueError):
                device.upload_arb(samples, name=name)
        self.assertEqual(self.rm.device.calls, ["*IDN?"])

    def test_short_upload_disables_both_and_poisoned(self):
        device = self.connect()
        original = self.rm.device.write_raw
        self.rm.device.write_raw = lambda payload: original(payload) - 1
        with self.assertRaises(IOError):
            device.upload_arb([0, 1, 0, -1])
        self.assertTrue(device.broken)
        self.assertEqual(self.rm.device.calls[-2:], [":CHANnel1:OUTPut OFF", ":CHANnel2:OUTPut OFF"])

    def test_bsv_signed_little_endian_and_roundtrip(self):
        payload = encode_bsv([-1, 0, 1, 0.5])
        self.assertTrue(payload.startswith(b"[HEAD]:"))
        self.assertTrue(payload.endswith(b"[DATA]:4\r\n" + struct.pack("<4h", -32767, 0, 32767, 16384)))
        self.assertEqual(encode_bsv(decode_bsv(payload)), payload)
        for invalid in (payload[:-1], payload + b"\n", payload.replace(b"MAX:32767", b"MAX:16383")):
            with self.assertRaises(ValueError):
                decode_bsv(invalid)

    def test_multitone_exact_frequencies_and_relative_amplitude(self):
        result = synthesize_multitone({"tones": [{"hz": 100000, "vpp": 0.1}, {"hz": 189500, "vpp": 0.05}]})
        self.assertEqual(result["repeat_hz"], 500)
        self.assertEqual(result["table_sample_rate_hz"], 2e6)
        self.assertAlmostEqual(result["vpp"], 0.15)
        samples = result["samples"]
        for tone in result["tones"]:
            amplitude = 2 / len(samples) * math.fsum(x * math.sin(2 * math.pi * tone["harmonic"] * i / len(samples)) for i, x in enumerate(samples))
            self.assertAlmostEqual(amplitude * result["vpp"], tone["vpp"], places=10)

    def test_multitone_aliasing_noncoherence_and_clipping_rejected(self):
        plans = [{"tones": [{"hz": 100000, "vpp": 0.2}], "vpp": 0.1},
                 {"tones": [{"hz": 100000, "vpp": 0.1}], "repeat_hz": 3000},
                 {"tones": [{"hz": 100000, "vpp": 0.1}, {"hz": 100001, "vpp": 0.1}]}]
        for plan in plans:
            with self.assertRaises(ValueError):
                synthesize_multitone(plan)

    def test_multitone_and_upload_preview_do_not_connect(self):
        plan = Path(self.tmp.name) / "plan.json"
        plan.write_text(json.dumps({"tones": [{"hz": 100000, "vpp": 0.1}]}))
        output = Path(self.tmp.name) / "wave.json"
        with patch.object(utg932, "UTG932") as constructor, patch("builtins.print"):
            self.assertEqual(utg932.main(["multitone", str(plan), "--save", str(output)]), 0)
            self.assertEqual(utg932.main(["upload", str(output), "--dry-run"]), 0)
            self.assertEqual(utg932.main(["arb", str(output), "--dry-run"]), 0)
            constructor.assert_not_called()
        self.assertEqual(len(load_samples(output)), 4000)

    def test_combined_arb_uses_metadata_and_keeps_both_off(self):
        path = Path(self.tmp.name) / "wave.json"
        path.write_text(json.dumps({"samples": [-1, 0, 1, 0], "repeat_hz": 500, "vpp": 0.15}))
        with patch("builtins.print"):
            self.assertEqual(utg932.main(["arb", str(path), "--slot", "1", "--name", "TwoTone"]), 0)
        self.assertEqual(self.rm.device.channels[1]["BASE:FREQuency"], "500")
        self.assertEqual(self.rm.device.channels[1]["BASE:WAVe"], "ARB")
        self.assertEqual(self.rm.device.channels[1]["ARB:INDex"], "1")
        self.assertTrue(all(state["OUTPut"] == "0" for state in self.rm.device.channels.values()))

    def test_bare_samples_require_scale_before_connect(self):
        path = Path(self.tmp.name) / "wave.json"
        path.write_text("[-1,0,1,0]")
        with patch.object(utg932, "UTG932") as constructor:
            with self.assertRaisesRegex(ValueError, "Specify --hz"):
                utg932.main(["arb", str(path)])
            constructor.assert_not_called()

    def test_upload_unexpected_level_mutation_detected(self):
        device = self.connect()
        original = self.rm.device.write_raw
        def write(payload):
            self.rm.device.channels[2]["BASE:AMPLitude"] = "2"
            return original(payload)
        self.rm.device.write_raw = write
        with self.assertRaisesRegex(RuntimeError, "CH2 changed during upload"):
            device.upload_arb([-1, 0, 1, 0])
        self.assertTrue(all(state["OUTPut"] == "0" for state in self.rm.device.channels.values()))

    def test_csv_bsv_and_sample_bounds(self):
        path = Path(self.tmp.name) / "wave.csv"
        path.write_text("# normalized\n-1\n0\n1\n0\n")
        self.assertEqual(load_samples(path), [-1, 0, 1, 0])
        bsv = path.with_suffix(".bsv")
        bsv.write_bytes(encode_bsv(load_samples(path)))
        self.assertEqual(load_samples(bsv), [-1, 0, 1, 0])
        for values in ([0] * 4001, [0, float("inf")], [True, 0]):
            with self.assertRaises(ValueError):
                encode_bsv(values)

    def test_screen_reads_binary_with_eom_without_line_terminator(self):
        device = self.connect()
        payload = b"BM" + bytes(52)
        def read(command, **kwargs):
            self.assertEqual(command, ":DISPlay?")
            self.assertFalse(kwargs["expect_termination"])
            return payload
        self.rm.device.query_binary_values = read
        self.assertEqual(device.screen(), payload)

    def test_dc_fixed_frequency_is_not_treated_as_failed_configuration(self):
        device = self.connect()
        original = self.rm.device.query
        def query(command):
            return "1e-6" if command == ":CHANnel1:BASE:FREQuency?" else original(command)
        self.rm.device.query = query
        state = device.configure(waveform="dc", offset_v=0.1)
        self.assertEqual(state["offset_v"], 0.1)
        self.assertEqual(state["hz"], 1e-6)
        self.assertNotIn(":CHANnel1:BASE:FREQuency 100000", self.rm.device.calls)


if __name__ == "__main__":
    unittest.main()
