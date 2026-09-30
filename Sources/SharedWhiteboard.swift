import Combine
import CryptoKit
import Foundation
import PencilKit
import UIKit

struct SharedStroke: Codable, Equatable {
    let id: String
    let drawingData: Data
    let drawingHeight: Double

    func stroke(at height: Double) throws -> PKStroke {
        let drawing = try PKDrawing(data: drawingData)
        guard drawing.strokes.count == 1, drawingHeight >= 300 else {
            throw PairSync.SyncError.server("The server sent an invalid whiteboard stroke.")
        }
        if abs(height - drawingHeight) < 0.000001 { return drawing.strokes[0] }
        return drawing.transformed(using: CGAffineTransform(scaleX: 1, y: CGFloat(height / drawingHeight))).strokes[0]
    }

    static func split(_ data: Data, height: Double) throws -> [SharedStroke] {
        guard !data.isEmpty else { return [] }
        return try PKDrawing(data: data).strokes.map {
            SharedStroke(id: UUID().uuidString,
                         drawingData: PKDrawing(strokes: [$0]).dataRepresentation(), drawingHeight: height)
        }
    }
}

struct BoardUpdate: Codable {
    let revision: Int
    let baseRevision: Int?
    let strokes: [SharedStroke]
    let removed: [String]
}

struct BoardPatch: Codable {
    let id: String
    let remove: [String]
    let add: [SharedStroke]
}

/// Stroke edits, not whole-canvas replacement. Each queued patch has a stable ID
/// so a lost HTTP response can be retried without duplicating the drawing.
@MainActor final class SharedWhiteboard: ObservableObject {
    private struct Saved: Codable {
        var revision = 0
        var strokes: [SharedStroke] = []
        var pending: [BoardPatch] = []
    }
    private struct Edit {
        let removed: [SharedStroke]
        let added: [SharedStroke]
    }
    @Published private(set) var drawingData = Data()
    @Published private(set) var isEditing = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var errorMessage: String?
    private let url: URL
    let drawingHeight: Double
    private var saved: Saved
    private var shown: [SharedStroke] = []
    private var shownKeys: [String] = []
    private var undoEdits: [Edit] = []
    private var redoEdits: [Edit] = []

    var revision: Int { saved.revision }
    var nextPatch: BoardPatch? { saved.pending.first }
    var hasPending: Bool { !saved.pending.isEmpty }

    init(url: URL, height: Double) throws {
        self.url = url
        drawingHeight = height
        if FileManager.default.fileExists(atPath: url.path) {
            saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
        } else { saved = Saved() }
        try rebuild()
    }

    private func write(_ value: Saved) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        saved = value
        pendingCount = value.pending.count
    }

    func receive(_ update: BoardUpdate, acknowledging id: String? = nil) throws {
        var next = saved
        if update.revision >= next.revision {
            if let base = update.baseRevision {
                guard base <= next.revision else {
                    throw PairSync.SyncError.server("Whiteboard needs a full refresh.")
                }
                let removed = Set(update.removed).union(update.strokes.map(\.id))
                next.strokes.removeAll { removed.contains($0.id) }
                next.strokes += update.strokes
            } else { next.strokes = update.strokes }
            next.revision = update.revision
        }
        if let id { next.pending.removeAll { $0.id == id } }
        // Decode before persisting or advancing the acknowledged version.
        for stroke in next.strokes { _ = try stroke.stroke(at: drawingHeight) }
        try write(next)
        if !isEditing { try rebuild() }
    }

    private func effectiveStrokes() -> [SharedStroke] {
        var result = saved.strokes
        for patch in saved.pending {
            let removed = Set(patch.remove).union(patch.add.map(\.id))
            result.removeAll { removed.contains($0.id) }
            result += patch.add
        }
        return result
    }

    private func rebuild() throws {
        let strokes = effectiveStrokes()
        let objects = try strokes.map { try $0.stroke(at: drawingHeight) }
        let keys = objects.map(Self.fingerprint)
        // Preserve PencilKit's lasso selection when the visible drawing is unchanged.
        if keys != shownKeys || drawingData.isEmpty {
            drawingData = PKDrawing(strokes: objects).dataRepresentation()
        }
        shown = strokes
        shownKeys = keys
        canUndo = !undoEdits.isEmpty
        canRedo = !redoEdits.isEmpty
    }

    func beginEditing() { isEditing = true }
    func drawingChanged(_ data: Data) {
        if isEditing { drawingData = data }
        else { commit(data) }
    }
    func endEditing(_ data: Data) {
        isEditing = false
        commit(data)
    }

    private func commit(_ data: Data) {
        do {
            let strokes = try PKDrawing(data: data).strokes
            var available: [String: [SharedStroke]] = [:]
            for (entry, key) in zip(shown, shownKeys) { available[key, default: []].append(entry) }
            var retained = Set<String>()
            var added: [SharedStroke] = []
            for stroke in strokes {
                let key = Self.fingerprint(stroke)
                if var matches = available[key], !matches.isEmpty {
                    let match = matches.removeFirst()
                    available[key] = matches
                    retained.insert(match.id)
                } else {
                    added.append(SharedStroke(id: UUID().uuidString,
                        drawingData: PKDrawing(strokes: [stroke]).dataRepresentation(), drawingHeight: drawingHeight))
                }
            }
            let removed = shown.filter { !retained.contains($0.id) }
            if !removed.isEmpty || !added.isEmpty {
                let edit = Edit(removed: removed, added: added)
                try enqueue(edit)
                undoEdits.append(edit)
                redoEdits.removeAll()
            }
            try rebuild()
        } catch { errorMessage = "Could not save shared edits: \(error.localizedDescription)" }
    }

    private func enqueue(_ edit: Edit) throws {
        var next = saved
        next.pending.append(BoardPatch(id: UUID().uuidString, remove: edit.removed.map(\.id), add: edit.added))
        try write(next)
    }

    func clear() {
        let removed = effectiveStrokes()
        guard !removed.isEmpty else { return }
        do {
            let edit = Edit(removed: removed, added: [])
            try enqueue(edit)
            undoEdits.append(edit)
            redoEdits.removeAll()
            try rebuild()
        } catch { errorMessage = error.localizedDescription }
    }

    private func inverse(_ edit: Edit) throws -> Edit {
        let active = Set(effectiveStrokes().map(\.id))
        guard edit.added.allSatisfy({ active.contains($0.id) }) else {
            throw PairSync.SyncError.server("Your partner changed those strokes. Undo would overwrite their edit.")
        }
        return Edit(removed: edit.added, added: edit.removed.map {
            SharedStroke(id: UUID().uuidString, drawingData: $0.drawingData, drawingHeight: $0.drawingHeight)
        })
    }
    func undo() {
        guard let edit = undoEdits.last else { return }
        do {
            let reverse = try inverse(edit)
            try enqueue(reverse)
            undoEdits.removeLast()
            redoEdits.append(reverse)
            try rebuild()
        } catch { errorMessage = error.localizedDescription }
    }
    func redo() {
        guard let edit = redoEdits.last else { return }
        do {
            let reverse = try inverse(edit)
            try enqueue(reverse)
            redoEdits.removeLast()
            undoEdits.append(reverse)
            try rebuild()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Called only after the optimistic drawing has been saved to local History.
    func resolveConflict(_ update: BoardUpdate) throws {
        var next = saved
        next.pending = []
        try write(next)
        undoEdits.removeAll()
        redoEdits.removeAll()
        try receive(update)
    }

    /// Match strokes by their public geometry and ink. PKDrawing's opaque archive
    /// can change across serialization, so hashing the archive would create false edits.
    static func fingerprint(_ stroke: PKStroke) -> String {
        var parts: [String] = [stroke.ink.inkType.rawValue]
        func number(_ value: Double) { parts.append(String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), value)) }
        number(stroke.path.creationDate.timeIntervalSinceReferenceDate)
        let color = stroke.ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        for value in [r, g, b, a, stroke.transform.a, stroke.transform.b, stroke.transform.c,
                      stroke.transform.d, stroke.transform.tx, stroke.transform.ty] { number(Double(value)) }
        parts.append(String(stroke.path.count))
        for point in stroke.path {
            for value in [point.location.x, point.location.y, point.size.width, point.size.height,
                          point.opacity, point.force, point.azimuth, point.altitude] { number(Double(value)) }
            number(point.timeOffset)
        }
        if let mask = stroke.mask {
            parts.append(mask.usesEvenOddFillRule ? "mask-even" : "mask-winding")
            mask.cgPath.applyWithBlock { pointer in
                let element = pointer.pointee
                parts.append(String(element.type.rawValue))
                let count: Int
                switch element.type {
                case .moveToPoint, .addLineToPoint: count = 1
                case .addQuadCurveToPoint: count = 2
                case .addCurveToPoint: count = 3
                case .closeSubpath: count = 0
                @unknown default: count = 0
                }
                for index in 0..<count {
                    number(Double(element.points[index].x)); number(Double(element.points[index].y))
                }
            }
        } else { parts.append("no-mask") }
        return SHA256.hash(data: Data(parts.joined(separator: "|").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
