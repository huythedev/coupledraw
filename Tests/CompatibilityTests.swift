import XCTest
import PencilKit
@testable import CoupleDraw

@MainActor final class CompatibilityTests: XCTestCase {
    private var root: URL!
    private var store: CanvasStore!
    private var savedPreferences: [String: Any] = [:]
    private let keys = ["syncEndpoint", "syncVersions", "syncDirty", "syncRetryUntil", "partnerAlertsEnabled"]

    override func setUp() async throws {
        try await super.setUp()
        for key in keys {
            savedPreferences[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = CanvasStore(root: root)
    }

    override func tearDown() async throws {
        for key in keys {
            if let value = savedPreferences[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: root)
        store = nil
        try await super.tearDown()
    }

    private func reply(_ request: URLRequest, _ body: [String: Any], status: Int = 200) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: body),
         try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)))
    }

    private func item(_ source: String = "a", color: String = "#123456") -> [String: Any] {
        ["source": source, "revision": 1, "author": "A", "backgroundHex": color,
         "drawingData": "", "drawingHeight": 844]
    }

    private func state(items: [[String: Any]] = [], board: Int? = 1, caps: [String: Any]? = nil) -> [String: Any] {
        var body: [String: Any] = ["role": "A", "items": items, "mediaProtocol": 1]
        if let board {
            body["boardProtocol"] = board
            body["board"] = ["revision": 1, "strokes": [], "removed": []]
        }
        if let caps { body["capabilities"] = caps }
        return body
    }

    private func caps(_ protocols: [String: [Int]], peer: [String: [Int]]? = nil) -> [String: Any] {
        var result: [String: Any] = ["apiVersions": [1, 2], "protocols": protocols]
        if let peer { result["peerProtocols"] = peer }
        return result
    }

    func testNewAppOnPreWhiteboardServerKeepsOwnPartnerSyncAndApply() async throws {
        var paths: [String] = []
        let sync = PairSync(transport: { request in
            paths.append(request.url!.path)
            if request.url?.path == "/v1/apply" {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                return try self.reply(request, self.item(body["source"] as? String ?? "a", color: "#654321"))
            }
            return try self.reply(request, self.state(items: [self.item(), self.item("b", color: "#ABCDEF")], board: nil))
        }, readToken: { "phone-A" }, writeToken: { _ in })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://sync.invalid", token: "phone-A", store: store)
        sync.stop()
        XCTAssertNil(sync.updateNotice)
        XCTAssertNil(store.whiteboard)
        XCTAssertEqual(store.record(.first).backgroundHex, "#123456")
        XCTAssertEqual(store.record(.second).backgroundHex, "#ABCDEF")
        store.updateBackground("#654321", on: .first)
        sync.markDirty(.first)
        await sync.publish(store.record(.first), slot: .first, store: store)
        XCTAssertTrue(paths.contains("/v1/apply"))
        XCTAssertFalse(paths.contains("/v1/board/seed"))
        XCTAssertNil(sync.updateNotice)
        XCTAssertTrue(sync.requireSharedEditing(store: store, allowSnapshot: true))
        await sync.publish(store.record(.together), slot: .together, store: store)
        XCTAssertTrue(sync.status.contains("Published"))
        XCTAssertFalse(sync.requireSharedEditing(store: store))
        XCTAssertEqual(sync.updateNotice?.feature, "whiteboard")
    }

    func testLegacySharedLayersCanStillSyncAndApply() async throws {
        var paths: [String] = []
        var body = state(board: nil)
        body["drafts"] = [["role": "B", "revision": 1, "drawingData": "", "drawingHeight": 844]]
        let sync = PairSync(transport: { request in
            paths.append(request.url!.path)
            if request.url?.path == "/v1/draft" { return try self.reply(request, ["role": "A", "revision": 1]) }
            if request.url?.path == "/v1/apply" { return try self.reply(request, self.item("together")) }
            return try self.reply(request, body)
        }, readToken: { "phone-A" }, writeToken: { _ in })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://sync.invalid", token: "phone-A", store: store)
        sync.stop()
        XCTAssertTrue(store.liveSharedEnabled)
        XCTAssertNil(store.whiteboard)
        XCTAssertTrue(sync.requireSharedEditing(store: store))
        store.updateSharedOwn(PKDrawing().dataRepresentation())
        sync.markDirty(.together)
        await sync.publish(store.displayedRecord(.together), slot: .together, store: store)
        XCTAssertTrue(paths.contains("/v1/draft"))
        XCTAssertTrue(paths.contains("/v1/apply"))
        XCTAssertNil(sync.updateNotice)
    }

    func testShortcutExportsPartnerWallpaperFromOlderServer() async throws {
        UserDefaults.standard.set("https://sync.invalid", forKey: "syncEndpoint")
        let lightweight = CanvasStore(root: root, shortcutChoice: .partner)
        let sync = PairSync(transport: { request in
            XCTAssertEqual(request.url?.path, "/v1/state")
            return try self.reply(request, self.state(items: [self.item("b")], board: nil))
        }, readToken: { "phone-A" })
        defer { sync.suspend() }
        try await sync.refreshForShortcut(store: lightweight, choice: .partner)
        let exported = try lightweight.wallpaperFileForShortcut(on: .second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
        XCTAssertNil(lightweight.whiteboard)
        XCTAssertNil(sync.updateNotice)
    }

    func testUnknownFutureBoardPayloadDoesNotBreakWallpaperSync() async throws {
        var body = state(items: [item("b")], board: 2, caps: caps(["wallpaper": [1], "whiteboard": [2]]))
        body["board"] = ["futureFormat": ["newField": "ignored"]]
        let sync = PairSync(transport: { request in try self.reply(request, body) },
                            readToken: { "phone-A" }, writeToken: { _ in })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://sync.invalid", token: "phone-A", store: store)
        sync.stop()
        XCTAssertEqual(store.record(.second).backgroundHex, "#123456")
        XCTAssertNil(sync.updateNotice)
        XCTAssertFalse(sync.requireSharedEditing(store: store))
        XCTAssertEqual(sync.updateNotice?.target, .app)
    }

    func testFutureServerAdvertisingV1StillUsesCurrentWhiteboard() async throws {
        let body = state(caps: caps(["wallpaper": [2, 1], "whiteboard": [2, 1], "futureFeature": [99]],
                                   peer: ["whiteboard": [1], "wallpaper": [1]]))
        let sync = PairSync(transport: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CoupleDraw-API"), "1")
            let advertised = try XCTUnwrap(request.value(forHTTPHeaderField: "X-CoupleDraw-Protocols"))
            XCTAssertTrue(advertised.contains("whiteboard"))
            return try self.reply(request, body)
        }, readToken: { "phone-A" }, writeToken: { _ in })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://sync.invalid", token: "phone-A", store: store)
        sync.stop()
        XCTAssertNotNil(store.whiteboard)
        XCTAssertTrue(sync.requireSharedEditing(store: store))
        XCTAssertNil(sync.updateNotice)
    }

    func testUnsupportedPhotosPromptOnApplyAndPlainDrawingStillPublishes() async throws {
        var published = 0
        let body = state(caps: caps(["wallpaper": [1], "whiteboard": [1]]))
        let sync = PairSync(transport: { request in
            if request.url?.path == "/v1/apply" { published += 1; return try self.reply(request, self.item()) }
            return try self.reply(request, body)
        }, readToken: { "phone-A" }, writeToken: { _ in })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://sync.invalid", token: "phone-A", store: store)
        sync.stop()
        XCTAssertNil(sync.updateNotice)
        var withPhoto = store.record(.first)
        withPhoto.backgroundPhoto = BackgroundPhoto(data: Data([1, 2, 3]))
        await sync.publish(withPhoto, slot: .first, store: store)
        XCTAssertEqual(published, 0)
        XCTAssertEqual(sync.updateNotice?.feature, "photos")
        XCTAssertEqual(sync.updateNotice?.target, .server)
        sync.updateNotice = nil
        await sync.publish(store.record(.first), slot: .first, store: store)
        XCTAssertEqual(published, 1)
        XCTAssertNil(sync.updateNotice)
    }

    func testPairingUnsupportedPopupStillAllowsManualToken() async throws {
        let sync = PairSync(transport: { request in
            if request.url?.path.hasPrefix("/v1/pairing/") == true {
                return try self.reply(request, ["error": "Not found"], status: 404)
            }
            return try self.reply(request, self.state(board: nil))
        }, readToken: { "phone-A" }, writeToken: { _ in }, readPairing: { nil }, writePairing: { _ in })
        defer { sync.suspend() }
        try sync.beginPairing(.create, endpoint: "https://sync.invalid")
        do { _ = try await sync.resumePairing(store: store, wait: false); XCTFail("Expected an update notice") }
        catch { XCTAssertTrue(error is UpdateNotice) }
        XCTAssertEqual(sync.updateNotice?.feature, "pairing")
        try await sync.cancelPairing()
        try await sync.configure(endpoint: "https://sync.invalid", token: "phone-A", store: store)
        sync.stop()
        XCTAssertTrue(sync.configured)
        XCTAssertNil(sync.updateNotice)
    }

    func testPartnerCapabilityGatesOnlyFeatureAndDistinguishesFutureProtocol() throws {
        let model = try JSONDecoder().decode(SyncCapabilities.self, from: JSONSerialization.data(withJSONObject:
            caps(["wallpaper": [1], "stickers": [1], "whiteboard": [2]], peer: ["wallpaper": [1]])))
        XCTAssertTrue(model.supports("wallpaper", withPartner: true))
        XCTAssertEqual(model.missing("stickers", withPartner: true)?.target, .partner)
        XCTAssertEqual(model.missing("whiteboard")?.target, .app)
    }

    func testServerFeatureErrorShowsUpdateWithoutMisreportingEditConflict() async throws {
        let sync = PairSync(transport: { request in
            if request.url?.path == "/v1/apply" {
                return try self.reply(request, ["error": "Update required", "code": "update_required",
                                                "feature": "photos", "target": "server"], status: 409)
            }
            return try self.reply(request, self.state())
        }, readToken: { "phone-A" }, writeToken: { _ in })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://sync.invalid", token: "phone-A", store: store)
        sync.stop()
        await sync.publish(store.record(.first), slot: .first, store: store)
        XCTAssertEqual(sync.updateNotice?.feature, "photos")
        XCTAssertFalse(sync.status.contains("Edit conflict"))
        XCTAssertNil(store.errorMessage)
    }

    func testKnownOlderPartnerGetsStickerNoticeAndPlainApplyStillWorks() async throws {
        var published = 0
        let body = state(board: nil, caps: caps(["wallpaper": [1], "stickers": [1]], peer: ["wallpaper": [1]]))
        let sync = PairSync(transport: { request in
            if request.url?.path == "/v1/apply" { published += 1; return try self.reply(request, self.item()) }
            return try self.reply(request, body)
        }, readToken: { "phone-A" }, writeToken: { _ in })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://sync.invalid", token: "phone-A", store: store)
        sync.stop()
        var record = store.record(.first)
        record.stickers = [CanvasSticker(data: Data([1, 2]))]
        await sync.publish(record, slot: .first, store: store)
        XCTAssertEqual(published, 0)
        XCTAssertEqual(sync.updateNotice?.target, .partner)
        sync.updateNotice = nil
        await sync.publish(store.record(.first), slot: .first, store: store)
        XCTAssertEqual(published, 1)
        XCTAssertNil(sync.updateNotice)
    }

    func testLegacyToWhiteboardMigrationRefetchesCompleteLayers() async throws {
        var phase = 0
        var seeded = 0
        var fullMigrationReads = 0
        func drawing(_ x: CGFloat) -> Data {
            let point = PKStrokePoint(location: CGPoint(x: x, y: 20), timeOffset: 0,
                                      size: CGSize(width: 6, height: 6), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .white),
                        path: PKStrokePath(controlPoints: [point], creationDate: Date()))]).dataRepresentation()
        }
        let drawings = [drawing(20), drawing(100), drawing(200)]
        var base = item("together")
        base["drawingData"] = drawings[0].base64EncodedString()
        let drafts: [[String: Any]] = ["A", "B"].enumerated().map { index, role in
            ["role": role, "revision": 1, "drawingData": drawings[index + 1].base64EncodedString(), "drawingHeight": 844]
        }
        let sync = PairSync(transport: { request in
            if request.url?.path == "/v1/board/seed" {
                let seed = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                let strokes = try XCTUnwrap(seed["strokes"] as? [[String: Any]])
                seeded = strokes.count
                return try self.reply(request, ["revision": 1, "strokes": strokes, "removed": []])
            }
            var declarations = self.caps(["wallpaper": [1], "whiteboard": [1], "legacyDrafts": [1]], peer: ["whiteboard": [1]])
            declarations["whiteboardReady"] = phase == 1
            var state = self.state(board: nil, caps: declarations)
            state["boardProtocol"] = 1
            if phase == 1 { state["boardSeedTag"] = "migration-tag" }
            if request.value(forHTTPHeaderField: "X-CoupleDraw-Base-Known") == nil {
                state["sharedBase"] = base
                state["drafts"] = drafts
                if phase == 1 { fullMigrationReads += 1 }
            } else { state["drafts"] = [] }
            return try self.reply(request, state)
        }, readToken: { "phone-A" }, writeToken: { _ in })
        defer { sync.suspend() }
        try await sync.configure(endpoint: "https://sync.invalid", token: "phone-A", store: store)
        sync.stop()
        XCTAssertTrue(store.liveSharedEnabled)
        XCTAssertNil(store.whiteboard)
        phase = 1
        await sync.refresh(store: store)
        XCTAssertEqual(fullMigrationReads, 1)
        XCTAssertEqual(seeded, 3)
        XCTAssertEqual(try PKDrawing(data: XCTUnwrap(store.whiteboard).drawingData).strokes.count, 3)
        XCTAssertNil(sync.updateNotice)
    }
}
