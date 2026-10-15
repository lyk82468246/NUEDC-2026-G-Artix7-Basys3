"""Local asynchronous lab API. Default mode is SIMULATION, no hardware access."""
from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import secrets
import threading
from urllib.parse import parse_qs, urlsplit

from hds242s import ROOT, timestamp
from lab_backend import RealBackend, SimBackend
from lab_controller import Busy, LabController, atomic_json
from resource_lock import ResourceLock


class LabHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, controller, token, port=0):
        self.controller = controller
        self.token = token
        super().__init__(("127.0.0.1", port), Handler)


class Handler(BaseHTTPRequestHandler):
    server_version = "FPGA-Lab/1"

    def log_message(self, *args):
        pass

    def _send(self, code, value):
        data = json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Job continues independently of the client connection.

    def _authorized(self):
        # No browser origins/CORS. Bind is always loopback, token required even
        # for status. Do not offer a route that forwards arbitrary SCPI/shell.
        if self.headers.get("Origin") is not None or not secrets.compare_digest(
                self.headers.get("X-Lab-Token", ""), self.server.token):
            self._send(403, {"error": "Local API token required; browser origins are not accepted"})
            return False
        return True

    def do_GET(self):
        if not self._authorized():
            return
        try:
            uri = urlsplit(self.path)
            controller = self.server.controller
            if uri.path == "/v1/status":
                result = controller.status()
            elif uri.path == "/v1/capabilities":
                result = {"actions": controller.ACTIONS, "simulated": controller.backend.simulated,
                          "poll_s": controller.poll_s, "queue_limit": controller.queue_limit,
                          "scope_optional": True, "nonzero_offset": False,
                          "hardware_mutation_retried": False, "api_version": 1}
            elif uri.path == "/v1/jobs":
                result = controller.jobs()
            elif uri.path.startswith("/v1/jobs/"):
                result = controller.job(uri.path.rsplit("/", 1)[-1])
            elif uri.path == "/v1/events":
                after = int(parse_qs(uri.query).get("after", [0])[0])
                result = controller.events(after)
            else:
                self._send(404, {"error": "Unknown endpoint"})
                return
            self._send(200, result)
        except KeyError as error:
            self._send(404, {"error": str(error)})
        except (ValueError, TypeError) as error:
            self._send(400, {"error": str(error)})

    def do_POST(self):
        if not self._authorized():
            return
        try:
            self.connection.settimeout(3)
            if self.headers.get("Content-Type", "").split(";")[0] != "application/json":
                raise ValueError("Content-Type must be application/json")
            if self.headers.get("Transfer-Encoding"):
                raise ValueError("Chunked requests are not supported")
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 262144:
                raise ValueError("JSON body must be 1..262144 bytes")
            data = self.rfile.read(length)
            if len(data) != length:
                raise ValueError("Incomplete request body")
            body = json.loads(data, parse_constant=lambda value: (_ for _ in ()).throw(ValueError(f"Invalid JSON number {value}")))
            if not isinstance(body, dict):
                raise ValueError("JSON body must be an object")
            controller = self.server.controller
            path = urlsplit(self.path).path
            if path == "/v1/jobs":
                result = controller.submit(body["action"], body.get("params"),
                                           request_id=self.headers.get("Idempotency-Key"))
                self._send(202, result)
            elif path.startswith("/v1/jobs/") and path.endswith("/cancel"):
                identifier = path.split("/")[-2]
                self._send(200, controller.cancel(identifier))
            elif path == "/v1/plan/validate":
                plan = controller._plan(body)
                self._send(200, {"valid": True, "points": len(plan["points"]),
                                 "simulated": controller.backend.simulated})
            elif path == "/v1/shutdown":
                self._send(202, {"shutdown_requested": True})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
            else:
                self._send(404, {"error": "Unknown endpoint"})
        except Busy as error:
            self._send(409, {"error": str(error)})
        except KeyError as error:
            self._send(404 if "/cancel" in self.path else 400, {"error": str(error)})
        except (ValueError, TypeError, OSError) as error:
            self._send(400, {"error": str(error)})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("simulate", "hardware"), default="simulate")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--poll-s", type=float, default=2)
    parser.add_argument("--vivado")
    parser.add_argument("--ltx")
    parser.add_argument("--directory", type=Path)
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error("Invalid TCP port")
    directory = args.directory or ROOT / "test_results" / ("lab_" + timestamp().replace(":", "-") + "_" + secrets.token_hex(3))
    manifest_path = ROOT / "test_results/lab_client.json"
    with ResourceLock(ROOT / ".lab_locks/lab_service.lock"):
        backend = SimBackend() if args.mode == "simulate" else RealBackend(args.vivado, args.ltx)
        controller = LabController(backend, directory, poll_s=args.poll_s)
        server = None
        manifest = None
        try:
            token = secrets.token_urlsafe(32)
            server = LabHTTPServer(controller, token, port=args.port)
            manifest = {"base_url": f"http://127.0.0.1:{server.server_port}", "token": token,
                        "simulated": backend.simulated, "running": True,
                        "directory": str(controller.directory), "started_at": timestamp()}
            atomic_json(manifest_path, manifest)
            print(json.dumps({k: v for k, v in manifest.items() if k != "token"}), flush=True)
            print("Client connection file: test_results/lab_client.json", flush=True)
            server.serve_forever(poll_interval=0.1)
        except KeyboardInterrupt:
            pass
        finally:
            if server:
                server.server_close()
            try:
                controller.close()
            finally:
                if manifest:
                    manifest.update(running=False, stopped_at=timestamp())
                    atomic_json(manifest_path, manifest)


if __name__ == "__main__":
    main()
