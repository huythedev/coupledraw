import Foundation
import Combine
import PencilKit
import UIKit

@MainActor final class CanvasStore: ObservableObject {
    @Published private(set) var pair: LocalPair
    @Published private(set) var records: [CanvasSlot: CanvasRecord]
    @Published private(set) var revisions: [AppliedRevision]
    @Published private(set) var liveSharedEnabled = false
    @Published private(set) var sharedOwnData: Data
    @Published private(set) var sharedPartnerData: Data
    @Published private(set) var whiteboard: SharedWhiteboard?
    private var boardIdentity: String?
    private var boardChanges: AnyCancellable?
    private var boardErrors: AnyCancellable?
    @Published var errorMessage: String?

    private let root: URL
    private let encoder: JSONEncoder
    private var combinedCache: (base: Data, partner: Data, own: Data, merged: Data)?
    private var readOnlyCache: (base: Data, partner: Data, merged: Data)?

    init(root: URL? = nil) {
        let rootURL = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CoupleDraw", isDirectory: true)
        self.root = rootURL
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let localEncoder = JSONEncoder()
        let localDecoder = JSONDecoder()
        localEncoder.userInfo[.coupleDrawMediaRoot] = rootURL
        localDecoder.userInfo[.coupleDrawMediaRoot] = rootURL
        self.encoder = localEncoder

        let pairURL = rootURL.appendingPathComponent("pair.json")
        let localPair: LocalPair
        if let data = try? Data(contentsOf: pairURL), let saved = try? JSONDecoder().decode(LocalPair.self, from: data) {
            localPair = saved
        } else {
            let mine = UUID(), partner = UUID()
            localPair = LocalPair(myUserID: mine, partnerUserID: partner,
                                  firstCanvasID: UUID(), secondCanvasID: UUID())
        }
        var resolvedPair = localPair
        if resolvedPair.sharedCanvasID == nil { resolvedPair.sharedCanvasID = UUID() }
        self.pair = resolvedPair

        var loaded: [CanvasSlot: CanvasRecord] = [:]
        var readableSlots = Set<CanvasSlot>()
        for slot in CanvasSlot.allCases {
            let url = rootURL.appendingPathComponent("\(slot.rawValue).json")
            if let record = try? LocalMediaFiles.withLock(root: rootURL, {
                try localDecoder.decode(CanvasRecord.self, from: Data(contentsOf: url))
            }) {
                loaded[slot] = record
                readableSlots.insert(slot)
            } else {
                let ownerID = slot == .second ? localPair.partnerUserID : localPair.myUserID
                let canvasID: UUID
                switch slot {
                case .first: canvasID = localPair.firstCanvasID
                case .second: canvasID = localPair.secondCanvasID
                case .together: canvasID = resolvedPair.sharedCanvasID!
                }
                loaded[slot] = CanvasRecord(canvasID: canvasID, ownerID: ownerID)
            }
        }
        self.records = loaded
        self.sharedOwnData = (try? Data(contentsOf: rootURL.appendingPathComponent("shared-own.data"))) ?? Data()
        self.sharedPartnerData = (try? Data(contentsOf: rootURL.appendingPathComponent("shared-partner.data"))) ?? Data()
        let revisionsURL = rootURL.appendingPathComponent("revisions.json")
        let savedRevisions = try? LocalMediaFiles.withLock(root: rootURL, {
            try localDecoder.decode([AppliedRevision].self, from: Data(contentsOf: revisionsURL))
        })
        if let saved = savedRevisions {
            self.revisions = saved
        } else {
            self.revisions = []
        }
        if !FileManager.default.fileExists(atPath: pairURL.path) || localPair.sharedCanvasID == nil {
            try? persist(self.pair, to: pairURL)
        }
        for slot in CanvasSlot.allCases {
            let record = self.record(slot)
            if abs(record.drawingHeight - record.targetSize.drawingHeight) > 0.01 {
                updateTargetSize(record.targetSize, on: slot)
            }
        }
        refreshMineTarget()
        // Upgrade inline photos without deleting the old manifest until its
        // replacement and every referenced file have been written atomically.
        do {
            for slot in readableSlots {
                try persist(record(slot), to: rootURL.appendingPathComponent("\(slot.rawValue).json"))
            }
            if savedRevisions != nil { try persist(revisions, to: revisionsURL) }
            try FileManager.default.createDirectory(at: wallpaperCache, withIntermediateDirectories: true)
            var cacheURL = wallpaperCache
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try cacheURL.setResourceValues(values)
            try LocalMediaFiles.withLock(root: rootURL) {
                for revision in revisions {
                    let old = rootURL.appendingPathComponent(revision.imageFilename)
                    let new = imageURL(for: revision)
                    if FileManager.default.fileExists(atPath: old.path) {
                        if FileManager.default.fileExists(atPath: new.path) {
                            try FileManager.default.removeItem(at: old)
                        } else { try FileManager.default.moveItem(at: old, to: new) }
                    }
                }
            }
        } catch { errorMessage = "Could not migrate local media: \(error.localizedDescription)" }
    }

    func record(_ slot: CanvasSlot) -> CanvasRecord { records[slot]! }

    func displayedRecord(_ slot: CanvasSlot) -> CanvasRecord {
        var result = record(slot)
        if slot == .together, let whiteboard {
            result.drawingData = whiteboard.drawingData
            return result
        }
        if slot == .together && liveSharedEnabled {
            if let cache = combinedCache, cache.base == result.drawingData,
               cache.partner == sharedPartnerData, cache.own == sharedOwnData {
                result.drawingData = cache.merged
            } else {
                let base = result.drawingData
                let merged = mergedDrawing([base, sharedPartnerData, sharedOwnData])
                combinedCache = (base, sharedPartnerData, sharedOwnData, merged)
                result.drawingData = merged
            }
        }
        return result
    }

    func deactivateWhiteboard() {
        whiteboard = nil
        boardIdentity = nil
        boardChanges = nil
        boardErrors = nil
        liveSharedEnabled = false
    }

    func resumeWhiteboard(identity: String) throws {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("whiteboard-\(identity).json").path) {
            try activateWhiteboard(identity: identity)
        }
    }

    func activateWhiteboard(identity: String) throws {
        guard boardIdentity != identity else { return }
        let file = root.appendingPathComponent("whiteboard-\(identity).json")
        if boardIdentity == nil && !FileManager.default.fileExists(atPath: file.path) {
            // Keep the previous local layers as a recovery, without changing the
            // wallpaper returned by Shortcuts. Server layers migrate separately.
            let wasLive = liveSharedEnabled
            liveSharedEnabled = true
            let old = displayedRecord(.together).drawingData
            if let drawing = try? PKDrawing(data: old), !drawing.strokes.isEmpty {
                guard apply(.together, recovery: true) != nil else {
                    liveSharedEnabled = wasLive
                    throw StoreError.imageEncoding
                }
            }
            liveSharedEnabled = wasLive
        }
        let board = try SharedWhiteboard(url: file, height: record(.together).drawingHeight)
        boardChanges = board.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        boardErrors = board.$errorMessage.compactMap { $0 }.sink { [weak self] in self?.errorMessage = $0 }
        whiteboard = board
        boardIdentity = identity
        liveSharedEnabled = true
    }

    var sharedReadOnlyData: Data {
        let base = record(.together).drawingData
        if let cache = readOnlyCache, cache.base == base, cache.partner == sharedPartnerData {
            return cache.merged
        }
        let merged = mergedDrawing([base, sharedPartnerData])
        readOnlyCache = (base, sharedPartnerData, merged)
        return merged
    }

    func enableLiveShared() { if !liveSharedEnabled { liveSharedEnabled = true } }

    func migrateUnappliedSharedCanvas() {
        var base = record(.together)
        guard !base.drawingData.isEmpty else { return }
        let migrated = mergedDrawing([sharedOwnData, base.drawingData])
        updateSharedOwn(migrated)
        guard sharedOwnData == migrated else { return }
        base.drawingData = Data()
        save(base, on: .together)
    }

    func setSharedBase(_ remote: SyncedRevision) throws {
        var base = record(.together)
        base.drawingData = remote.drawingData
        base.drawingHeight = remote.drawingHeight
        base = try rescaled(base, to: base.targetSize)
        if base.drawingData != record(.together).drawingData { save(base, on: .together) }
    }

    func updateSharedOwn(_ data: Data) {
        guard sharedOwnData != data else { return }
        do {
            try data.write(to: root.appendingPathComponent("shared-own.data"), options: .atomic)
            sharedOwnData = data
        } catch { errorMessage = error.localizedDescription }
    }

    func updateSharedOwn(_ data: Data, drawingHeight: Double) throws {
        guard drawingHeight > 0 else { throw StoreError.invalidDrawingSize }
        updateSharedOwn(try scaledDrawing(data, y: record(.together).drawingHeight / drawingHeight))
    }

    func updateSharedPartner(_ data: Data, drawingHeight: Double) throws {
        guard drawingHeight > 0 else { throw StoreError.invalidDrawingSize }
        let resized = try scaledDrawing(data, y: record(.together).drawingHeight / drawingHeight)
        guard sharedPartnerData != resized else { return }
        try resized.write(to: root.appendingPathComponent("shared-partner.data"), options: .atomic)
        sharedPartnerData = resized
    }

    private func mergedDrawing(_ pieces: [Data]) -> Data {
        let strokes = pieces.compactMap { try? PKDrawing(data: $0).strokes }.flatMap { $0 }
        return PKDrawing(strokes: strokes).dataRepresentation()
    }

    private func scaledDrawing(_ data: Data, y ratio: Double) throws -> Data {
        guard !data.isEmpty else { return data }
        let drawing = try PKDrawing(data: data)
        if abs(ratio - 1) < 0.000001 { return data }
        return drawing.transformed(using: CGAffineTransform(scaleX: 1, y: CGFloat(ratio)))
            .dataRepresentation()
    }

    func updateDrawing(_ data: Data, on slot: CanvasSlot) {
        guard var record = records[slot], record.drawingData != data else { return }
        record.drawingData = data
        record.modifiedAt = Date()
        save(record, on: slot)
    }

    func clearCurrentDrawing(on slot: CanvasSlot) {
        guard slot != .second else { return }
        updateDrawing(PKDrawing().dataRepresentation(), on: slot)
    }

    func updateBackground(_ hex: String, on slot: CanvasSlot) {
        guard slot != .second else { return }
        guard var record = records[slot] else { return }
        record.backgroundHex = hex
        record.backgroundPhoto = nil
        record.modifiedAt = Date()
        save(record, on: slot)
    }

    func updateBackgroundPhoto(_ photo: BackgroundPhoto?, on slot: CanvasSlot) {
        guard slot != .second, var record = records[slot] else { return }
        record.backgroundPhoto = photo
        record.modifiedAt = Date()
        save(record, on: slot)
    }

    func updateStickers(_ stickers: [CanvasSticker], on slot: CanvasSlot) {
        guard slot != .second, var record = records[slot] else { return }
        guard stickers.count <= 12, stickers.reduce(0, { $0 + $1.data.count }) <= 1_500_000 else {
            errorMessage = "This canvas is full of stickers. Remove a sticker before adding another."
            return
        }
        record.stickers = stickers
        record.modifiedAt = Date()
        save(record, on: slot)
    }

    func refreshMineTarget() {
        let actual = WallpaperSize.thisIPhone
        if record(.first).targetSize != actual {
            updateTargetSize(actual, on: .first)
        }
        if record(.together).targetSize != actual {
            updateTargetSize(actual, on: .together)
        }
    }

    func updateTargetSize(_ size: WallpaperSize, on slot: CanvasSlot) {
        guard size.isValid else {
            errorMessage = "Enter a valid portrait pixel size."
            return
        }
        do {
            let oldHeight = record(slot).drawingHeight
            var adjusted = try rescaled(record(slot), to: size)
            adjusted.modifiedAt = Date()
            save(adjusted, on: slot)
            if slot == .together {
                updateSharedOwn(try scaledDrawing(sharedOwnData, y: adjusted.drawingHeight / oldHeight))
                try updateSharedPartner(sharedPartnerData, drawingHeight: oldHeight)
            }
        } catch { errorMessage = "Could not resize the editable drawing: \(error.localizedDescription)" }
    }

    private func rescaled(_ original: CanvasRecord, to size: WallpaperSize) throws -> CanvasRecord {
        guard original.drawingHeight > 0 else { throw StoreError.invalidDrawingSize }
        var result = original
        let ratio = size.drawingHeight / original.drawingHeight
        result.drawingData = try scaledDrawing(original.drawingData, y: ratio)
        result.targetSize = size
        result.drawingHeight = size.drawingHeight
        return result
    }

    private func save(_ record: CanvasRecord, on slot: CanvasSlot) {
        // Reject accidental writes to a slot owned by the other canvas.
        let expected: UUID
        switch slot {
        case .first: expected = pair.firstCanvasID
        case .second: expected = pair.secondCanvasID
        case .together: expected = pair.sharedCanvasID!
        }
        guard record.canvasID == expected else {
            errorMessage = "Canvas ID mismatch. No changes were saved."
            return
        }
        do {
            try persist(record, to: root.appendingPathComponent("\(slot.rawValue).json"))
            records[slot] = record
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult func apply(_ slot: CanvasSlot, recovery: Bool = false) -> URL? {
        if slot == .first { refreshMineTarget() }
        let record = displayedRecord(slot)
        let revisionID = UUID()
        let filename = "\(revisionID.uuidString).png"
        let url = wallpaperCache.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: wallpaperCache, withIntermediateDirectories: true)
            let image = try WallpaperRenderer.render(record)
            guard let png = image.pngData() else { throw StoreError.imageEncoding }
            try png.write(to: url, options: .atomic)
            let revision = AppliedRevision(id: revisionID, canvasID: record.canvasID,
                                           authorID: pair.myUserID, createdAt: Date(),
                                           document: record, imageFilename: filename, recovery: recovery ? true : nil)
            let updated = [revision] + revisions
            try persist(updated, to: root.appendingPathComponent("revisions.json"))
            revisions = updated
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func imageURL(for revision: AppliedRevision) -> URL {
        wallpaperCache.appendingPathComponent("\(revision.id.uuidString).png")
    }

    private var wallpaperCache: URL { root.appendingPathComponent("wallpaper-cache", isDirectory: true) }

    func cachedWallpaperURL(for revision: AppliedRevision) throws -> URL {
        try LocalMediaFiles.withLock(root: root) {
            let url = imageURL(for: revision)
            if !FileManager.default.fileExists(atPath: url.path) {
                let image = try WallpaperRenderer.render(revision.document)
                guard let png = image.pngData() else { throw StoreError.imageEncoding }
                try FileManager.default.createDirectory(at: wallpaperCache, withIntermediateDirectories: true)
                try png.write(to: url, options: .atomic)
            }
            return url
        }
    }

    private func removableCacheFiles() throws -> [URL] {
        let fm = FileManager.default
        // Read every persisted reference, including canvases changed by a
        // Shortcut since this in-memory store was opened. Abort on corrupt JSON.
        var used = Set<String>()
        func collect(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let file = dict["file"] as? String { used.insert(file) }
                dict.values.forEach(collect)
            } else if let array = value as? [Any] { array.forEach(collect) }
        }
        let manifests = CanvasSlot.allCases.map { root.appendingPathComponent("\($0.rawValue).json") }
            + [root.appendingPathComponent("revisions.json")]
        for url in manifests where fm.fileExists(atPath: url.path) {
            collect(try JSONSerialization.jsonObject(with: Data(contentsOf: url)))
        }
        let cached = (try? fm.contentsOfDirectory(at: wallpaperCache, includingPropertiesForKeys: nil)) ?? []
        let legacy = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        let media = (try? fm.contentsOfDirectory(at: LocalMediaFiles.folder(root), includingPropertiesForKeys: nil)) ?? []
        return cached.filter { $0.pathExtension == "png" } + legacy
            + media.filter { !used.contains($0.lastPathComponent) }
    }

    var cacheBytes: Int64 {
        (try? LocalMediaFiles.withLock(root: root) {
            try removableCacheFiles().reduce(Int64(0)) { total, url in
                total + Int64((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            }
        }) ?? 0
    }

    @discardableResult func clearCache() throws -> Int64 {
        try LocalMediaFiles.withLock(root: root) {
            var removed: Int64 = 0
            for url in try removableCacheFiles() {
                let bytes = Int64((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
                try FileManager.default.removeItem(at: url)
                removed += bytes
            }
            BackgroundPhotoLayout.clearImageCache()
            return removed
        }
    }

    func deleteAllRevisions(on slot: CanvasSlot) {
        let canvasID = record(slot).canvasID
        let removed = revisions.filter { $0.canvasID == canvasID }
        guard !removed.isEmpty else { return }
        let retained = revisions.filter { $0.canvasID != canvasID }
        do {
            try persist(retained, to: root.appendingPathComponent("revisions.json"))
            revisions = retained
            for revision in removed {
                try? FileManager.default.removeItem(at: imageURL(for: revision))
            }
        } catch { errorMessage = "Could not delete revisions: \(error.localizedDescription)" }
    }

    /// A server revision is copied into this device's canvas ID, then rendered
    /// for this device. The remote snapshot never overwrites another slot.
    func acceptRemote(_ remote: SyncedRevision, on slot: CanvasSlot, localRole: String,
                      keepSharedBase: Bool = false, keepSharedBackground: Bool = false) throws {
        var incoming = record(slot)
        incoming.backgroundHex = remote.backgroundHex
        incoming.backgroundPhoto = remote.backgroundPhoto
        incoming.stickers = remote.stickers ?? []
        incoming.drawingData = remote.drawingData
        incoming.drawingHeight = remote.drawingHeight
        incoming = try rescaled(incoming, to: incoming.targetSize)
        incoming.modifiedAt = Date()
        let image = try WallpaperRenderer.render(incoming)
        guard let png = image.pngData() else { throw StoreError.imageEncoding }
        let revisionID = UUID()
        let filename = "\(revisionID.uuidString).png"
        let url = wallpaperCache.appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: wallpaperCache, withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
        let revision = AppliedRevision(id: revisionID, canvasID: incoming.canvasID,
                                       authorID: remote.author == localRole ? pair.myUserID : pair.partnerUserID,
                                       createdAt: Date(), document: incoming, imageFilename: filename)
        do {
            try persist([revision] + revisions, to: root.appendingPathComponent("revisions.json"))
            if slot == .together && keepSharedBase {
                var base = record(.together)
                if !keepSharedBackground {
                    base.backgroundHex = incoming.backgroundHex
                    base.backgroundPhoto = incoming.backgroundPhoto
                    base.stickers = incoming.stickers
                }
                save(base, on: slot)
            } else {
                save(incoming, on: slot)
            }
            revisions.insert(revision, at: 0)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func restore(_ revision: AppliedRevision, to slot: CanvasSlot) {
        guard revision.canvasID == record(slot).canvasID else {
            errorMessage = "This revision belongs to another canvas."
            return
        }
        do {
            var restored = try rescaled(revision.document, to: record(slot).targetSize)
            restored.modifiedAt = Date()
            save(restored, on: slot)
        } catch { errorMessage = "Could not restore the drawing: \(error.localizedDescription)" }
        // Restoring edits the document. Tap Apply to publish a fresh revision.
    }

    private func persist<T: Encodable>(_ value: T, to url: URL) throws {
        try LocalMediaFiles.withLock(root: root) {
            try encoder.encode(value).write(to: url, options: .atomic)
        }
    }

    enum StoreError: LocalizedError {
        case imageEncoding, invalidDrawingSize
        var errorDescription: String? {
            switch self {
            case .imageEncoding: return "Could not encode the wallpaper image."
            case .invalidDrawingSize: return "Invalid drawing dimensions."
            }
        }
    }
}
