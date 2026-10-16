"""One-shot SIMULATED HTTP/FPGA workflow, no equipment or wiring required."""
import json
import secrets
import threading

from hds242s import output_dir
from lab_backend import SimBackend
from lab_client import LabClient
from lab_controller import LabController, atomic_json
from lab_server import LabHTTPServer


def main():
    directory = output_dir(None)
    controller = LabController(SimBackend(), directory, poll_s=.2)
    token = secrets.token_urlsafe(32)
    server = LabHTTPServer(controller, token)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .02}, daemon=True)
    thread.start()
    manifest = directory / "demo_client.json"
    atomic_json(manifest, {"running": True, "simulated": True,
                          "base_url": f"http://127.0.0.1:{server.server_port}", "token": token})
    client = LabClient(manifest)
    try:
        if not client.status()["simulated"]:
            raise RuntimeError("Demo refuses real hardware")
        connected = client.submit("connect")
        if client.wait(connected["id"], 5)["status"] != "completed":
            raise RuntimeError("Simulated connect failed")
        plan = {"connections_confirmed": True,
                "limits": {"max_vpp": .1, "min_output_v": -.05, "max_output_v": .05},
                "load": "HIGHZ", "settle_s": 1, "scope_channels": [],
                "capture_fpga": True, "samples_per_point": 2,
                "points": [{"hz": hz, "vpp": .1, "offset_v": 0} for hz in (50000, 100000, 200000)]}
        submitted = client.submit("run_plan", {"plan": plan})
        result = client.wait(submitted["id"], 15)
        final_state = client.status()
        if result["status"] != "completed" or final_state["output"] != "off":
            raise RuntimeError(f"Simulated plan failed: {result}")
        summary = {"simulated": True, "job": result, "final_state": final_state,
                   "message": "SIMULATION ONLY: no USB, signal output, JTAG or physical measurement"}
        atomic_json(directory / "demo_summary.json", summary)
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        print(f"SIMULATION results: {directory}")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(2)
        controller.close()
        atomic_json(manifest, {"running": False, "simulated": True})


if __name__ == "__main__":
    main()
