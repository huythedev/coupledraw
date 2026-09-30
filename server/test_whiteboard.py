"""HTTP integration tests: python3 -m unittest discover -s server -v

The server treats PencilKit archives as opaque bytes. Device XCTest covers the
actual strokes; these tests exercise protocol, concurrency and persistence.
"""
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import coupledraw_server as server


def stroke(ident, content=None):
    return {"id": ident, "drawingData": base64.b64encode((content or ident).encode()).decode(), "drawingHeight": 844}


class WhiteboardHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db_path = str(Path(self.temp.name) / "test.sqlite3")
        self.log = open(Path(self.temp.name) / "server.log", "w+")
        self.tokens = {role: "test-token-private-" + role for role in ("A", "B", "other")}
        with server.connect(self.db_path) as db:
            for role, token in self.tokens.items():
                db.execute("INSERT INTO members VALUES (?, ?, ?)",
                           (hashlib.sha256(token.encode()).hexdigest(), "pair" if role != "other" else "other", "A" if role == "other" else role))
        self.processes = []
        self.port = self.start_server()

    def start_server(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        env = {k: v for k, v in os.environ.items() if not k.startswith(("APNS_", "NTFY_"))}
        process = subprocess.Popen([sys.executable, str(Path(server.__file__)), "serve", "--db", self.db_path, "--port", str(port)],
                                   stdout=self.log, stderr=self.log, env=env)
        self.processes.append(process)
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    return port
            except OSError:
                if process.poll() is not None:
                    self.fail("Test server did not start")
                time.sleep(0.02)
        self.fail("Test server timed out")

    def tearDown(self):
        for process in self.processes:
            process.terminate()
            process.wait(timeout=5)
        self.log.close()
        self.temp.cleanup()

    def request(self, method, route, body=None, role="A", headers=None, port=None):
        connection = http.client.HTTPConnection("127.0.0.1", port or self.port, timeout=27)
        all_headers = {"Authorization": "Bearer " + self.tokens[role]}
        all_headers.update(headers or {})
        encoded = json.dumps(body).encode() if body is not None else None
        connection.request(method, route, body=encoded, headers=all_headers)
        response = connection.getresponse()
        raw = response.read()
        result = response.status, json.loads(raw) if raw else None, dict(response.getheaders())
        connection.close()
        return result

    def seed(self, strokes=None):
        _, state, _ = self.request("GET", "/v1/state")
        status, board, _ = self.request("POST", "/v1/board/seed", {"seedTag": state["boardSeedTag"], "strokes": strokes or []})
        self.assertEqual(status, 200)
        return board

    def edit(self, ident, added=(), removed=(), role="A", **kwargs):
        return self.request("POST", "/v1/board/ops", {"id": ident, "add": list(added), "remove": list(removed)}, role, **kwargs)

    def test_concurrent_additions_and_idempotent_retry(self):
        self.seed()
        with ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda role: self.edit("op-" + role, [stroke(role)], role=role), ["A", "B"]))
        self.assertEqual([r[0] for r in results], [200, 200])
        _, state, _ = self.request("GET", "/v1/state")
        self.assertEqual(state["board"]["revision"], 3)
        self.assertEqual({s["id"] for s in state["board"]["strokes"]}, {"A", "B"})
        code, board, _ = self.edit("op-A", [stroke("A")])
        self.assertEqual((code, board["revision"]), (200, 3))
        self.assertEqual(self.edit("op-A", [stroke("different")])[0], 409)
        other = self.request("GET", "/v1/state", role="other")[1]
        self.assertIsNone(other["board"])

    def test_partner_can_move_erase_and_conflicting_move_is_rejected(self):
        self.seed([stroke("original")])
        code, board, _ = self.edit("move-B", [stroke("moved")], ["original"], role="B")
        self.assertEqual(code, 200)
        code, conflict, _ = self.edit("move-A", [stroke("stale-move")], ["original"])
        self.assertEqual(code, 409)
        self.assertEqual([s["id"] for s in conflict["board"]["strokes"]], ["moved"])
        code, board, _ = self.edit("erase", removed=["moved"])
        self.assertEqual((code, board["strokes"]), (200, []))
        self.assertEqual(self.edit("reuse", [stroke("original")])[0], 409)

    def test_clear_does_not_erase_unseen_concurrent_strokes(self):
        self.seed([stroke("old")])
        self.edit("new", [stroke("new")], role="B")
        code, board, _ = self.edit("clear", removed=["old"])
        self.assertEqual(code, 200)
        self.assertEqual([s["id"] for s in board["strokes"]], ["new"])

    def test_delta_and_long_poll_wake_across_server_processes(self):
        self.seed([stroke("old")])
        other_port = self.start_server()
        _, state, headers = self.request("GET", "/v1/state", role="B")
        etag = headers["ETag"]
        with ThreadPoolExecutor(1) as pool:
            start = time.monotonic()
            future = pool.submit(self.request, "GET", "/v1/state", None, "B",
                                 {"If-None-Match": etag, "Prefer": "wait=20", "X-CoupleDraw-Board": "1"})
            time.sleep(0.15)
            self.edit("move", [stroke("new")], ["old"], port=other_port)
            status, changed, _ = future.result(timeout=4)
        self.assertEqual(status, 200)
        self.assertLess(time.monotonic() - start, 3)
        self.assertEqual(changed["board"]["baseRevision"], 1)
        self.assertEqual(changed["board"]["removed"], ["old"])
        self.assertEqual([s["id"] for s in changed["board"]["strokes"]], ["new"])
        _, _, headers = self.request("GET", "/v1/state")
        start = time.monotonic()
        status, empty, response_headers = self.request("GET", "/v1/state", headers={"If-None-Match": headers["ETag"], "Prefer": "wait=1"})
        self.assertEqual((status, empty), (304, None))
        self.assertGreater(time.monotonic() - start, 0.9)
        self.assertEqual(response_headers["X-CoupleDraw-Long-Poll"], "1")

    def test_apply_checks_board_and_snapshot_revisions(self):
        self.seed([stroke("first")])
        body = {"source": "together", "expectedRevision": 0, "boardRevision": 1,
                "backgroundHex": "#000000", "backgroundPhoto": None,
                "drawingData": stroke("opaque-combined")["drawingData"], "drawingHeight": 844}
        self.edit("second", [stroke("second")], role="B")
        self.assertEqual(self.request("POST", "/v1/apply", body)[0], 409)
        body["boardRevision"] = 2
        status, saved, _ = self.request("POST", "/v1/apply", body)
        self.assertEqual((status, saved["revision"]), (200, 1))
        partner = self.request("GET", "/v1/state", role="B")[1]
        self.assertEqual(partner["items"], [saved])
        self.assertEqual(self.request("POST", "/v1/apply", body, role="B")[0], 409)
        self.assertEqual(self.request("POST", "/v1/draft", {"drawingData": stroke("old")["drawingData"], "drawingHeight": 844})[0], 409)

    def test_migration_is_guarded_and_only_seeds_once(self):
        _, first, _ = self.request("GET", "/v1/state")
        draft = {"drawingData": stroke("legacy")["drawingData"], "drawingHeight": 844}
        self.assertEqual(self.request("POST", "/v1/draft", draft)[0], 200)
        self.assertEqual(self.request("POST", "/v1/board/seed", {"seedTag": first["boardSeedTag"], "strokes": []})[0], 409)
        _, latest, _ = self.request("GET", "/v1/state")
        body = {"seedTag": latest["boardSeedTag"], "strokes": [stroke("legacy")]}
        with ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda role: self.request("POST", "/v1/board/seed", body, role), ["A", "B"]))
        self.assertTrue(all(r[0] == 200 and r[1]["revision"] == 1 and len(r[1]["strokes"]) == 1 for r in results))
        # Persistence survives a service restart.
        self.processes[0].terminate(); self.processes[0].wait(timeout=5)
        self.port = self.start_server()
        self.assertEqual(self.request("GET", "/v1/state")[1]["board"]["strokes"], [stroke("legacy")])

    def test_malformed_and_unauthorized_requests(self):
        self.seed()
        self.assertEqual(self.edit("bad", [dict(stroke("bad"), drawingHeight=float("nan"))])[0], 400)
        self.assertEqual(self.edit("bad", removed=[{}])[0], 400)
        self.assertEqual(self.edit("bad", [stroke("dup"), stroke("dup")])[0], 400)
        self.assertEqual(self.request("POST", "/v1/board/ops", {"id": "none", "add": [], "remove": []}, headers={"Authorization": "Bearer invalid"})[0], 401)

    def photo(self, content="photo"):
        return {"data": base64.b64encode(b"\xff\xd8" + content.encode()).decode(),
                "zoom": 1, "offsetX": 0, "offsetY": 0, "rotation": 0}

    def apply_art(self, source, revision, photo=None, role="A", stickers=None):
        return self.request("POST", "/v1/apply",
                            {"source": source, "expectedRevision": revision,
                             "backgroundHex": "#000000", "backgroundPhoto": photo,
                             "drawingData": stroke("snapshot")["drawingData"], "drawingHeight": 844,
                             "stickers": stickers or []}, role=role)

    def test_media_is_deduplicated_kept_for_offline_partner_and_old_files_pruned(self):
        photo = self.photo()
        self.assertEqual(self.apply_art("a", 0, photo)[0], 200)
        self.assertEqual(self.apply_art("b", 0, photo, role="B")[0], 200)
        media = server.MediaFiles(self.db_path)
        self.assertEqual(len(list(media.root.glob("*.image"))), 1)
        with server.connect(self.db_path) as db:
            bodies = [json.loads(row[0]) for row in db.execute("SELECT body FROM snapshots")]
        self.assertTrue(all("data" not in body["backgroundPhoto"] for body in bodies))
        # The partner may fetch later, after the publishing phone is gone.
        state = self.request("GET", "/v1/state", role="B")[1]
        self.assertTrue(all(item["backgroundPhoto"] == photo for item in state["items"]))
        self.assertEqual(self.request("GET", "/v1/state", role="other")[1]["items"], [])
        self.assertEqual(self.apply_art("a", 1, self.photo("new"))[0], 200)
        self.assertEqual(len(list(media.root.glob("*.image"))), 2)  # B still uses the original.
        self.assertEqual(self.apply_art("b", 1, role="B")[0], 200)
        self.assertEqual(len(list(media.root.glob("*.image"))), 1)
        self.assertEqual(self.apply_art("a", 1, self.photo("conflict"))[0], 409)
        self.assertEqual(len(list(media.root.glob("*.image"))), 1)
        self.assertEqual(self.apply_art("a", 2)[0], 200)
        self.assertEqual(list(media.root.glob("*.image")), [])

    def test_inline_media_migrates_on_restart_without_changing_wire_snapshot(self):
        self.processes[0].terminate(); self.processes[0].wait(timeout=5)
        body = {"source": "a", "revision": 1, "author": "A", "backgroundHex": "#000000",
                "backgroundPhoto": self.photo("legacy"), "drawingData": "", "drawingHeight": 844}
        with server.connect(self.db_path) as db:
            db.execute("INSERT INTO snapshots VALUES (?, ?, ?, ?)", ("pair", "a", 1, json.dumps(body)))
        self.port = self.start_server()
        self.assertEqual(self.request("GET", "/v1/state", role="B")[1]["items"], [body])
        with server.connect(self.db_path) as db:
            stored = json.loads(db.execute("SELECT body FROM snapshots").fetchone()[0])
        self.assertIn("mediaID", stored["backgroundPhoto"])
        self.assertNotIn("data", stored["backgroundPhoto"])
        self.processes[-1].terminate(); self.processes[-1].wait(timeout=5)
        self.port = self.start_server()
        self.assertEqual(self.request("GET", "/v1/state", role="B")[1]["items"], [body])

    def test_stickers_round_trip_and_invalid_media_cannot_replace_saved_art(self):
        sticker = {"id": "11111111-1111-1111-1111-111111111111",
                   "data": base64.b64encode(b"\x89PNG\r\n\x1a\nopaque-test").decode(),
                   "centerX": 0.3, "centerY": 0.7, "width": 0.15, "rotation": -32}
        status, saved, _ = self.apply_art("a", 0, stickers=[sticker])
        self.assertEqual(status, 200)
        self.assertEqual(self.request("GET", "/v1/state", role="B")[1]["items"], [saved])
        with server.connect(self.db_path) as db:
            stored = json.loads(db.execute("SELECT body FROM snapshots").fetchone()[0])
        self.assertNotIn("data", stored["stickers"][0])
        for invalid in [dict(sticker, width=-1), dict(sticker, rotation=float("nan")),
                        dict(sticker, data=base64.b64encode(b"not-an-image").decode())]:
            self.assertEqual(self.apply_art("a", 1, stickers=[invalid])[0], 400)
        self.assertEqual(self.request("GET", "/v1/state", role="B")[1]["items"], [saved])

    def test_missing_photo_reports_an_error_but_unchanged_snapshots_need_no_media_read(self):
        self.apply_art("a", 0, self.photo())
        for file in server.MediaFiles(self.db_path).root.glob("*.image"):
            file.unlink()
        self.assertEqual(self.request("GET", "/v1/state", role="B")[0], 503)
        status, state, _ = self.request("GET", "/v1/state", role="B",
                                        headers={"X-CoupleDraw-Snapshots": "a:1"})
        self.assertEqual((status, state["items"]), (200, []))


if __name__ == "__main__":
    unittest.main()
