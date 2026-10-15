"""Small Python/CLI client for the local lab service. POSTs are never retried."""
import argparse
import json
from pathlib import Path
import time
from urllib.error import HTTPError
from urllib.request import Request, ProxyHandler, build_opener
from urllib.parse import urlsplit
import uuid

from hds242s import ROOT


class LabClient:
    def __init__(self, manifest=None, timeout_s=3):
        manifest = manifest or ROOT / "test_results/lab_client.json"
        config = json.loads(Path(manifest).read_text(encoding="utf-8"))
        if not config.get("running"):
            raise RuntimeError("Lab service is stopped; start lab_server.py first")
        self.base_url = config["base_url"]
        uri = urlsplit(self.base_url)
        if (uri.scheme != "http" or uri.hostname != "127.0.0.1" or uri.port is None
                or uri.username or uri.password or uri.path or uri.query or uri.fragment):
            raise ValueError("Client only accepts loopback service URLs")
        self.opener = build_opener(ProxyHandler({}))
        self.token = config["token"]
        self.timeout_s = timeout_s

    def request(self, path, body=None, request_id=None):
        headers = {"X-Lab-Token": self.token}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if request_id:
            headers["Idempotency-Key"] = request_id
        request = Request(self.base_url + path,
                          data=None if body is None else json.dumps(body, allow_nan=False).encode(),
                          headers=headers)
        try:
            with self.opener.open(request, timeout=self.timeout_s) as response:
                return json.load(response)
        except HTTPError as error:
            details = json.loads(error.read())
            raise RuntimeError(f"HTTP {error.code}: {details.get('error', details)}") from error

    def status(self):
        return self.request("/v1/status")

    def submit(self, action, params=None, request_id=None):
        return self.request("/v1/jobs", {"action": action, "params": params or {}}, request_id or uuid.uuid4().hex)

    def job(self, identifier):
        return self.request("/v1/jobs/" + identifier)

    def cancel(self, identifier):
        return self.request("/v1/jobs/" + identifier + "/cancel", {})

    def wait(self, identifier, timeout_s=120):
        deadline = time.monotonic() + timeout_s
        while True:
            result = self.job(identifier)
            if result["status"] in ("completed", "failed", "cancelled"):
                return result
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"Client wait expired; job {identifier} is NOT cancelled. Inspect or cancel it explicitly.")
            time.sleep(min(0.1, remaining))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("status", "capabilities", "jobs", "stop", "shutdown"):
        sub.add_parser(command)
    for command in ("job", "cancel", "wait"):
        item = sub.add_parser(command)
        item.add_argument("id")
        if command == "wait":
            item.add_argument("--timeout-s", type=float, default=120)
    events = sub.add_parser("events")
    events.add_argument("--after", type=int, default=0)
    submit = sub.add_parser("submit")
    submit.add_argument("action")
    submit.add_argument("--params", type=Path, help="JSON params file, not the entire job envelope")
    submit.add_argument("--request-id")
    args = parser.parse_args()
    client = LabClient(args.manifest)
    if args.command == "status":
        result = client.status()
    elif args.command == "capabilities":
        result = client.request("/v1/capabilities")
    elif args.command == "jobs":
        result = client.request("/v1/jobs")
    elif args.command == "events":
        result = client.request(f"/v1/events?after={args.after}")
    elif args.command == "job":
        result = client.job(args.id)
    elif args.command == "cancel":
        result = client.cancel(args.id)
    elif args.command == "wait":
        result = client.wait(args.id, args.timeout_s)
    elif args.command == "stop":
        result = client.submit("output_off")
    elif args.command == "shutdown":
        result = client.request("/v1/shutdown", {})
    else:
        params = json.loads(args.params.read_text(encoding="utf-8-sig")) if args.params else {}
        result = client.submit(args.action, params, args.request_id)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
