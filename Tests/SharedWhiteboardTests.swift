import XCTest
import PencilKit
@testable import CoupleDraw

@MainActor final class SharedWhiteboardTests: XCTestCase {
    private func stroke(_ x: CGFloat) throws -> SharedStroke {
        let point = PKStrokePoint(location: CGPoint(x: x, y: 40), timeOffset: 0,
                                  size: CGSize(width: 6, height: 6), opacity: 1, force: 1,
                                  azimuth: 0, altitude: .pi / 2)
        let object = PKStroke(ink: PKInk(.pen, color: .white),
                              path: PKStrokePath(controlPoints: [point], creationDate: Date(timeIntervalSince1970: Double(x))))
        return try XCTUnwrap(SharedStroke.split(PKDrawing(strokes: [object]).dataRepresentation(), height: 844).first)
    }

    private func makeBoard() throws -> (SharedWhiteboard, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        return (try SharedWhiteboard(url: file, height: 844), file)
    }

    func testIncomingEditDuringGestureMergesWithoutDeletingPartnerStroke() throws {
        let (board, file) = try makeBoard()
        defer { try? FileManager.default.removeItem(at: file) }
        let first = try stroke(10), partner = try stroke(20), mine = try stroke(30)
        try board.receive(BoardUpdate(revision: 1, baseRevision: nil, strokes: [first], removed: []))
        let before = board.drawingData
        board.beginEditing()
        try board.receive(BoardUpdate(revision: 2, baseRevision: 1, strokes: [partner], removed: []))
        XCTAssertEqual(board.drawingData, before)
        board.endEditing(PKDrawing(strokes: [try first.stroke(at: 844), try mine.stroke(at: 844)]).dataRepresentation())
        XCTAssertEqual(try PKDrawing(data: board.drawingData).strokes.count, 3)
        let patch = try XCTUnwrap(board.nextPatch)
        XCTAssertTrue(patch.remove.isEmpty)
        XCTAssertEqual(patch.add.count, 1)
    }

    func testQueueSurvivesRelaunchAndEchoBeforeAcknowledgementDoesNotDuplicate() throws {
        let (board, file) = try makeBoard()
        defer { try? FileManager.default.removeItem(at: file) }
        try board.receive(BoardUpdate(revision: 1, baseRevision: nil, strokes: [], removed: []))
        let mine = try stroke(10)
        board.drawingChanged(mine.drawingData)
        let patch = try XCTUnwrap(board.nextPatch)
        let reopened = try SharedWhiteboard(url: file, height: 844)
        XCTAssertEqual(reopened.nextPatch?.id, patch.id)
        try reopened.receive(BoardUpdate(revision: 2, baseRevision: 1, strokes: patch.add, removed: []))
        XCTAssertEqual(try PKDrawing(data: reopened.drawingData).strokes.count, 1)
        try reopened.receive(BoardUpdate(revision: 2, baseRevision: 1, strokes: patch.add, removed: []), acknowledging: patch.id)
        XCTAssertFalse(reopened.hasPending)
        XCTAssertEqual(try PKDrawing(data: reopened.drawingData).strokes.count, 1)
    }

    func testMovePartnerStrokeAndUndoOnlyMyEdit() throws {
        let (board, file) = try makeBoard()
        defer { try? FileManager.default.removeItem(at: file) }
        let partner = try stroke(10)
        try board.receive(BoardUpdate(revision: 1, baseRevision: nil, strokes: [partner], removed: []))
        let moved = try PKDrawing(data: partner.drawingData).transformed(using: CGAffineTransform(translationX: 50, y: 10))
        board.drawingChanged(moved.dataRepresentation())
        let patch = try XCTUnwrap(board.nextPatch)
        XCTAssertEqual(patch.remove, [partner.id])
        XCTAssertEqual(patch.add.count, 1)
        try board.receive(BoardUpdate(revision: 2, baseRevision: 1, strokes: patch.add, removed: patch.remove), acknowledging: patch.id)
        let later = try stroke(100)
        try board.receive(BoardUpdate(revision: 3, baseRevision: 2, strokes: [later], removed: []))
        board.undo()
        let reverse = try XCTUnwrap(board.nextPatch)
        XCTAssertEqual(reverse.remove, patch.add.map(\.id))
        XCTAssertEqual(reverse.add.count, 1)
        XCTAssertEqual(try PKDrawing(data: board.drawingData).strokes.count, 2)
        XCTAssertTrue(board.canRedo)
    }

    func testFingerprintSurvivesArchiveAndDetectsMaskAndColor() throws {
        let original = try stroke(10).stroke(at: 844)
        let copy = try PKDrawing(data: PKDrawing(strokes: [original]).dataRepresentation()).strokes[0]
        XCTAssertEqual(SharedWhiteboard.fingerprint(original), SharedWhiteboard.fingerprint(copy))
        var masked = copy
        masked.mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 10, height: 50))
        XCTAssertNotEqual(SharedWhiteboard.fingerprint(original), SharedWhiteboard.fingerprint(masked))
        var colored = copy
        colored.ink = PKInk(.pen, color: .red)
        XCTAssertNotEqual(SharedWhiteboard.fingerprint(original), SharedWhiteboard.fingerprint(colored))
    }

    func testDifferentPhoneHeightRoundtripDoesNotCreateEdits() throws {
        let (board, file) = try makeBoard()
        defer { try? FileManager.default.removeItem(at: file) }
        let original = try stroke(10)
        let resized = SharedStroke(id: original.id,
                                  drawingData: PKDrawing(strokes: [try original.stroke(at: 900)]).dataRepresentation(),
                                  drawingHeight: 900)
        try board.receive(BoardUpdate(revision: 1, baseRevision: nil, strokes: [resized], removed: []))
        let roundTrip = try PKDrawing(data: board.drawingData).dataRepresentation()
        board.drawingChanged(roundTrip)
        XCTAssertFalse(board.hasPending)
    }

    func testRecoveryDoesNotBecomeWallpaperAndReloadsFromOlderHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CanvasStore(root: root)
        XCTAssertNotNil(store.apply(.together))
        let applied = try XCTUnwrap(store.revisions.first)
        XCTAssertNotNil(store.apply(.together, recovery: true))
        let reopened = CanvasStore(root: root)
        XCTAssertEqual(reopened.revisions.first?.recovery, true)
        XCTAssertEqual(reopened.revisions.first { $0.recovery != true }?.id, applied.id)
    }
}
