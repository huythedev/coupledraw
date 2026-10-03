"""One-time pairing API and recovery tests; no existing pair is required."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import json
import secrets
import threading
import time
import unittest
from unittest.mock import patch
import coupledraw_server as server
import test_whiteboard


class PairingHTTPTests(unittest.TestCase):
    setUp = test_whiteboard.WhiteboardHTTPTests.setUp
    start_server = test_whiteboard.WhiteboardHTTPTests.start_server
    cleanup_resources = test_whiteboard.WhiteboardHTTPTests.cleanup_resources

    def request(self, action, body, *, port=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", port or self.port, timeout=27)
        connection.request("POST", "/v1/pairing/" + action, json.dumps(body),
                           {"Content-Type": "application/json", **(headers or {})})
        response = connection.getresponse()
        raw = response.read()
        result = response.status, json.loads(raw), dict(response.getheaders())
        connection.close()
        return result

    def create(self, secret=None):
        secret = secret or secrets.token_hex(32)
        status, body, _ = self.request("create", {"secret": secret})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["state"], "waiting")
        self.assertRegex(body["code"], r"^[0-9]{6}$")
        self.assertNotIn("credential", body)
        return secret, body

    def state(self, credential, port=None):
        connection = http.client.HTTPConnection("127.0.0.1", port or self.port, timeout=5)
        connection.request("GET", "/v1/state", headers={"Authorization": "Bearer " + credential})
        response = connection.getresponse()
        raw = response.read()
        result = response.status, json.loads(raw)
        connection.close()
        return result

    def test_single_use_code_issues_separate_private_credentials(self):
        creator, invite = self.create()
        with server.connect(self.db_path) as db:
            before = db.execute("SELECT COUNT(*) FROM members").fetchone()[0]
            self.assertEqual(before, 3)  # Existing token pairs remain untouched.
        joiner = secrets.token_hex(32)
        status, joined, _ = self.request("join", {"code": invite["code"], "secret": joiner})
        self.assertEqual((status, joined["state"], joined["role"]), (200, "paired", "B"))
        status, claimed, _ = self.request("status", {"secret": creator})
        self.assertEqual((status, claimed["role"]), (200, "A"))
        self.assertNotEqual(claimed["credential"], joined["credential"])
        for role, credential in [("A", claimed["credential"]), ("B", joined["credential"])]:
            self.assertRegex(credential, r"^[0-9a-f]{64}$")
            self.assertEqual(self.state(credential)[1]["role"], role)
        self.assertEqual(self.request("join", {"code": invite["code"], "secret": secrets.token_hex(32)})[0], 410)
        self.assertEqual(self.request("status", {"secret": secrets.token_hex(32)})[0], 410)
        with server.connect(self.db_path) as db:
            members = db.execute("SELECT token_hash, pair_id, role FROM members WHERE token_hash IN (?, ?)",
                                 tuple(hashlib.sha256(t.encode()).hexdigest() for t in [claimed["credential"], joined["credential"]])).fetchall()
            self.assertEqual(len(members), 2)
            self.assertEqual(members[0][1], members[1][1])
            session = db.execute("SELECT * FROM pairing_sessions").fetchone()
            self.assertNotIn(creator, session)
            self.assertNotIn(joiner, session)
            self.assertNotIn(claimed["credential"], session)
            self.assertNotIn(joined["credential"], session)

    def test_retry_and_restart_return_the_same_pair_without_reusing_code(self):
        creator, invite = self.create()
        self.assertEqual(self.create(creator)[1], invite)
        joiner = secrets.token_hex(32)
        joined = self.request("join", {"code": invite["code"], "secret": joiner})[1]
        other_port = self.start_server()
        self.assertEqual(self.request("join", {"code": invite["code"], "secret": joiner}, port=other_port)[1], joined)
        claimed = self.request("status", {"secret": creator}, port=other_port)[1]
        self.assertEqual(self.request("create", {"secret": creator})[1], claimed)
        self.assertEqual(self.state(claimed["credential"])[0], 200)
        with server.connect(self.db_path) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM members").fetchone()[0], 5)

    def test_concurrent_join_across_processes_has_one_winner(self):
        _, invite = self.create()
        other_port = self.start_server()
        with ThreadPoolExecutor(2) as pool:
            results = list(pool.map(lambda port: self.request("join", {"code": invite["code"], "secret": secrets.token_hex(32)}, port=port),
                                    [self.port, other_port]))
        self.assertEqual(sorted(r[0] for r in results), [200, 410])
        with server.connect(self.db_path) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM members").fetchone()[0], 5)

    def test_creator_wait_wakes_promptly_when_partner_joins(self):
        creator, invite = self.create()
        started = threading.Event()
        def wait():
            started.set()
            return self.request("status", {"secret": creator}, headers={"Prefer": "wait=20"})
        with ThreadPoolExecutor(1) as pool:
            waiting = pool.submit(wait)
            started.wait(timeout=2)
            time.sleep(0.15)
            self.assertFalse(waiting.done())
            start = time.monotonic()
            self.assertEqual(self.request("join", {"code": invite["code"], "secret": secrets.token_hex(32)})[0], 200)
            status, body, _ = waiting.result(timeout=3)
            self.assertLess(time.monotonic() - start, 2)
            self.assertEqual((status, body["role"]), (200, "A"))

    def test_expired_code_cannot_create_members(self):
        creator, invite = self.create()
        with server.connect(self.db_path) as db:
            db.execute("UPDATE pairing_sessions SET expires_at=?", (int(time.time()) - 1,))
        self.assertEqual(self.request("join", {"code": invite["code"], "secret": secrets.token_hex(32)})[0], 410)
        self.assertEqual(self.request("status", {"secret": creator})[0], 410)
        with server.connect(self.db_path) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM members").fetchone()[0], 3)

    def test_cancellation_invalidates_code_but_cannot_destroy_a_joined_pair(self):
        creator, invite = self.create()
        self.assertEqual(self.request("cancel", {"secret": creator})[0], 200)
        self.assertEqual(self.request("join", {"code": invite["code"], "secret": secrets.token_hex(32)})[0], 410)
        creator, invite = self.create()
        joiner = secrets.token_hex(32)
        joined = self.request("join", {"code": invite["code"], "secret": joiner})[1]
        self.assertEqual(self.request("cancel", {"secret": creator})[0], 409)
        self.assertEqual(self.request("cancel", {"secret": joiner})[0], 409)
        self.assertEqual(self.request("status", {"secret": creator})[0], 200)
        self.assertEqual(self.state(joined["credential"])[0], 200)

    def test_failed_guesses_are_limited_across_processes(self):
        other_port = self.start_server()
        # Freeze the minute in persisted limiter rows to avoid a boundary flake.
        with server.connect(self.db_path) as db:
            for window in [int(time.time()) // 60, int(time.time()) // 60 + 1]:
                db.execute("INSERT INTO pairing_limits VALUES (?, ?, ?)", ("join:peer:127.0.0.1", window, 5))
        status, body, headers = self.request("join", {"code": "000000", "secret": secrets.token_hex(32)}, port=other_port)
        self.assertEqual(status, 429)
        self.assertIn("Retry-After", headers)
        self.assertNotIn("credential", body)
        self.assertEqual(self.request("join", {"code": "000001", "secret": secrets.token_hex(32)})[0], 429)

    def test_failed_guess_transactions_preserve_the_attempt_counter(self):
        with patch.object(server.time, "time", return_value=1200):
            for _ in range(5):
                with self.assertRaises(server.PairingError) as error:
                    server.PairingService(self.db_path).handle("join", {"code": "123456", "secret": secrets.token_hex(32)}, "guesser")
                self.assertEqual(error.exception.status, 410)
            with self.assertRaises(server.PairingError) as error:
                server.PairingService(self.db_path).handle("join", {"code": "654321", "secret": secrets.token_hex(32)}, "guesser")
        self.assertEqual(error.exception.status, 429)
        with server.connect(self.db_path) as db:
            self.assertEqual(db.execute("SELECT hits FROM pairing_limits WHERE bucket='join:peer:guesser'").fetchone()[0], 5)

    def test_joined_credentials_work_after_recovery_metadata_expires(self):
        creator, invite = self.create()
        joiner = secrets.token_hex(32)
        joined = self.request("join", {"code": invite["code"], "secret": joiner})[1]
        claimed = self.request("status", {"secret": creator})[1]
        with server.connect(self.db_path) as db:
            db.execute("UPDATE pairing_sessions SET recover_until=?", (int(time.time()) - 1,))
        self.assertEqual(self.request("status", {"secret": creator})[0], 410)
        self.assertEqual(self.state(claimed["credential"])[0], 200)
        self.assertEqual(self.state(joined["credential"])[0], 200)
        with server.connect(self.db_path) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM pairing_sessions").fetchone()[0], 0)

    def test_invalid_requests_and_secrets_are_never_logged(self):
        for obj in [{}, {"secret": "short"}, {"secret": [1]}, {"secret": "a" * 64, "extra": True}]:
            self.assertEqual(self.request("create", obj)[0], 400)
        creator, invite = self.create()
        self.assertEqual(self.request("join", {"secret": creator, "code": invite["code"]})[0], 409)
        self.assertEqual(self.request("join", {"secret": secrets.token_hex(32), "code": "１２３４５６"})[0], 400)
        joiner = secrets.token_hex(32)
        joined = self.request("join", {"secret": joiner, "code": invite["code"]})[1]
        claimed = self.request("status", {"secret": creator})[1]
        self.log.flush()
        self.log.seek(0)
        logs = self.log.read()
        self.assertIn("/v1/pairing/create", logs)
        for private in [creator, joiner, invite["code"], joined["credential"], claimed["credential"]]:
            self.assertNotIn(private, logs)

    def test_code_collisions_are_retried_and_abandoned_sessions_are_bounded(self):
        service = server.PairingService(self.db_path)
        with patch.object(server.secrets, "randbelow", side_effect=[123456, 123456, 654321]):
            first = service.handle("create", {"secret": secrets.token_hex(32)}, "first")
            second = service.handle("create", {"secret": secrets.token_hex(32)}, "second")
        self.assertEqual((first["code"], second["code"]), ("123456", "654321"))
        with patch.object(server, "MAX_PAIRING_SESSIONS", 2):
            with self.assertRaises(server.PairingError) as error:
                service.handle("create", {"secret": secrets.token_hex(32)}, "third")
        self.assertEqual(error.exception.status, 429)


if __name__ == "__main__":
    unittest.main()
