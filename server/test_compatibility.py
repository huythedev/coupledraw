"""Mixed-version v1 contract: discovery is additive and gating is feature-only."""
import json
import unittest
from unittest.mock import patch
import coupledraw_server as server
import test_whiteboard
import test_media_relay


class CompatibilityHTTPTests(unittest.TestCase):
    setUp = test_whiteboard.WhiteboardHTTPTests.setUp
    start_server = test_whiteboard.WhiteboardHTTPTests.start_server
    cleanup_resources = test_whiteboard.WhiteboardHTTPTests.cleanup_resources
    request = test_whiteboard.WhiteboardHTTPTests.request
    seed = test_whiteboard.WhiteboardHTTPTests.seed
    def apply(self, source="a"):
        return self.request("POST", "/v1/apply", {
            "source": source, "expectedRevision": 0, "backgroundHex": "#123456",
            "drawingData": "", "drawingHeight": 844})

    def modern(self, role="A"):
        return self.request("GET", "/v1/state", role=role, headers={
            "X-CoupleDraw-API": "1", "X-CoupleDraw-Media": "2", "X-CoupleDraw-Board-History": "1",
            "X-CoupleDraw-Protocols": json.dumps(server.PROTOCOLS)})

    def test_discovery_needs_no_token_and_does_not_change_v1_state(self):
        status, discovery, _ = self.request("GET", "/v1/capabilities", headers={"Authorization": ""})
        self.assertEqual(status, 200)
        self.assertEqual(discovery["apiVersions"], [1])
        self.assertEqual(discovery["protocols"]["whiteboard"], [1])
        self.assertEqual(self.apply()[0], 200)
        status, state, _ = self.request("GET", "/v1/state", role="B")
        self.assertEqual(status, 200)
        self.assertEqual((state["role"], state["items"][0]["source"], state["boardProtocol"]), ("B", "a", 1))

    def test_new_api_request_is_rejected_without_breaking_existing_clients(self):
        status, error, _ = self.request("GET", "/v1/state", headers={"X-CoupleDraw-API": "2"})
        self.assertEqual((status, error["code"], error["target"]), (426, "update_required", "server"))
        self.assertEqual(self.request("GET", "/v1/state")[0], 200)
        self.assertEqual(self.apply()[0], 200)

    def test_peer_upgrade_wakes_state_and_enables_whiteboard_without_repairing(self):
        _, state, headers = self.modern()
        self.assertFalse(state["capabilities"]["whiteboardReady"])
        self.modern("B")
        status, state, _ = self.request("GET", "/v1/state", headers={
            "If-None-Match": headers["ETag"], "X-CoupleDraw-Media": "2",
            "X-CoupleDraw-Board-History": "1", "X-CoupleDraw-Protocols": json.dumps(server.PROTOCOLS)})
        self.assertEqual(status, 200)
        self.assertTrue(state["capabilities"]["whiteboardReady"])
        self.assertEqual(state["capabilities"]["peerProtocols"]["stickers"], [1])

    def test_whiteboard_migration_keeps_layers_omitted_by_legacy_delta_hints(self):
        self.modern()
        for role in ("A", "B"):
            self.request("POST", "/v1/draft", {"drawingData": test_whiteboard.stroke(role)["drawingData"], "drawingHeight": 844}, role=role)
        self.modern("B")
        _, state, _ = self.request("GET", "/v1/state", headers={
            "X-CoupleDraw-Media": "2", "X-CoupleDraw-Board-History": "1",
            "X-CoupleDraw-Protocols": json.dumps(server.PROTOCOLS),
            "X-CoupleDraw-Drafts": "A:1,B:1", "X-CoupleDraw-Base-Known": "1"})
        self.assertTrue(state["capabilities"]["whiteboardReady"])
        self.assertEqual({d["role"] for d in state["drafts"]}, {"A", "B"})

    def test_legacy_partner_keeps_shared_drafts_and_apply_available(self):
        self.request("GET", "/v1/state", role="B")
        _, state, _ = self.modern()
        self.assertFalse(state["capabilities"]["whiteboardReady"])
        status, error, _ = self.request("POST", "/v1/board/seed", {"seedTag": state["boardSeedTag"], "strokes": []},
                                        headers={"X-CoupleDraw-Protocols": json.dumps(server.PROTOCOLS)})
        self.assertEqual((status, error["feature"], error["target"]), (409, "whiteboard", "partner"))
        draft = {"drawingData": "", "drawingHeight": 844}
        self.assertEqual(self.request("POST", "/v1/draft", draft, role="B")[0], 200)
        self.assertEqual(self.request("POST", "/v1/draft", draft)[0], 200)
        self.assertEqual(self.apply(source="together")[0], 200)
        self.assertEqual(self.apply()[0], 200)

    def test_pre_discovery_whiteboard_clients_can_seed_edit_retry_and_apply(self):
        self.request("GET", "/v1/state", role="B", headers={"X-CoupleDraw-Media": "2"})
        self.seed()
        operation = {"id": "old-operation", "add": [test_whiteboard.stroke("old-stroke")], "remove": []}
        self.assertEqual(self.request("POST", "/v1/board/ops", operation)[0], 200)
        self.assertEqual(self.request("POST", "/v1/board/ops", operation)[1]["revision"], 2)
        body = {"source": "together", "expectedRevision": 0, "boardRevision": 2,
                "backgroundHex": "#000000", "backgroundPhoto": None, "drawingData": "", "drawingHeight": 844}
        self.assertEqual(self.request("POST", "/v1/apply", body)[0], 200)
        with server.read_connection(self.db_path) as db:
            self.assertIsNone(db.execute("SELECT 1 FROM board_history").fetchone())

    def test_missing_legacy_discovery_does_not_claim_peer_features_are_absent(self):
        self.seed()
        self.request("GET", "/v1/state", role="B", headers={"X-CoupleDraw-Media": "1"})
        _, state, _ = self.modern()
        self.assertTrue(state["capabilities"]["whiteboardReady"])
        self.assertIsNone(state["capabilities"]["peerProtocols"])
        self.assertEqual(state["boardProtocol"], 1)

    def test_lowercase_headers_keep_explicit_capabilities_during_board_edits(self):
        self.seed(); self.modern(); self.modern("B")
        headers = {"x-coupledraw-protocols": json.dumps(server.PROTOCOLS), "x-coupledraw-board-history": "1"}
        status, _, _ = self.request("POST", "/v1/board/ops", {
            "id": "lowercase", "baseRevision": 1, "add": [test_whiteboard.stroke("kept")], "remove": []}, headers=headers)
        self.assertEqual(status, 200)
        _, state, _ = self.modern("B")
        self.assertEqual(state["capabilities"]["peerProtocols"]["stickers"], [1])

    def test_legacy_reconnect_revokes_gc_permission_and_retains_recent_retries(self):
        self.seed()
        self.modern(); self.modern("B")
        operation = {"id": "recent", "baseRevision": 1, "add": [test_whiteboard.stroke("kept")], "remove": []}
        self.assertEqual(self.request("POST", "/v1/board/ops", operation)[0], 200)
        self.request("GET", "/v1/state", role="B", headers={"X-CoupleDraw-Media": "2"})
        with patch.object(server, "BOARD_HISTORY_REVISIONS", 0):
            with server.connect(self.db_path, initialize=False) as db:
                db.execute("BEGIN IMMEDIATE")
                server.compact_board(db, "pair", 2)
                self.assertIsNone(db.execute("SELECT 1 FROM board_history").fetchone())
                self.assertEqual(db.execute("SELECT COUNT(*) FROM board_operations").fetchone()[0], 1)
        self.assertEqual(self.request("POST", "/v1/board/ops", operation)[1]["revision"], 2)

    def test_checkpointed_legacy_edits_return_feature_update_but_own_art_still_works(self):
        self.seed(); self.modern(); self.modern("B")
        with server.connect(self.db_path, initialize=False) as db:
            db.execute("INSERT INTO board_history VALUES ('pair', 1)")
        status, error, _ = self.request("POST", "/v1/board/ops", {"id": "old", "add": [], "remove": []})
        self.assertEqual((status, error["code"], error["feature"], error["target"]), (409, "update_required", "boardHistory", "app"))
        self.assertEqual(error["board"]["revision"], 1)
        self.assertEqual(self.apply()[0], 200)
        self.assertEqual(self.request("GET", "/v1/state", role="B")[0], 200)

    def test_unknown_and_invalid_discovery_hints_do_not_disable_legacy_requests(self):
        for hint in ('{"wallpaper":[1,2],"futureFeature":[99]}', '[]', '{broken', '{"wallpaper":[true]}'):
            self.assertEqual(self.request("GET", "/v1/state", headers={"X-CoupleDraw-Protocols": hint})[0], 200)
        _, state, _ = self.request("GET", "/v1/state", role="B")
        self.assertEqual(state["capabilities"]["peerProtocols"]["futureFeature"], [99])

    def test_downgraded_media_client_recovers_inline_photos_without_relay_api(self):
        photo = test_media_relay.MediaRelayHTTPTests.photo()
        status, _, _ = self.request("POST", "/v1/apply", {
            "source": "a", "expectedRevision": 0, "backgroundHex": "#123456",
            "backgroundPhoto": photo, "drawingData": "", "drawingHeight": 844})
        self.assertEqual(status, 200)
        _, state, _ = self.modern()
        receipt = state["mediaInventory"][0]
        for role in ("A", "B"):
            self.assertEqual(self.request("POST", "/v1/media/ack", {"receipts": [receipt]}, role=role)[0], 200)
        self.assertEqual(self.request("GET", "/v1/state", role="B")[0], 503)
        _, state, _ = self.modern()
        self.assertEqual(state["mediaRequests"], receipt["mediaIDs"])
        self.assertEqual(self.request("POST", "/v1/media/restore", {"mediaID": receipt["mediaIDs"][0], "data": photo["data"]})[0], 200)
        self.request("POST", "/v1/media/ack", {"receipts": [receipt]})
        status, state, _ = self.request("GET", "/v1/state", role="B")
        self.assertEqual(status, 200)
        self.assertEqual(state["items"][0]["backgroundPhoto"]["data"], photo["data"])


if __name__ == "__main__":
    unittest.main()
