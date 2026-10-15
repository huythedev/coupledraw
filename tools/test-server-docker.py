#!/usr/bin/env python3
"""Build and smoke-test Compose using an isolated, disposable project/volume."""
import base64
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
from urllib.request import Request, urlopen


def main():
    root = Path(__file__).resolve().parents[1]
    project = "coupledraw-smoke-" + secrets.token_hex(6)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    env = {**os.environ, "COUPLEDRAW_BIND_IP": "127.0.0.1",
           "COUPLEDRAW_PORT": str(port), "COUPLEDRAW_IMAGE": project + ":test"}
    compose = ["docker", "compose", "--project-name", project,
               "--file", str(root / "compose.yaml")]

    def run(*args, capture=False):
        return subprocess.run([*compose, *args], cwd=root, env=env, check=True,
                              text=True, capture_output=capture)

    def request(path, body=None, token=None):
        headers = {"Content-Type": "application/json", "X-CoupleDraw-Media": "2"}
        if token:
            headers["Authorization"] = "Bearer " + token
        data = None if body is None else json.dumps(body).encode()
        with urlopen(Request(f"http://127.0.0.1:{port}" + path, data, headers), timeout=5) as response:
            return json.load(response)

    try:
        run("config", "--quiet")
        run("up", "--build", "--detach", "--wait", "--wait-timeout", "120")
        # Verify the actual image user, APNs dependencies and data permissions.
        run("exec", "-T", "backend", "python", "-c",
            "import os, stat, httpx, cryptography; "
            "assert os.getuid() == 10001; "
            "assert stat.S_IMODE(os.stat('/data/coupledraw.sqlite3').st_mode) == 0o600")
        request("/v1/capabilities")
        creator = secrets.token_hex(32)
        invite = request("/v1/pairing/create", {"secret": creator})
        joined = request("/v1/pairing/join", {"code": invite["code"], "secret": secrets.token_hex(32)})
        claimed = request("/v1/pairing/status", {"secret": creator})
        photo = {"data": base64.b64encode(b"\xff\xd8docker-smoke-photo").decode(),
                 "zoom": 1, "offsetX": 0, "offsetY": 0}
        drawing = base64.b64encode(b"docker-smoke-drawing").decode()
        request("/v1/apply", {"source": "a", "expectedRevision": 0, "backgroundHex": "#123456",
                              "backgroundPhoto": photo, "stickers": [], "drawingData": drawing,
                              "drawingHeight": 844}, claimed["credential"])
        # Recreate, rather than merely restart, to catch data left in the container.
        run("up", "--detach", "--force-recreate", "--wait", "--wait-timeout", "120")
        state = request("/v1/state", token=joined["credential"])
        assert state["role"] == "B", "Pair credentials did not survive recreation"
        item = next(item for item in state["items"] if item["source"] == "a")
        assert item["revision"] == 1 and item["drawingData"] == drawing, "Drawing did not persist"
        assert item["backgroundPhoto"]["data"] == photo["data"], "Pending media did not persist"
        run("stop", "backend")
        run("run", "--rm", "--no-deps", "backend", "compact", "--db", "/data/coupledraw.sqlite3")
        print("Docker smoke test passed: health, non-root user, APNs imports, pairing, drawing/media persistence, compact.")
    except BaseException:
        subprocess.run([*compose, "logs", "--no-color"], cwd=root, env=env, check=False)
        raise
    finally:
        # Only delete the randomly named project and volume created by this test.
        subprocess.run([*compose, "down", "--volumes", "--remove-orphans"], cwd=root, env=env, check=False)


if __name__ == "__main__":
    main()
