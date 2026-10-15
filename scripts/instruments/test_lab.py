"""Offline concurrency/failure/API tests. Uses simulation only; no USB imports."""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from hds242s import HDS242S, ROOT, capture_ila, validate_plan
import hds242s
from lab_backend import FPGACaptureError, SimBackend
from lab_client import LabClient
from lab_controller import Busy, LabController, atomic_json
from lab_server import LabHTTPServer
from resource_lock import ResourceBusy, ResourceLock


LIMITS = {"max_vpp": .1, "min_output_v": -.05, "max_output_v": .05}
POINT = {"hz": 100000, "vpp": .1, "offset_v": 0}


def plan():
    return {"limits": copy.deepcopy(LIMITS), "connections_confirmed": True,
            "scope_channels": [], "capture_fpga": True, "samples_per_point": 2,
            "settle_s": 1, "points": [copy.deepcopy(POINT)]}


class LabTests(unittest.TestCase):
    def setUp(self):
        base = ROOT / "test_results"
        base.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=base)
        self.directory = Path(self.temporary.name)
        self.backend = SimBackend()
        self.controller = LabController(self.backend, self.directory / "session", poll_s=.05, queue_limit=2)

    def tearDown(self):
        self.controller.close()
        self.temporary.cleanup()

    def wait(self, job, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = self.controller.job(job["id"])
            if result["status"] in ("completed", "failed", "cancelled"):
                return result
            time.sleep(.01)
        self.fail(f"Job did not finish: {self.controller.job(job['id'])}")

    def run_job(self, action, params=None):
        return self.wait(self.controller.submit(action, params))

    def connect_configure(self):
        self.assertEqual(self.run_job("connect")["status"], "completed")
        self.assertEqual(self.run_job("configure_generator", {"point": POINT, "limits": LIMITS})["status"], "completed")

    def start_blocked_capture(self):
        self.backend.capture_delay = 5
        job = self.controller.submit("capture_fpga")
        self.assertTrue(self.backend.active_capture.wait(1))
        return job

    def test_startup_has_unknown_output_no_replay(self):
        state = self.controller.status()
        self.assertEqual(state["link"], "disconnected")
        self.assertEqual(state["output"], "unknown")
        self.assertTrue(state["stale"])
        self.assertFalse(self.backend.connected)

    def test_panel_change_invalidates_verified_config(self):
        self.connect_configure()
        self.assertTrue(self.controller.status()["verified"])
        self.backend.panel_change(vpp=.08)
        deadline = time.monotonic() + 1
        while self.controller.status()["verified"] and time.monotonic() < deadline:
            time.sleep(.01)
        state = self.controller.status()
        self.assertFalse(state["verified"])
        self.assertEqual(state["generator"]["vpp"], .08)
        self.assertEqual(self.run_job("set_output", {"enabled": True, "connections_confirmed": True})["status"], "failed")
        self.assertEqual(self.backend.values["output"], "off")

    def test_output_on_requires_configuration_and_confirmation(self):
        self.run_job("connect")
        failed = self.run_job("set_output", {"enabled": True, "connections_confirmed": True})
        self.assertEqual(failed["status"], "failed")
        self.connect_configure()
        failed = self.run_job("set_output", {"enabled": True})
        self.assertEqual(failed["status"], "failed")
        self.connect_configure()
        self.assertEqual(self.run_job("set_output", {"enabled": True, "connections_confirmed": True})["status"], "completed")
        self.assertEqual(self.controller.status()["output"], "on")
        self.assertEqual(self.run_job("output_off")["status"], "completed")
        state = self.controller.status()
        self.assertEqual(state["output"], state["generator"]["output"])

    def test_status_fast_during_capture_and_stale_is_explicit(self):
        self.run_job("connect")
        job = self.start_blocked_capture()
        # Simulate elapsed observation age without waiting for a long test.
        self.controller._last_sync = time.monotonic() - 5
        start = time.monotonic()
        with ThreadPoolExecutor(max_workers=8) as pool:
            states = list(pool.map(lambda _: self.controller.status(), range(32)))
        self.assertLess(time.monotonic() - start, .5)
        self.assertTrue(all(state["stale"] for state in states))
        self.assertTrue(all(state["active_job"] == job["id"] for state in states))
        self.controller.cancel(job["id"])
        self.assertEqual(self.wait(job)["status"], "cancelled")

    def test_queue_bound_cancel_queued_and_running(self):
        self.run_job("connect")
        active = self.start_blocked_capture()
        queued = self.controller.submit("sync")
        self.controller.submit("sync")
        with self.assertRaises(Busy):
            self.controller.submit("sync")
        self.controller.cancel(queued["id"])
        self.assertEqual(self.controller.job(queued["id"])["status"], "cancelled")
        self.controller.cancel(active["id"])
        self.assertEqual(self.wait(active)["status"], "cancelled")

    def test_stop_cancels_queued_enable_and_bypasses_full_queue(self):
        self.connect_configure()
        self.run_job("set_output", {"enabled": True, "connections_confirmed": True})
        active = self.start_blocked_capture()
        queued_on = self.controller.submit("set_output", {"enabled": True, "connections_confirmed": True})
        self.controller.submit("sync")
        off = self.controller.submit("output_off")
        self.assertEqual(self.wait(off)["status"], "completed")
        self.assertEqual(self.wait(active)["status"], "cancelled")
        self.assertEqual(self.controller.job(queued_on["id"])["status"], "cancelled")
        self.assertEqual(self.backend.values["output"], "off")

    def test_idempotency_deduplicates_and_rejects_different_payload(self):
        first = self.controller.submit("connect", request_id="same")
        second = self.controller.submit("connect", request_id="same")
        self.assertEqual(first["id"], second["id"])
        with self.assertRaises(ValueError):
            self.controller.submit("disconnect", request_id="same")
        self.wait(first)

    def test_poll_failure_unknown_then_explicit_reconnect(self):
        self.run_job("connect")
        self.backend.next_error = TimeoutError("Unplugged")
        deadline = time.monotonic() + 1
        while self.controller.status()["link"] != "faulted" and time.monotonic() < deadline:
            time.sleep(.01)
        state = self.controller.status()
        self.assertEqual(state["link"], "faulted")
        self.assertIsNone(state["generator"])
        self.assertTrue(state["stale"])
        self.assertFalse(state["verified"])
        self.assertEqual(self.run_job("connect")["status"], "completed")
        self.assertFalse(self.controller.status()["verified"])

    def test_plan_without_scope_records_fpga_and_turns_output_off(self):
        self.run_job("connect")
        job = self.run_job("run_plan", {"plan": plan()})
        self.assertEqual(job["status"], "completed", job)
        self.assertEqual(job["result"]["samples"], 2)
        self.assertEqual(self.backend.values["output"], "off")
        files = list((self.controller.directory / job["id"]).glob("point_*/result.json"))
        self.assertEqual(len(files), 2)
        record = json.loads(files[0].read_text())
        self.assertTrue(record["simulated"])
        self.assertIsNone(record["scope"])
        self.assertEqual(record["fpga"]["frequency_hz"], 100000)

    def test_unconfirmed_plan_never_configures_or_enables(self):
        self.run_job("connect")
        invalid = plan()
        invalid["connections_confirmed"] = False
        result = self.run_job("run_plan", {"plan": invalid})
        self.assertEqual(result["status"], "failed")
        self.assertEqual(self.backend.configure_count, 0)
        self.assertEqual(self.backend.values["output"], "off")

    def test_cancel_plan_while_settling(self):
        self.run_job("connect")
        job = self.controller.submit("run_plan", {"plan": plan()})
        deadline = time.monotonic() + 1
        while self.backend.values["output"] != "on" and time.monotonic() < deadline:
            time.sleep(.01)
        start = time.monotonic()
        self.controller.cancel(job["id"])
        self.assertEqual(self.wait(job)["status"], "cancelled")
        self.assertLess(time.monotonic() - start, .5)
        self.assertEqual(self.backend.values["output"], "off")

    def test_external_change_during_acquisition_rejects_result(self):
        self.run_job("connect")
        self.backend.capture_delay = .3
        job = self.controller.submit("run_plan", {"plan": plan()})
        self.assertTrue(self.backend.active_capture.wait(2))
        self.backend.panel_change(hz=200000)
        result = self.wait(job)
        self.assertEqual(result["status"], "failed")
        self.assertIn("changed during acquisition", result["error"])
        self.assertFalse(list((self.controller.directory / job["id"]).glob("point_*/result.json")))
        self.assertEqual(self.backend.values["output"], "off")

    def test_cancel_and_timeout_reap_owned_fpga_child(self):
        original_popen = subprocess.Popen
        for cancel_requested in (True, False):
            directory = self.directory / ("cancel_child" if cancel_requested else "timeout_child")
            directory.mkdir()
            children = []
            def create_child(*args, **kwargs):
                if "-mode" not in args[0]:
                    return original_popen(*args, **kwargs)
                process = original_popen([sys.executable, "-c", "import time; time.sleep(10)"], **kwargs)
                children.append(process)
                return process
            cancel = threading.Event()
            timer = threading.Timer(.15, cancel.set) if cancel_requested else None
            if timer:
                timer.start()
            with patch.object(hds242s.subprocess, "Popen", side_effect=create_child), patch.object(
                    hds242s, "ResourceLock", side_effect=lambda _: ResourceLock(directory / "fpga.lock")):
                expected_error = InterruptedError if cancel_requested else TimeoutError
                with self.assertRaises(expected_error):
                    capture_ila(sys.executable, directory, directory / "not-used.ltx", cancel,
                                timeout_s=2 if cancel_requested else .15)
            if timer:
                timer.join()
            self.assertIsNotNone(children[0].poll())
            self.assertTrue((directory / "vivado_capture.txt").is_file())

    def test_shutdown_cancels_capture_and_releases_device(self):
        self.connect_configure()
        active = self.start_blocked_capture()
        self.controller.close()
        self.assertEqual(self.controller.job(active["id"])["status"], "cancelled")
        self.assertFalse(self.backend.connected)
        self.assertFalse(self.controller.status()["worker_alive"])
        persisted = json.loads((self.controller.directory / "state.json").read_text())
        self.assertEqual(persisted["queue_depth"], 0)
        self.assertIsNone(persisted["active_job"])
        with self.assertRaises(Busy):
            self.controller.submit("connect")

    def test_fpga_failure_does_not_falsely_disconnect_usb(self):
        self.run_job("connect")
        def fail_capture(*args):
            raise FPGACaptureError("Simulated JTAG timeout")
        self.backend.fpga = fail_capture
        result = self.run_job("capture_fpga")
        self.assertEqual(result["status"], "failed")
        state = self.controller.status()
        self.assertEqual(state["link"], "connected")
        self.assertEqual(state["fpga_status"], "failed")
        self.assertIsNone(state["fpga_result"])

    def test_failed_usb_write_poisons_session(self):
        class FailingUSB:
            def write(self, *args, **kwargs):
                raise OSError("Simulated USB unplug")
        device = HDS242S.__new__(HDS242S)
        device._io_lock = threading.RLock()
        device.device = FailingUSB()
        device.timeout_ms = 100
        device.log = []
        device.broken = False
        device.pending = bytearray()
        with self.assertRaises(OSError):
            device.query("*IDN?")
        self.assertTrue(device.broken)

    def test_transport_query_pairs_are_serialized(self):
        class EchoUSB:
            def __init__(self):
                self.response = None
                self.trace = []
            def write(self, endpoint, data, timeout):
                self.assert_no_pending()
                self.response = data
                self.trace.append("write")
                time.sleep(.005)
                return len(data)
            def assert_no_pending(self):
                if self.response is not None:
                    raise AssertionError("Concurrent SCPI transaction")
            def read(self, *args, **kwargs):
                self.trace.append("read")
                result, self.response = self.response, None
                return result
        device = HDS242S.__new__(HDS242S)
        device._io_lock = threading.RLock()
        device.device = EchoUSB()
        device.timeout_ms = 100
        device.log = []
        device.broken = False
        device.pending = bytearray()
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda index: device.query(f":ECHO{index}?"), range(16)))
        self.assertEqual(results, [f":ECHO{index}?" for index in range(16)])
        self.assertEqual(device.device.trace, ["write", "read"] * 16)

    def test_failed_off_never_claims_output_off(self):
        self.run_job("connect")
        self.backend.emergency_off = lambda: {"sent": True, "acknowledged": False}
        result = self.run_job("output_off")
        self.assertEqual(result["status"], "failed")
        self.assertEqual(self.controller.status()["output"], "unknown")
        self.assertEqual(self.controller.status()["link"], "faulted")

    def test_cross_process_lock_and_recovery(self):
        path = self.directory / "resource.lock"
        with ResourceLock(path):
            with self.assertRaises(ResourceBusy):
                ResourceLock(path).acquire()
            code = "from resource_lock import ResourceLock; import sys; ResourceLock(sys.argv[1]).acquire()"
            process = subprocess.run([sys.executable, "-c", code, str(path)],
                                     cwd=Path(__file__).parent, capture_output=True, timeout=5)
            self.assertNotEqual(process.returncode, 0)
        with ResourceLock(path):
            pass

    def test_json_snapshot_atomic_and_machine_readable(self):
        self.run_job("connect")
        data = json.loads((self.controller.directory / "state.json").read_text())
        self.assertGreater(data["revision"], 0)
        self.assertTrue(data["simulated"])
        self.assertEqual(data["link"], "connected")
        self.assertGreater(self.controller.events()["cursor"], 0)

    def test_http_async_auth_idempotency_and_validation(self):
        server = LabHTTPServer(self.controller, "test-token")
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .02}, daemon=True)
        thread.start()
        manifest = self.directory / "client.json"
        atomic_json(manifest, {"running": True, "base_url": f"http://127.0.0.1:{server.server_port}", "token": "test-token"})
        client = LabClient(manifest)
        try:
            with self.assertRaises(HTTPError) as caught:
                urlopen(client.base_url + "/v1/status", timeout=1)
            self.assertEqual(caught.exception.code, 403)
            self.assertTrue(client.status()["simulated"])
            job = client.submit("connect", request_id="network-id")
            self.assertEqual(client.submit("connect", request_id="network-id")["id"], job["id"])
            self.assertEqual(client.wait(job["id"], 2)["status"], "completed")
            self.assertTrue(client.request("/v1/plan/validate", {"plan": plan()})["valid"])
            active = self.start_blocked_capture()
            start = time.monotonic()
            self.assertEqual(client.status()["active_job"], active["id"])
            self.assertLess(time.monotonic() - start, .5)
            with self.assertRaises(TimeoutError):
                client.wait(active["id"], .02)
            self.assertEqual(client.job(active["id"])["status"], "running")
            client.cancel(active["id"])
            self.assertEqual(client.wait(active["id"], 2)["status"], "cancelled")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(1)

    def test_transport_poisoned_off_does_not_consume_old_reply(self):
        class USB:
            def __init__(self):
                self.writes = []
            def write(self, endpoint, data, timeout):
                self.writes.append(data)
                return len(data)
            def read(self, *args, **kwargs):
                raise AssertionError("Poisoned session must not read an old reply")
        device = HDS242S.__new__(HDS242S)
        device._io_lock = threading.RLock()
        device.device = USB()
        device.timeout_ms = 100
        device.log = []
        device.broken = True
        result = device.emergency_off()
        self.assertTrue(result["sent"])
        self.assertFalse(result["acknowledged"])
        self.assertTrue(device.broken)
        self.assertEqual(device.device.writes, [b":CHANnel OFF\n"])


if __name__ == "__main__":
    unittest.main()
