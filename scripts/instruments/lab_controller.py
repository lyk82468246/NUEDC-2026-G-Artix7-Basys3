"""Single-owner worker, bounded asynchronous jobs, explicit observed state.

HTTP threads never access hardware. Only this worker owns backend operations.
No mutating command is automatically retried after a disconnect or restart.
"""
from __future__ import annotations

from collections import deque
import copy
import csv
import json
import math
from pathlib import Path
import threading
import time
import uuid

from hds242s import timestamp, validate_plan, validate_scope_config


class Busy(RuntimeError):
    pass


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def signature(generator):
    return tuple(generator[key] for key in ("hz", "vpp", "offset_v", "waveform", "load"))


class LabController:
    ACTIONS = ("connect", "disconnect", "sync", "configure_generator", "set_output",
               "output_off", "configure_scope", "capture_scope", "capture_fpga", "run_plan")

    def __init__(self, backend, directory, poll_s=2.0, queue_limit=8, history_limit=128):
        if not 0.05 <= poll_s <= 30:
            raise ValueError("poll_s must be 0.05..30 seconds")
        self.backend = backend
        self.directory = Path(directory).resolve()
        if (self.directory / "state.json").exists():
            raise FileExistsError("Session directory already contains state; choose a new directory")
        self.directory.mkdir(parents=True, exist_ok=True)
        self.poll_s = poll_s
        self.queue_limit = queue_limit
        self.history_limit = history_limit
        self._lock = threading.RLock()
        self._condition = threading.Condition(self._lock)
        self._pending = deque()
        self._jobs = {}
        self._requests = {}
        self._events = deque(maxlen=256)
        self._sequence = 0
        self._active = None
        self._connected = False
        self._verified = None
        self._last_sync = None
        self._closing = False
        self._stopping = threading.Event()
        self._state = {"session_id": uuid.uuid4().hex, "revision": 0, "simulated": backend.simulated,
                       "link": "disconnected", "phase": "idle", "output": "unknown",
                       "generator": None, "observed_at": None, "verified": False,
                       "fpga_status": "idle", "fpga_result": None,
                       "active_job": None, "last_error": None}
        self._publish("started")
        self._worker = threading.Thread(target=self._loop, name="lab-device-owner", daemon=True)
        self._worker.start()

    def _publish(self, event, **changes):
        with self._lock:
            self._state.update(changes)
            self._state["queue_depth"] = len(self._pending)
            self._state["revision"] += 1
            self._state["updated_at"] = timestamp()
            self._sequence += 1
            entry = {"sequence": self._sequence, "time": timestamp(), "event": event,
                     "simulated": self.backend.simulated, **copy.deepcopy(changes)}
            self._events.append(entry)
            with (self.directory / "events.jsonl").open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(entry, ensure_ascii=False, allow_nan=False) + "\n")
            atomic_json(self.directory / "state.json", self._state)

    def status(self):
        with self._lock:
            result = copy.deepcopy(self._state)
            age = None if self._last_sync is None else max(0, time.monotonic() - self._last_sync)
            result.update(age_s=age, stale=(not self._connected or age is None or age > max(1.0, 3 * self.poll_s)),
                          queue_depth=len(self._pending), closing=self._closing,
                          worker_alive=self._worker.is_alive())
            return result

    def events(self, after=0):
        with self._lock:
            return {"events": copy.deepcopy([x for x in self._events if x["sequence"] > after]),
                    "cursor": self._sequence,
                    "truncated": bool(self._events and after < self._events[0]["sequence"] - 1)}

    def jobs(self):
        with self._lock:
            return [self._public_job(job) for job in self._jobs.values()]

    def job(self, identifier):
        with self._lock:
            if identifier not in self._jobs:
                raise KeyError(identifier)
            return self._public_job(self._jobs[identifier])

    @staticmethod
    def _public_job(job):
        return copy.deepcopy({k: v for k, v in job.items() if k != "cancel" and not k.startswith("_")})

    def submit(self, action, params=None, request_id=None):
        if action not in self.ACTIONS:
            raise ValueError(f"Unknown action: {action}")
        params = copy.deepcopy(params if params is not None else {})
        if not isinstance(params, dict):
            raise ValueError("params must be an object")
        # Check JSON serializability and finite numbers before a worker sees it.
        if len(json.dumps(params, allow_nan=False)) > 200000:
            raise ValueError("Job payload too large")
        fingerprint = json.dumps([action, params], sort_keys=True, allow_nan=False)
        if request_id is not None and (not isinstance(request_id, str) or not 1 <= len(request_id) <= 128):
            raise ValueError("request_id must have 1..128 characters")
        with self._condition:
            if self._closing:
                raise Busy("Controller is closing")
            if request_id in self._requests:
                old_fingerprint, identifier = self._requests[request_id]
                if fingerprint != old_fingerprint:
                    raise ValueError("Idempotency key reused with a different action/payload")
                return self.job(identifier)
            if action == "output_off":
                # Stop cancels pending writes too; they must not re-enable OUT.
                self._cancel_pending("Superseded by output_off")
                if self._active:
                    self._jobs[self._active]["cancel"].set()
            elif len(self._pending) >= self.queue_limit:
                raise Busy("Job queue full; retry after a task completes")
            while len(self._jobs) >= self.history_limit:
                done = next((key for key, job in self._jobs.items()
                             if job["status"] in ("completed", "cancelled", "failed")), None)
                if done is None:
                    raise Busy("Job history full")
                del self._jobs[done]
                self._requests = {key: value for key, value in self._requests.items() if value[1] != done}
            identifier = uuid.uuid4().hex
            self._jobs[identifier] = {"id": identifier, "action": action, "params": params,
                                      "status": "queued", "created_at": timestamp(),
                                      "simulated": self.backend.simulated, "cancel": threading.Event()}
            if request_id is not None:
                self._requests[request_id] = (fingerprint, identifier)
            if action == "output_off":
                self._pending.appendleft(identifier)
            else:
                self._pending.append(identifier)
            self._write_job(self._jobs[identifier])
            self._publish("job_queued", queue_depth=len(self._pending))
            self._condition.notify_all()
            return self.job(identifier)

    def _cancel_pending(self, reason):
        while self._pending:
            job = self._jobs[self._pending.popleft()]
            job.update(status="cancelled", finished_at=timestamp(), error=reason)
            job["cancel"].set()
            self._write_job(job)

    def cancel(self, identifier):
        with self._condition:
            job = self._jobs[identifier]
            if job["status"] in ("completed", "cancelled", "failed"):
                return self._public_job(job)
            job["cancel"].set()
            if identifier in self._pending:
                self._pending.remove(identifier)
                job.update(status="cancelled", finished_at=timestamp())
                self._write_job(job)
            else:
                job["status"] = "cancelling"
            self._publish("cancel_requested", queue_depth=len(self._pending))
            self._condition.notify_all()
            return self._public_job(job)

    def _write_job(self, job):
        directory = self.directory / job["id"]
        directory.mkdir(exist_ok=True)
        atomic_json(directory / "job.json", self._public_job(job))

    def _check_cancel(self, cancel):
        if cancel.is_set() or self._stopping.is_set():
            raise InterruptedError("Job cancelled")

    def _audit(self):
        entries = self.backend.drain_log()
        if entries:
            with (self.directory / "scpi.jsonl").open("a", encoding="utf-8") as stream:
                for entry in entries:
                    stream.write(json.dumps(entry, ensure_ascii=False) + "\n")

    def _sync(self):
        if not self._connected:
            raise ConnectionError("Instrument not connected; submit connect first")
        generator = self.backend.state()
        self._audit()
        if self._verified is not None and self._verified != signature(generator):
            self._verified = None
        self._last_sync = time.monotonic()
        self._publish("synced", generator=generator, output=generator["output"],
                      observed_at=timestamp(), output_observed_at=timestamp(),
                      verified=self._verified is not None)
        return generator

    def _off(self):
        result = self.backend.emergency_off()
        self._audit()
        generator = copy.deepcopy(self._state["generator"])
        if generator is not None:
            generator["output"] = "off" if result["acknowledged"] else "unknown"
        self._publish("output_off", output="off" if result["acknowledged"] else "unknown",
                      generator=generator, off_confirmation=result, output_observed_at=timestamp())
        if not result["acknowledged"]:
            raise ConnectionError("Cannot confirm OUT OFF; check instrument manually")
        return result

    @staticmethod
    def _plan(params):
        plan = copy.deepcopy(params["plan"])
        validate_plan(plan)
        if len(plan["points"]) > 1000:
            raise ValueError("At most 1000 points per plan")
        repeats = plan.get("samples_per_point", 1)
        if type(repeats) is not int or not 1 <= repeats <= 20:
            raise ValueError("samples_per_point must be 1..20")
        if type(plan.get("capture_fpga", True)) is not bool:
            raise ValueError("capture_fpga must be boolean")
        return plan

    def _configure(self, point, limits):
        point = {key: float(point[key]) for key in ("hz", "vpp", "offset_v")}
        validate_plan({"limits": limits, "points": [point], "scope_channels": []})
        if not self._connected:
            raise ConnectionError("Instrument not connected")
        self._verified = None
        self._publish("configuring", verified=False)
        with self._lock:
            self._jobs[self._active]["_mutated"] = True
        self.backend.configure(point)
        observed = self._sync()
        if observed["output"] != "off" or observed["waveform"] != "SINE" or observed["load"] != "HIGHZ":
            raise RuntimeError("Generator mode/output readback mismatch")
        for key in point:
            if not math.isclose(point[key], observed[key], rel_tol=1e-4, abs_tol=1e-6):
                raise RuntimeError(f"Generator {key} readback mismatch")
        self._verified = signature(observed)
        self._publish("configured", verified=True)
        return observed

    def _output(self, enabled, confirmed):
        if type(enabled) is not bool:
            raise ValueError("enabled must be boolean")
        if not enabled:
            return self._off()
        observed = self._sync()  # Refresh before every enable, never use cached settings.
        if confirmed is not True or self._verified is None or self._verified != signature(observed):
            raise ValueError("Output enable requires confirmed wiring and freshly verified configuration")
        with self._lock:
            self._jobs[self._active]["_mutated"] = True
        self.backend.set_output(True)
        result = self._sync()
        if result["output"] != "on" or self._verified is None:
            raise RuntimeError("Output enable readback mismatch")
        return result

    def _run_plan(self, job, directory):
        plan = self._plan(job["params"])
        if plan.get("connections_confirmed") is not True:
            raise ValueError("Plan wiring is not confirmed")
        fpga_enabled = plan.get("capture_fpga", True)
        if not fpga_enabled and not plan.get("scope_channels"):
            raise ValueError("Plan must capture FPGA and/or scope results")
        if fpga_enabled:
            self.backend.validate_fpga()
        atomic_json(directory / "plan.json", plan)
        rows = []
        cancel = job["cancel"]
        try:
            for index, point in enumerate(plan["points"]):
                self._check_cancel(cancel)
                self._configure(point, plan["limits"])
                expected = self._verified
                self._check_cancel(cancel)
                self._output(True, True)
                if cancel.wait(float(plan.get("settle_s", 2))):
                    self._check_cancel(cancel)
                for sample in range(plan.get("samples_per_point", 1)):
                    self._check_cancel(cancel)
                    self._sync()
                    if self._verified != expected or self._state["output"] != "on":
                        raise RuntimeError("Generator changed before acquisition")
                    sample_dir = directory / f"point_{index:03d}_sample_{sample:02d}"
                    sample_dir.mkdir()
                    self._publish("acquiring", progress={"point": index, "sample": sample,
                                  "total_points": len(plan["points"]), "directory": str(sample_dir)})
                    scope = self.backend.scope(plan["scope_channels"]) if plan.get("scope_channels") else None
                    self._check_cancel(cancel)
                    fpga = self._capture_fpga(sample_dir, cancel) if fpga_enabled else None
                    self._check_cancel(cancel)
                    self._sync()
                    if self._verified != expected or self._state["output"] != "on":
                        self._publish("fpga_result_rejected", fpga_status="rejected", fpga_result=None)
                        raise RuntimeError("Generator changed during acquisition; result rejected")
                    record = {"simulated": self.backend.simulated, "point": index, "sample": sample,
                              "settings": point, "scope": scope, "fpga": fpga,
                              "frequency_error_hz": fpga["frequency_hz"] - float(point["hz"]) if fpga else None,
                              "time": timestamp(), "status": "completed"}
                    atomic_json(sample_dir / "result.json", record)
                    rows.append({"point": index, "sample": sample, **point,
                                 "frequency_error_hz": record["frequency_error_hz"],
                                 "directory": sample_dir.name, "simulated": self.backend.simulated})
                    with (directory / "index.csv").open("w", encoding="utf-8-sig", newline="") as stream:
                        writer = csv.DictWriter(stream, fieldnames=rows[0].keys())
                        writer.writeheader()
                        writer.writerows(rows)
            return {"samples": len(rows), "directory": str(directory)}
        finally:
            self._off()

    def _capture_fpga(self, directory, cancel):
        self._publish("fpga_capture_started", fpga_status="capturing", fpga_result=None)
        try:
            result = self.backend.fpga(directory, cancel)
            self._check_cancel(cancel)
        except BaseException as error:
            self._publish("fpga_capture_failed", fpga_status="cancelled" if isinstance(error, InterruptedError) else "failed",
                          fpga_error=str(error), fpga_result=None)
            raise
        self._publish("fpga_captured", fpga_status="ready", fpga_result=result,
                      fpga_observed_at=timestamp(), fpga_error=None)
        return result

    def _dispatch(self, job, directory):
        action, params, cancel = job["action"], job["params"], job["cancel"]
        self._check_cancel(cancel)
        if action == "connect":
            if self._connected:
                return self._sync()
            identity = self.backend.connect()
            self._connected = True
            self._verified = None
            self._publish("connected", identity=identity, link="connected")
            return self._sync()
        if action == "disconnect":
            try:
                if self._connected:
                    self._off()
            finally:
                self.backend.close()
                self._connected = False
                self._verified = None
                self._publish("disconnected", link="disconnected", generator=None, verified=False)
            return {"disconnected": True}
        if action == "sync":
            return self._sync()
        if action == "output_off":
            return self._off()
        if action == "configure_generator":
            return self._configure(params["point"], params["limits"])
        if action == "set_output":
            return self._output(params["enabled"], params.get("connections_confirmed"))
        if action == "configure_scope":
            config = validate_scope_config(params)
            if not self._connected:
                raise ConnectionError("Instrument not connected")
            # Same single-owner queue; scope writes cannot race a running plan.
            # Do not change the acquisition setup while generator output is ON.
            self._off()
            result = self.backend.configure_scope(config)
            atomic_json(directory / 'scope_config.json', result)
            self._publish('scope_configured', scope_configuration=result,
                          scope_observed_at=timestamp())
            return result
        if action == "capture_scope":
            if not self._connected:
                raise ConnectionError("Instrument not connected")
            channels = params.get("channels", [1])
            if not channels or any(type(ch) is not int or ch not in (1, 2) for ch in channels):
                raise ValueError("channels must select 1/2")
            result = self.backend.scope(channels)
            atomic_json(directory / "scope.json", result)
            return {"file": str(directory / "scope.json")}
        if action == "capture_fpga":
            self.backend.validate_fpga()
            result = self._capture_fpga(directory, cancel)
            atomic_json(directory / "fpga.json", result)
            return result
        if action == "run_plan":
            return self._run_plan(job, directory)
        raise ValueError(action)

    def _fault(self, error):
        off = {"sent": False, "acknowledged": False}
        try:
            if self._connected:
                off = self.backend.emergency_off()
        finally:
            self._audit()
            self.backend.close()
            self._connected = False
            self._verified = None
            with self._condition:
                self._cancel_pending("Connection fault; reconnect explicitly")
                self._publish("connection_fault", link="faulted", generator=None, verified=False,
                              output="off" if off["acknowledged"] else "unknown", last_error=str(error))

    def _execute(self, job):
        directory = self.directory / job["id"]
        directory.mkdir(exist_ok=True)
        result, error, status = None, None, "completed"
        try:
            result = self._dispatch(job, directory)
            self._check_cancel(job["cancel"])
        except BaseException as failure:
            error = f"{type(failure).__name__}: {failure}"
            status = "cancelled" if isinstance(failure, InterruptedError) else "failed"
            self._verified = None
            if self._connected and (job.get("_mutated") or job["action"] == "output_off"):
                try:
                    self._off()
                except Exception as cleanup_error:
                    error += f"; OFF: {cleanup_error}"
                    status = "failed"
            broken = getattr(getattr(self.backend, "device", None), "broken", False)
            if (isinstance(failure, (OSError, ConnectionError)) and not isinstance(failure, InterruptedError)) or broken:
                self._fault(failure)
            elif job["action"] == "connect" and not isinstance(failure, InterruptedError):
                self._fault(failure)
        finally:
            self._audit()
            with self._condition:
                job.update(status=status, result=result, error=error, finished_at=timestamp())
                self._write_job(job)
                self._active = None
                self._publish("job_finished", active_job=None, phase="idle", verified=self._verified is not None,
                              last_error=error, progress=None)
                self._condition.notify_all()

    def _loop(self):
        next_poll = time.monotonic() + self.poll_s
        try:
            while not self._stopping.is_set():
                with self._condition:
                    if not self._pending:
                        self._condition.wait(max(0.01, next_poll - time.monotonic()))
                    if self._stopping.is_set():
                        break
                    identifier = self._pending.popleft() if self._pending else None
                    if identifier:
                        job = self._jobs[identifier]
                        self._active = identifier
                        job.update(status="running", started_at=timestamp())
                        self._publish("job_started", active_job=identifier, phase="running", progress=None)
                if identifier:
                    self._execute(job)
                elif self._connected and time.monotonic() >= next_poll:
                    try:
                        self._sync()
                    except Exception as error:
                        self._fault(error)
                    finally:
                        self._audit()
                next_poll = time.monotonic() + self.poll_s
        except BaseException as error:
            self._publish("worker_failed", phase="failed", last_error=str(error))
        finally:
            try:
                if self._connected:
                    self._off()
            finally:
                self._audit()
                self.backend.close()
                self._connected = False
                self._verified = None
                with self._condition:
                    self._closing = True
                    self._cancel_pending("Controller stopped")
                    if self._active:
                        job = self._jobs[self._active]
                        job.update(status="failed", error="Worker stopped unexpectedly", finished_at=timestamp())
                        self._write_job(job)
                        self._active = None
                    self._publish("stopped", phase="stopped", link="disconnected", generator=None,
                                  verified=False, active_job=None, progress=None)

    def close(self, timeout_s=30):
        with self._condition:
            self._closing = True
            self._stopping.set()
            if self._active:
                self._jobs[self._active]["cancel"].set()
            self._condition.notify_all()
        self._worker.join(timeout_s)
        if self._worker.is_alive():
            raise TimeoutError("Worker is still stopping; do not start another device owner")
