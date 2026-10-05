import XCTest
import UIKit
import PencilKit
import ImageIO
@testable import CoupleDraw

@MainActor final class SyncResourcesTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testShortcutDoesNotLoadHistoryOrUnselectedCanvases() throws {
        let folder = try root()
        defer { try? FileManager.default.removeItem(at: folder) }
        let main = CanvasStore(root: folder)
        main.updateBackground("#123456", on: .first)
        main.updateBackground("#654321", on: .together)
        XCTAssertNotNil(main.apply(.first))
        // A malformed History cannot make the lightweight initializer load it.
        try Data("not a History array".utf8).write(to: folder.appendingPathComponent("revisions.json"))
        let shortcut = CanvasStore(root: folder, shortcutChoice: .own)
        XCTAssertTrue(shortcut.revisions.isEmpty)
        XCTAssertEqual(shortcut.record(.first).backgroundHex, "#123456")
        XCTAssertEqual(shortcut.record(.together).backgroundHex, "#000000")
        XCTAssertNil(shortcut.whiteboard)
        XCTAssertTrue(shortcut.sharedOwnData.isEmpty)
        XCTAssertEqual(CanvasStore(root: folder).record(.together).backgroundHex, "#654321")
    }

    func testLegacyHistoryScanSkipsUnselectedMediaAndRecoveredDrafts() throws {
        let folder = try root()
        defer { try? FileManager.default.removeItem(at: folder) }
        let main = CanvasStore(root: folder)
        XCTAssertNotNil(main.apply(.first))
        let selected = try XCTUnwrap(main.revisions.first)
        let file = folder.appendingPathComponent("revisions.json")
        let unselected: [String: Any] = ["canvasID": UUID().uuidString,
            "document": ["file": "missing-original", "nested": ["escaped": "quote\" slash\\ braces } ]"]]]
        var recovered = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(selected)) as? [String: Any])
        recovered["recovery"] = true
        recovered["document"] = ["backgroundPhoto": ["file": "missing-recovery-original"]]
        let chosen = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selected))
        let history = Array(repeating: unselected, count: 3000) as [Any]
        try JSONSerialization.data(withJSONObject: history + [recovered, chosen]).write(to: file)
        let decoder = JSONDecoder()
        decoder.userInfo[.coupleDrawMediaRoot] = folder
        XCTAssertEqual(try RevisionStorage.firstApplied(at: file, canvasID: selected.canvasID, decoder: decoder)?.id, selected.id)
    }

    func testLegacyHistoryScanRejectsMalformedArrayAndOversizedObject() throws {
        let folder = try root()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json"), canvasID = UUID()
        let header = String(decoding: try JSONEncoder().encode(["canvasID": UUID().uuidString]), as: UTF8.self)
        for value in ["[" + header + ",]", "[" + header, "[1]"] {
            try Data(value.utf8).write(to: file)
            XCTAssertThrowsError(try RevisionStorage.firstApplied(at: file, canvasID: canvasID, decoder: JSONDecoder()))
        }
        try Data(("[{\"canvasID\":\"" + UUID().uuidString + "\",\"padding\":\"" + String(repeating: "x", count: 12_000_001) + "\"}]").utf8).write(to: file)
        XCTAssertThrowsError(try RevisionStorage.firstApplied(at: file, canvasID: canvasID, decoder: JSONDecoder()))
    }

    func testShortcutJournalMergesBeforeAnAlreadyOpenAppAppliesOrDeletesHistory() throws {
        let folder = try root()
        defer { try? FileManager.default.removeItem(at: folder) }
        let main = CanvasStore(root: folder)
        let shortcut = CanvasStore(root: folder, shortcutChoice: .partner)
        let incoming = SyncedRevision(source: "b", revision: 1, author: "B", backgroundHex: "#123456",
                                      backgroundPhoto: nil, drawingData: Data(), drawingHeight: 844)
        try shortcut.acceptRemote(incoming, on: .second, localRole: "A")
        XCTAssertTrue(shortcut.revisions.isEmpty)
        XCTAssertEqual(try RevisionStorage.pendingURLs(root: folder).count, 1)
        XCTAssertNotNil(main.apply(.first))
        XCTAssertEqual(main.revisions.count, 2)
        XCTAssertTrue(try RevisionStorage.pendingURLs(root: folder).isEmpty)
        let shortcutAgain = CanvasStore(root: folder, shortcutChoice: .partner)
        try shortcutAgain.acceptRemote(incoming, on: .second, localRole: "A")
        main.deleteAllRevisions(on: .second)
        XCTAssertEqual(main.revisions.count, 1)
        XCTAssertEqual(CanvasStore(root: folder).revisions.count, 1)
        XCTAssertTrue(try RevisionStorage.pendingURLs(root: folder).isEmpty)
        XCTAssertThrowsError(try CanvasStore(root: folder, shortcutChoice: .partner).wallpaperFileForShortcut(on: .second))
    }

    func testShortcutExportIsNativeSizedAndSurvivesClearCache() throws {
        let folder = try root()
        defer { try? FileManager.default.removeItem(at: folder) }
        let main = CanvasStore(root: folder)
        main.updateTargetSize(WallpaperSize(width: 750, height: 1334), on: .together)
        XCTAssertNotNil(main.apply(.together))
        let shortcut = CanvasStore(root: folder, shortcutChoice: .together)
        let exported = try shortcut.wallpaperFileForShortcut(on: .together)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(exported as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, WallpaperSize.thisIPhone.width)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, WallpaperSize.thisIPhone.height)
        _ = try main.clearCache()
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
        XCTAssertNotNil(UIImage(contentsOfFile: exported.path))
    }

    func testRendererRejectsExcessivePixelsAndNonFiniteDimensionsBeforeAllocation() throws {
        var record = CanvasRecord(ownerID: UUID())
        for size in [CGSize(width: 5000, height: 10000), CGSize(width: CGFloat.nan, height: 844),
                     CGSize(width: 390, height: CGFloat.infinity), .zero] {
            XCTAssertThrowsError(try WallpaperRenderer.render(record, pixels: size))
        }
        record.drawingHeight = .infinity
        XCTAssertThrowsError(try WallpaperRenderer.render(record, pixels: CGSize(width: 390, height: 844)))
        record.drawingHeight = 99999
        XCTAssertThrowsError(try WallpaperRenderer.render(record, pixels: CGSize(width: 390, height: 844)))
        XCTAssertFalse(WallpaperSize(width: Int.max, height: Int.max).isValid)
        XCTAssertFalse(WallpaperSize(width: 5000, height: 10000).isValid)
        XCTAssertTrue(WallpaperSize.thisIPhone.isValid)
    }

    func testRetryAfterUnderstandsSecondsAndHTTPDates() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(SyncRetrySchedule.retryAfter("120", now: now), 120)
        XCTAssertEqual(SyncRetrySchedule.retryAfter("Thu, 01 Jan 1970 00:01:00 GMT", now: now), 60)
        XCTAssertEqual(SyncRetrySchedule.retryAfter("Thu, 01 Jan 1970 00:00:00 GMT", now: now.addingTimeInterval(1)), 0)
        for header in ["-1", "NaN", "infinity", "garbage"] { XCTAssertNil(SyncRetrySchedule.retryAfter(header, now: now)) }
    }

    func testExponentialBackoffIsJitteredBoundedAndResetsAfterSuccess() {
        XCTAssertEqual(SyncRetrySchedule.delay(attempt: 1, sample: 0), 0.5)
        XCTAssertEqual(SyncRetrySchedule.delay(attempt: 2, sample: 1), 2)
        XCTAssertEqual(SyncRetrySchedule.delay(attempt: 99, sample: 1), 60)
        XCTAssertEqual(SyncRetrySchedule.delay(attempt: 1, retryAfter: 120, sample: 0.5), 120.5)
        var policy = SyncRetrySchedule()
        let now = Date()
        policy.fail(URLError(.timedOut), now: now, sample: 1)
        XCTAssertEqual(policy.remaining(at: now), 1)
        policy.fail(URLError(.timedOut), now: now, sample: 1)
        XCTAssertEqual(policy.remaining(at: now), 2)
        policy.reset()
        XCTAssertEqual(policy.failures, 0)
        XCTAssertEqual(policy.remaining(at: now), 0)
    }

    func testRetryGateSurvivesInstancesAndIsScopedToOriginAndPrincipal() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var request = URLRequest(url: URL(string: "https://gate.invalid/v1/state")!)
        request.setValue("Bearer private-A", forHTTPHeaderField: "Authorization")
        let now = Date()
        let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil,
                                                    headerFields: ["Retry-After": "120"]))
        SyncRetryGate.record(response, request: request, now: now, sample: 0.5, defaults: defaults)
        XCTAssertEqual(SyncRetryGate.remaining(request, now: now, defaults: defaults), 120.5)
        var other = request
        other.setValue("Bearer private-B", forHTTPHeaderField: "Authorization")
        XCTAssertEqual(SyncRetryGate.remaining(other, now: now, defaults: defaults), 0)
        other = request; other.url = URL(string: "https://other.invalid/v1/state")!
        XCTAssertEqual(SyncRetryGate.remaining(other, now: now, defaults: defaults), 0)
        XCTAssertEqual(SyncRetryGate.remaining(request, now: now.addingTimeInterval(121), defaults: defaults), 0)
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("private-A"))
    }
}
