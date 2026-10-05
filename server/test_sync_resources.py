"""Read/write contention, pair wakeups and bounded whiteboard history."""
from concurrent.futures import ThreadPoolExecutor
import time
import unittest
from unittest.mock import patch
import coupledraw_server as server
import test_whiteboard
import test_media_relay


class SyncResourceHTTPTests(unittest.TestCase):
    setUp = test_whiteboard.WhiteboardHTTPTests.setUp
    start_server = test_whiteboard.WhiteboardHTTPTests.start_server
    cleanup_resources = test_whiteboard.WhiteboardHTTPTests.cleanup_resources
    request = test_whiteboard.WhiteboardHTTPTests.request
    seed = test_whiteboard.WhiteboardHTTPTests.seed

    def modern(self, role="A"):
        return self.request("GET", "/v1/state", role=role,
                            headers={"X-CoupleDraw-Board-History": "1"})

    def operation(self, ident, base, add=(), remove=(), **kwargs):
        return self.request("POST", "/v1/board/ops",
                            {"id": ident, "baseRevision": base, "add": list(add), "remove": list(remove)}, **kwargs)

    def test_warm_state_reads_and_etag_checks_do_not_wait_for_sqlite_writer(self):
        self.seed([test_whiteboard.stroke("kept")])
        self.modern("A")
        _, _, headers = self.modern("B")
        with server.connect(self.db_path, initialize=False) as writer:
            writer.execute("BEGIN IMMEDIATE")
            start = time.monotonic()
            status, state, _ = self.modern("B")
            self.assertEqual(status, 200)
            self.assertEqual(state["board"]["strokes"][0]["id"], "kept")
            status, _, _ = self.request("GET", "/v1/state", role="B",
                                        headers={"If-None-Match": headers["ETag"], "Prefer": "wait=1", "X-CoupleDraw-Board-History": "1"})
            self.assertEqual(status, 304)
            self.assertLess(time.monotonic() - start, 2.5)

    def test_gc_needs_both_capabilities_and_rejects_forgotten_replays(self):
        self.seed()
        self.modern("A")
        first = test_whiteboard.stroke("first")
        self.assertEqual(self.operation("add-first", 1, [first])[0], 200)
        self.assertEqual(self.operation("erase-first", 2, remove=["first"])[0], 200)
        self.assertEqual(self.operation("add-kept", 3, [test_whiteboard.stroke("kept")])[0], 200)
        with patch.object(server, "BOARD_MAX_OPERATIONS", 1):
            with server.connect(self.db_path, initialize=False) as db:
                db.execute("BEGIN IMMEDIATE")
                server.compact_board(db, "pair", 4)
                self.assertEqual(db.execute("SELECT COUNT(*) FROM board_operations").fetchone()[0], 3)
        self.modern("B")
        with patch.object(server, "BOARD_MAX_OPERATIONS", 1):
            with server.connect(self.db_path, initialize=False) as db:
                db.execute("BEGIN IMMEDIATE")
                server.compact_board(db, "pair", 4)
                self.assertEqual(db.execute("SELECT minimum_revision FROM board_history").fetchone()[0], 3)
                self.assertEqual(db.execute("SELECT id FROM board_strokes").fetchall(), [("kept",)])
                self.assertEqual(db.execute("SELECT id FROM board_operations").fetchall(), [("add-kept",)])
        status, conflict, _ = self.operation("add-first", 1, [first])
        self.assertEqual((status, conflict["code"]), (409, "history_compacted"))
        self.assertEqual([s["id"] for s in conflict["board"]["strokes"]], ["kept"])
        # A forgotten legacy request cannot bypass the checkpoint either.
        self.assertEqual(self.request("POST", "/v1/board/ops", {"id": "legacy", "add": [first], "remove": []})[0], 409)
        self.assertEqual(self.operation("add-kept", 3, [test_whiteboard.stroke("kept")])[0], 200)
        _, state, _ = self.request("GET", "/v1/state", headers={"X-CoupleDraw-Board": "1"})
        self.assertIsNone(state["board"]["baseRevision"])
        self.assertEqual(state["board"]["minimumRevision"], 3)

    def test_tombstone_bound_and_revision_window_preserve_active_strokes(self):
        self.seed([test_whiteboard.stroke("one"), test_whiteboard.stroke("two"), test_whiteboard.stroke("kept")])
        self.modern("A"); self.modern("B")
        self.operation("erase-one", 1, remove=["one"])
        self.operation("erase-two", 2, remove=["two"])
        with patch.object(server, "BOARD_MAX_TOMBSTONES", 1):
            with server.connect(self.db_path, initialize=False) as db:
                db.execute("BEGIN IMMEDIATE")
                server.compact_board(db, "pair", 3)
                self.assertEqual(db.execute("SELECT id FROM board_strokes ORDER BY id").fetchall(), [("kept",), ("two",)])
        with patch.object(server, "BOARD_HISTORY_REVISIONS", 0):
            with server.connect(self.db_path, initialize=False) as db:
                db.execute("BEGIN IMMEDIATE")
                server.compact_board(db, "pair", 3)
                self.assertEqual(db.execute("SELECT id FROM board_strokes").fetchall(), [("kept",)])
                self.assertEqual(db.execute("SELECT COUNT(*) FROM board_operations").fetchone()[0], 0)

    def test_legacy_digest_migration_keeps_the_recent_operation_idempotent(self):
        self.seed()
        self.operation("legacy-add", 1, [test_whiteboard.stroke("kept")])
        with server.connect(self.db_path, initialize=False) as db:
            db.execute("DELETE FROM board_operation_history")
        with server.connect(self.db_path) as db:
            self.assertEqual(db.execute("SELECT revision FROM board_operation_history").fetchone()[0], 2)
        self.assertEqual(self.operation("legacy-add", 1, [test_whiteboard.stroke("kept")])[1]["revision"], 2)


class MediaReadLockTests(unittest.TestCase):
    setUp = test_whiteboard.WhiteboardHTTPTests.setUp
    start_server = test_whiteboard.WhiteboardHTTPTests.start_server
    cleanup_resources = test_whiteboard.WhiteboardHTTPTests.cleanup_resources
    request = test_whiteboard.WhiteboardHTTPTests.request
    seed = test_whiteboard.WhiteboardHTTPTests.seed
    files = test_media_relay.MediaRelayHTTPTests.files
    photo = staticmethod(test_media_relay.MediaRelayHTTPTests.photo)
    apply = test_media_relay.MediaRelayHTTPTests.apply
    state = test_media_relay.MediaRelayHTTPTests.state
    ack = test_media_relay.MediaRelayHTTPTests.ack
    receipt = test_media_relay.MediaRelayHTTPTests.receipt

    def test_shared_file_lease_blocks_prune_but_not_stroke_writes(self):
        self.seed()
        self.apply(photo=self.photo())
        receipt = self.receipt()
        self.ack(receipt, "A")
        media = server.MediaFiles(self.db_path)
        with ThreadPoolExecutor(1) as pool:
            with media.access():
                future = pool.submit(self.ack, receipt, "B")
                time.sleep(0.15)
                self.assertFalse(future.done())
                with server.read_connection(self.db_path) as db:
                    db.execute("BEGIN")
                    body = db.execute("SELECT body FROM snapshots WHERE source='a'").fetchone()[0]
                    self.assertIn("mediaID", body)
                    self.assertTrue(media.path(receipt["mediaIDs"][0]).read_bytes())
                status, _, _ = self.request("POST", "/v1/board/ops",
                                            {"id": "write-with-reader", "add": [test_whiteboard.stroke("new")], "remove": []})
                self.assertEqual(status, 200)
                self.assertEqual(len(self.files()), 1)
            self.assertGreater(future.result(timeout=3)["removedBytes"], 0)
        self.assertEqual(self.files(), [])

    def test_shortcut_state_skips_unselected_vectors_but_keeps_all_originals(self):
        self.seed([test_whiteboard.stroke("board")])
        self.apply(source="a", photo=self.photo(b"A"))
        self.apply(source="b", photo=self.photo(b"B"), role="B")
        state, _ = self.state("A", **{"X-CoupleDraw-Wallpaper": "partner"})
        self.assertEqual([s["source"] for s in state["items"]], ["b"])
        self.assertNotEqual(state["items"][0]["drawingData"], "")
        self.assertEqual([s["source"] for s in state["mediaOnlyItems"]], ["a"])
        self.assertEqual(state["mediaOnlyItems"][0]["drawingData"], "")
        self.assertEqual(state["mediaOnlyItems"][0]["backgroundPhoto"]["data"], self.photo(b"A")["data"])
        self.assertEqual(len(state["mediaInventory"]), 2)
        self.assertEqual(state["drafts"], [])
        self.assertIsNone(state["board"])
        state, _ = self.state("B", **{"X-CoupleDraw-Wallpaper": "own"})
        self.assertEqual([s["source"] for s in state["items"]], ["b"])
        self.assertEqual(len(self.state("B")[0]["items"]), 2)


class PairEventTests(unittest.TestCase):
    def test_pair_wakeups_are_scoped_and_a_notify_before_wait_is_not_lost(self):
        events = server.PairEvents()
        with events.watch("first") as first, events.watch("second") as second:
            version = first.version()
            events.notify("first")
            start = time.monotonic()
            first.wait(version, 0.5)
            self.assertLess(time.monotonic() - start, 0.1)
            self.assertEqual(second.version(), 0)
            with events.watch("first") as same:
                self.assertIs(same, first)
                self.assertEqual(first.users, 2)
            self.assertEqual(first.users, 1)
        self.assertEqual(events.signals, {})
        events.notify("absent")
        self.assertEqual(events.signals, {})


if __name__ == "__main__":
    unittest.main()
