"""Real and simulated lab endpoints. Simulation never imports USB or Vivado."""
from __future__ import annotations

import copy
import math
from pathlib import Path
import threading
import time

from hds242s import HDS242S, capture_ila, generator_load, timestamp


class FPGACaptureError(RuntimeError):
    """FPGA/Vivado failure, distinct from a USB instrument disconnect."""
    pass


def read_state(device):
    generator = device.generator_settings()["si"]
    generator["waveform"] = device.query(":FUNCtion?").upper()
    generator["load"] = generator_load(device.query(":FUNCtion:LOAD?"))
    raw = device.query(":CHANnel?").upper()
    if raw not in ("ON", "OFF", "0", "1"):
        raise ValueError(f"Invalid OUT state: {raw}")
    generator["output"] = "on" if raw in ("ON", "1") else "off"
    return generator


class RealBackend:
    simulated = False

    def __init__(self, vivado=None, ltx=None):
        self.vivado = vivado
        self.ltx = ltx
        self.device = None

    def connect(self):
        if self.device is not None:
            raise RuntimeError("Already connected")
        device = HDS242S(timeout_ms=1500)
        try:
            identity = device.identify()
        except BaseException:
            device.close()
            raise
        self.device = device
        return identity

    def close(self):
        if self.device is not None:
            device, self.device = self.device, None
            device.close()

    def state(self):
        return read_state(self.device)

    def configure(self, point):
        self.device.configure_sine(point)

    def set_output(self, enabled):
        self.device.set(":CHANnel ON" if enabled else ":CHANnel OFF")

    def emergency_off(self):
        if self.device is None:
            return {"sent": False, "acknowledged": False, "error": "Not connected"}
        return self.device.emergency_off()

    def scope(self, channels):
        return self.device.snapshot(channels)

    def configure_scope(self, config):
        return self.device.configure_scope(config)

    def fpga(self, directory, cancel):
        if not self.vivado or not self.ltx:
            raise RuntimeError("Configure --vivado and --ltx for hardware FPGA capture")
        try:
            return capture_ila(self.vivado, directory, self.ltx, cancel=cancel)
        except InterruptedError:
            raise
        except Exception as error:
            raise FPGACaptureError(str(error)) from error

    def validate_fpga(self):
        if not self.vivado or not self.ltx or not Path(self.vivado).is_file() or not Path(self.ltx).is_file():
            raise ValueError("Real FPGA capture requires existing --vivado and --ltx files")

    def drain_log(self):
        if not self.device:
            return []
        entries = list(self.device.log)
        self.device.log.clear()
        return entries


class SimBackend:
    """Deterministic development endpoint. All returned data marked simulated."""
    simulated = True

    def __init__(self, capture_delay=0.04):
        self.connected = False
        self.values = {"hz": 1000.0, "vpp": 1.0, "offset_v": 0.0,
                       "waveform": "SINE", "load": "HIGHZ", "output": "off"}
        self.capture_delay = capture_delay
        self._lock = threading.Lock()
        self.next_error = None
        self.active_capture = threading.Event()
        self.configure_count = 0

    def connect(self):
        self.connected = True
        return "SIMULATED,HDS242S,NO-HARDWARE,V8.1.0"

    def close(self):
        self.connected = False

    def state(self):
        if not self.connected:
            raise ConnectionError("Simulated device disconnected")
        if self.next_error:
            error, self.next_error = self.next_error, None
            raise error
        with self._lock:
            return copy.deepcopy(self.values)

    def panel_change(self, **values):
        with self._lock:
            self.values.update(values)

    def configure(self, point):
        self.configure_count += 1
        self.panel_change(**point, waveform="SINE", load="HIGHZ", output="off")

    def set_output(self, enabled):
        self.panel_change(output="on" if enabled else "off")

    def emergency_off(self):
        self.panel_change(output="off")
        return {"sent": self.connected, "acknowledged": self.connected}

    def scope(self, channels):
        state = self.state()
        return {"simulated": True, "time": timestamp(), "settings": state,
                "channels": {str(ch): {"vpp_v": state["vpp"], "frequency_hz": state["hz"]}
                             for ch in channels}}

    def configure_scope(self, config):
        return {'simulated': True, 'requested': dict(config)}

    def fpga(self, directory, cancel):
        self.active_capture.set()
        try:
            if cancel.wait(self.capture_delay):
                raise InterruptedError("Simulated FPGA capture cancelled")
            state = self.state()
            return {"simulated": True, "frequency_hz": round(state["hz"] / 500) * 500,
                    "max_index_out": round(state["hz"] / 500),
                    "vpp_out": round(state["vpp"] * 10000),
                    "vrms_out": round(state["vpp"] * 10000 / (2 * math.sqrt(2))),
                    "amp_f1_out": round(state["vpp"] * 100000)}
        finally:
            self.active_capture.clear()

    def validate_fpga(self):
        pass

    def drain_log(self):
        return []
