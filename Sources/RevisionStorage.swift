import Foundation

/// App storage lives in the app sandbox. A future extension must explicitly
/// migrate this root to an entitled App Group before sharing it.
enum CoupleDrawStorage {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoupleDraw", isDirectory: true)
    }
}

enum RevisionStorage {
    private struct Signature: Codable, Equatable {
        let size: Int
        let modified: Date?
    }
    private struct Index: Codable {
        let revision: AppliedRevision
        let history: Signature?
        let generation: UInt64
    }
    private struct Header: Decodable { let canvasID: UUID; let recovery: Bool? }
    static func pendingFolder(_ root: URL) -> URL { root.appendingPathComponent("pending-history", isDirectory: true) }
    static func indexURL(_ slot: CanvasSlot, root: URL) -> URL { root.appendingPathComponent("latest-\(slot.rawValue).json") }
    private static func historyURL(_ root: URL) -> URL { root.appendingPathComponent("revisions.json") }
    private static func counterURL(_ root: URL) -> URL { root.appendingPathComponent("history-sequence") }

    static func pendingURLs(root: URL) throws -> [URL] {
        let folder = pendingFolder(root)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func generation(_ root: URL) throws -> UInt64 {
        let url = counterURL(root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return try pendingURLs(root: root).first.flatMap { UInt64($0.lastPathComponent.prefix(20)) } ?? 0
        }
        guard let string = String(data: try Data(contentsOf: url), encoding: .utf8),
              let value = UInt64(string) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    private static func signature(_ root: URL) throws -> Signature? {
        let url = historyURL(root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Signature(size: values.fileSize ?? 0, modified: values.contentModificationDate)
    }

    // All callers hold LocalMediaFiles.withLock across their storage transaction.
    static func updateIndex(_ revision: AppliedRevision, slot: CanvasSlot, root: URL, encoder: JSONEncoder) throws {
        guard revision.recovery != true else { return }
        let value = Index(revision: revision, history: try signature(root), generation: try generation(root))
        try LocalMediaFiles.writeDurably(encoder.encode(value), to: indexURL(slot, root: root))
    }

    static func enqueue(_ revision: AppliedRevision, root: URL, encoder: JSONEncoder) throws -> URL {
        let (next, overflow) = try generation(root).addingReportingOverflow(1)
        guard !overflow else { throw CocoaError(.fileWriteUnknown) }
        let folder = pendingFolder(root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try LocalMediaFiles.writeDurably(Data(String(next).utf8), to: counterURL(root))
        let name = String(format: "%020llu", next) + "-" + revision.id.uuidString + ".json"
        let url = folder.appendingPathComponent(name)
        try LocalMediaFiles.writeDurably(encoder.encode(revision), to: url)
        return url
    }

    static func mergePending(_ saved: [AppliedRevision], root: URL,
                             decoder: JSONDecoder, encoder: JSONEncoder) throws -> [AppliedRevision] {
        let files = try pendingURLs(root: root)
        guard !files.isEmpty else { return saved }
        let incoming = try files.map { try decoder.decode(AppliedRevision.self, from: Data(contentsOf: $0)) }
        var seen = Set<UUID>()
        let merged = (incoming + saved).filter { seen.insert($0.id).inserted }
        // Keep the journal until the normal History manifest is durable.
        try LocalMediaFiles.writeDurably(encoder.encode(merged), to: historyURL(root))
        for url in files { try? FileManager.default.removeItem(at: url) }
        return merged
    }

    static func latest(slot: CanvasSlot, canvasID: UUID, root: URL,
                       decoder: JSONDecoder, encoder: JSONEncoder) throws -> AppliedRevision? {
        let currentSignature = try signature(root), currentGeneration = try generation(root)
        let index = indexURL(slot, root: root)
        if let data = try? Data(contentsOf: index),
           let saved = try? decoder.decode(Index.self, from: data), saved.revision.canvasID == canvasID,
           saved.history == currentSignature, saved.generation == currentGeneration, saved.revision.recovery != true {
            return saved.revision
        }
        for url in try pendingURLs(root: root) {
            let data = try Data(contentsOf: url)
            let header = try JSONDecoder().decode(Header.self, from: data)
            if header.canvasID == canvasID && header.recovery != true {
                let revision = try decoder.decode(AppliedRevision.self, from: data)
                try updateIndex(revision, slot: slot, root: root, encoder: encoder)
                return revision
            }
        }
        if let revision = try firstApplied(at: historyURL(root), canvasID: canvasID, decoder: decoder) {
            try updateIndex(revision, slot: slot, root: root, encoder: encoder)
            return revision
        }
        return nil
    }

    /// Legacy History migration reads one JSON object at a time, not the entire
    /// array. Original media is decoded only for the first matching revision.
    static func firstApplied(at url: URL, canvasID: UUID, decoder: JSONDecoder) throws -> AppliedRevision? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let stream = InputStream(url: url) else { throw CocoaError(.fileReadUnknown) }
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var object = Data(), depth = 0, quoted = false, escaped = false
        var opened = false, expectsObject = true, hasObject = false
        while true {
            let count = stream.read(&buffer, maxLength: 64 * 1024)
            if count < 0 { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
            if count == 0 { throw CocoaError(.fileReadCorruptFile) }
            for byte in buffer.prefix(count) {
                if !opened {
                    if [9, 10, 13, 32].contains(byte) { continue }
                    guard byte == 91 else { throw CocoaError(.fileReadCorruptFile) }
                    opened = true
                    continue
                }
                if depth == 0 {
                    if [9, 10, 13, 32].contains(byte) { continue }
                    if byte == 93 {
                        guard !hasObject || !expectsObject else { throw CocoaError(.fileReadCorruptFile) }
                        return nil
                    }
                    if byte == 44 && !expectsObject { expectsObject = true; continue }
                    guard byte == 123 && expectsObject else { throw CocoaError(.fileReadCorruptFile) }
                    object.removeAll(keepingCapacity: true)
                    depth = 1
                    quoted = false
                    escaped = false
                    object.append(byte)
                    continue
                }
                object.append(byte)
                guard object.count <= 12_000_000 else { throw CocoaError(.fileReadCorruptFile) }
                if quoted {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { quoted = false }
                } else if byte == 34 { quoted = true }
                else if byte == 123 || byte == 91 { depth += 1 }
                else if byte == 125 || byte == 93 { depth -= 1 }
                if depth == 0 {
                    let header = try JSONDecoder().decode(Header.self, from: object)
                    if header.canvasID == canvasID && header.recovery != true {
                        return try decoder.decode(AppliedRevision.self, from: object)
                    }
                    expectsObject = false
                    hasObject = true
                }
            }
        }
    }
}
