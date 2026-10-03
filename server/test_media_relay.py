"""Temporary originals: durable receipts, revision races and authenticated recovery."""
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
from pathlib import Path
import time
import unittest
import coupledraw_server as server
import test_whiteboard


class MediaRelayHTTPTests(unittest.TestCase):
    setUp = test_whiteboard.WhiteboardHTTPTests.setUp
    start_server = test_whiteboard.WhiteboardHTTPTests.start_server
    cleanup_resources = test_whiteboard.WhiteboardHTTPTests.cleanup_resources
    request = test_whiteboard.WhiteboardHTTPTests.request
    seed = test_whiteboard.WhiteboardHTTPTests.seed

    def files(self):
        return list(Path(self.db_path + ".media").glob("*.image"))

    @staticmethod
    def photo(content=b"original"):
        return {"data": base64.b64encode(b"\xff\xd8" + content).decode(),
                "zoom": 0.7, "offsetX": 0.1, "offsetY": -0.2, "rotation": 23}

    def apply(self, source="a", expected=0, photo=None, role="A", stickers=None):
        body = {"source": source, "expectedRevision": expected, "backgroundHex": "#123456",
                "backgroundPhoto": photo, "stickers": stickers or [],
                "drawingData": base64.b64encode(b"unchanged-PencilKit-archive").decode(), "drawingHeight": 844}
        status, result, headers = self.request("POST", "/v1/apply", body, role,
                                              {"X-CoupleDraw-Media": "2"})
        self.assertEqual(status, 200, result)
        self.assertEqual(headers["X-CoupleDraw-Media"], "2")
        return result

    def state(self, role="A", **headers):
        status, body, response = self.request("GET", "/v1/state", role=role,
                                             headers={"X-CoupleDraw-Media": "2", **headers})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["mediaProtocol"], 2)
        return body, response

    def ack(self, receipt, role="A", **kwargs):
        status, body, _ = self.request("POST", "/v1/media/ack", {"receipts": [receipt]}, role, **kwargs)
        self.assertEqual(status, 200, body)
        return body

    def receipt(self, source="a", role="A"):
        return next(item for item in self.state(role)[0]["mediaInventory"] if item["source"] == source)

    def test_downloads_are_not_receipts_and_originals_delete_only_after_both_phones(self):
        photo = self.photo()
        sticker = {"id": "01234567-89ab-cdef-0123-456789abcdef",
                   "data": base64.b64encode(b"\x89PNG\r\n\x1a\nsticker").decode(),
                   "centerX": 0.3, "centerY": 0.6, "width": 0.2, "rotation": -35}
        applied = self.apply(photo=photo, stickers=[sticker])
        received, _ = self.state("B")
        self.assertEqual(received["items"][0]["backgroundPhoto"]["data"], photo["data"])
        self.state("B", **{"X-CoupleDraw-Snapshots": "a:1"})
        receipt = received["mediaInventory"][0]
        self.assertEqual(len(self.files()), 2)
        self.ack(receipt, "A")
        self.assertEqual(len(self.files()), 2)
        partial = {**receipt, "mediaIDs": receipt["mediaIDs"][:1]}
        self.assertEqual(self.ack(partial, "B")["accepted"], [])
        self.assertEqual(len(self.files()), 2)
        self.assertGreater(self.ack(receipt, "B")["removedBytes"], 0)
        self.assertEqual(self.files(), [])
        state, _ = self.state("B")
        saved = state["items"][0]
        self.assertNotIn("data", saved["backgroundPhoto"])
        self.assertNotIn("data", saved["stickers"][0])
        self.assertEqual(saved["backgroundPhoto"]["rotation"], photo["rotation"])
        self.assertEqual(saved["drawingData"], applied["drawingData"])
        self.assertEqual(self.request("GET", "/v1/state", role="B")[0], 503)
        self.assertEqual(self.ack(receipt, "B")["removedBytes"], 0)
        other_port = self.start_server()
        self.assertEqual(self.request("GET", "/v1/state", role="B", port=other_port,
                                      headers={"X-CoupleDraw-Media": "2"})[0], 200)
        server.prepare_media(self.db_path, server.MediaFiles(self.db_path), compact=True)
        self.assertEqual(self.files(), [])

    def test_stale_receipts_cannot_delete_new_revision_even_with_identical_bytes(self):
        self.apply(photo=self.photo())
        old = self.receipt()
        self.ack(old, "A")
        self.ack(old, "B")
        self.assertEqual(self.files(), [])
        self.apply(expected=1, photo=self.photo())
        new = self.receipt()
        self.assertEqual(new["mediaIDs"], old["mediaIDs"])
        for role in ("A", "B"):
            self.assertEqual(self.ack(old, role)["accepted"], [])
        self.assertEqual(len(self.files()), 1)
        self.ack(new, "A")
        self.assertEqual(len(self.files()), 1)
        self.ack(new, "B")
        self.assertEqual(self.files(), [])

    def test_replaced_unread_photo_is_pruned_without_deleting_pending_replacement(self):
        self.apply(photo=self.photo(b"old"))
        old = self.receipt()
        self.apply(expected=1, photo=self.photo(b"new"))
        new = self.receipt()
        self.assertEqual([file.stem for file in self.files()], new["mediaIDs"])
        self.assertEqual(self.ack(old, "B")["accepted"], [])
        self.ack(new, "A")
        server.prepare_media(self.db_path, server.MediaFiles(self.db_path), compact=True)
        self.assertEqual(len(self.files()), 1)

    def test_deduplicated_image_waits_for_every_canvas_that_references_it(self):
        self.apply(photo=self.photo())
        self.apply(source="b", photo=self.photo(), role="B")
        a = self.receipt("a")
        b = self.receipt("b")
        for role in ("A", "B"):
            self.ack(a, role)
        self.assertEqual(len(self.files()), 1)
        for role in ("A", "B"):
            self.ack(b, role)
        self.assertEqual(self.files(), [])

    def test_global_deduplication_does_not_delete_another_pairs_unread_copy(self):
        self.tokens["other-B"] = "other-pair-private-token-B"
        with server.connect(self.db_path) as db:
            db.execute("INSERT INTO members VALUES (?, 'other', 'B')",
                       (hashlib.sha256(self.tokens["other-B"].encode()).hexdigest(),))
        self.apply(photo=self.photo())
        self.apply(photo=self.photo(), role="other")
        first = self.receipt()
        second = self.receipt(role="other")
        for role in ("A", "B"):
            self.ack(first, role)
        self.assertEqual(len(self.files()), 1)
        self.ack(second, "other")
        self.assertEqual(len(self.files()), 1)
        self.ack(second, "other-B")
        self.assertEqual(self.files(), [])

    def test_legacy_phone_keeps_originals_until_it_can_send_durable_receipts(self):
        photo = self.photo()
        self.apply(photo=photo)
        self.ack(self.receipt(), "A")
        for _ in range(2):
            status, state, _ = self.request("GET", "/v1/state", role="B")
            self.assertEqual(status, 200)
            self.assertEqual(state["mediaProtocol"], 1)
            self.assertEqual(state["items"][0]["backgroundPhoto"], photo)
        self.assertEqual(len(self.files()), 1)

    def test_resend_wakes_long_poll_and_is_retained_until_recipient_confirms_again(self):
        photo = self.photo()
        self.apply(photo=photo)
        receipt = self.receipt()
        ident = receipt["mediaIDs"][0]
        for role in ("A", "B"):
            self.ack(receipt, role)
        self.assertEqual(self.files(), [])
        other_port = self.start_server()
        _, before = self.state("A")
        with ThreadPoolExecutor(1) as pool:
            started = time.monotonic()
            waiting = pool.submit(self.request, "GET", "/v1/state", None, "A",
                                  {"X-CoupleDraw-Media": "2", "If-None-Match": before["ETag"], "Prefer": "wait=20"})
            time.sleep(0.15)
            self.assertEqual(self.request("POST", "/v1/media/request", {"mediaIDs": [ident]}, "B", port=other_port)[0], 200)
            code, donor, _ = waiting.result(timeout=4)
        self.assertEqual((code, donor["mediaRequests"]), (200, [ident]))
        self.assertLess(time.monotonic() - started, 3)
        _, before = self.state("B")
        with ThreadPoolExecutor(1) as pool:
            waiting = pool.submit(self.request, "GET", "/v1/state", None, "B",
                                  {"X-CoupleDraw-Media": "2", "If-None-Match": before["ETag"], "Prefer": "wait=20"})
            time.sleep(0.15)
            restored = self.request("POST", "/v1/media/restore", {"mediaID": ident, "data": photo["data"]}, "A", port=other_port)
            code, recipient, _ = waiting.result(timeout=4)
        self.assertEqual((restored[0], code), (200, 200))
        self.assertEqual(recipient["items"][0]["backgroundPhoto"]["data"], photo["data"])
        self.assertEqual(self.state("A")[0]["mediaRequests"], [])
        self.assertEqual(len(self.files()), 1)
        with server.connect(self.db_path) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM media_requests").fetchone()[0], 1)
        self.ack(receipt, "B")
        self.assertEqual(self.files(), [])
        self.assertEqual(self.request("POST", "/v1/media/restore", {"mediaID": ident, "data": photo["data"]})[0], 409)
        self.assertEqual(self.files(), [])  # A delayed resend cannot resurrect a delivered file.
        with server.connect(self.db_path) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM media_requests").fetchone()[0], 0)

    def test_recovery_and_receipts_are_pair_scoped_and_validate_hash_and_limits(self):
        photo = self.photo()
        self.apply(photo=photo)
        receipt = self.receipt()
        ident = receipt["mediaIDs"][0]
        self.assertEqual(self.ack(receipt, "other")["accepted"], [])
        self.assertEqual(self.request("POST", "/v1/media/request", {"mediaIDs": [ident]}, "other")[0], 404)
        self.assertEqual(self.request("POST", "/v1/media/restore", {"mediaID": ident, "data": photo["data"]}, "other")[0], 404)
        self.assertEqual(self.request("POST", "/v1/media/request", {"mediaIDs": [ident]}, headers={"Authorization": ""})[0], 401)
        for ids in ([], [ident, ident], ["../private"], ["a" * 64] * 53):
            self.assertEqual(self.request("POST", "/v1/media/request", {"mediaIDs": ids})[0], 400)
        for revision in (True, -1, 2**80):
            self.assertEqual(self.request("POST", "/v1/media/ack", {"receipts": [{**receipt, "revision": revision}]})[0], 400)
        self.assertEqual(self.request("POST", "/v1/media/request", {"mediaIDs": [ident]}, "B")[0], 200)
        self.assertEqual(self.request("POST", "/v1/media/restore", {"mediaID": ident, "data": self.photo(b"wrong")["data"]})[0], 400)
        self.assertEqual(self.files()[0].read_bytes(), base64.b64decode(photo["data"]))
        with server.connect(self.db_path) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM media_deliveries").fetchone()[0], 0)

    def test_legacy_shared_base_protects_its_original_until_receipted_or_seeded(self):
        self.apply(source="together", photo=self.photo())
        together = self.receipt("together")
        base = self.receipt("base")
        for role in ("A", "B"):
            self.ack(together, role)
        self.assertEqual(len(self.files()), 1)
        self.seed()
        self.assertEqual(self.files(), [])
        self.assertEqual(self.ack(base, "B")["accepted"], [])
        self.assertNotIn("base", [item["source"] for item in self.state()[0]["mediaInventory"]])


if __name__ == "__main__":
    unittest.main()
