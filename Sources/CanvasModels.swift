import Foundation
import CryptoKit
import Darwin
import UIKit

/// The destination is always explicit; UI labels never serve as persistent IDs.
enum CanvasSlot: String, Codable, CaseIterable, Identifiable, Hashable {
    case first, second, together
    var id: String { rawValue }
    var title: String {
        switch self {
        case .first: return "My art"
        case .second: return "Partner's art"
        case .together: return "Our art"
        }
    }
    var help: String {
        switch self {
        case .first: return "Only you publish this drawing. Your partner can choose to show it on their phone."
        case .second: return "Your partner publishes this drawing. You can view it and choose it for your phone."
        case .together: return "Both can draw, move and erase shared strokes while the apps are open. Finished strokes sync live; either person can Apply the board for both phones."
        }
    }
}

enum WallpaperChoice: String, CaseIterable, Identifiable {
    case own, partner, together
    var id: String { rawValue }
    var label: String {
        switch self {
        case .own: return "My art"
        case .partner: return "Partner's art"
        case .together: return "Our art"
        }
    }
    var slot: CanvasSlot {
        switch self {
        case .own: return .first
        case .partner: return .second
        case .together: return .together
        }
    }
}

struct WallpaperSize: Codable, Equatable {
    let width: Int
    let height: Int

    var isValid: Bool { width >= 320 && height > width && width <= 5000 && height <= 10000 }
    var pixels: CGSize { CGSize(width: CGFloat(width), height: CGFloat(height)) }
    var drawingHeight: Double { 390.0 * Double(height) / Double(width) }

    static var thisIPhone: WallpaperSize {
        let native = UIScreen.main.nativeBounds.size
        return WallpaperSize(width: Int(min(native.width, native.height)),
                             height: Int(max(native.width, native.height)))
    }
}

struct CanvasRecord: Codable, Equatable {
    let canvasID: UUID
    let ownerID: UUID
    var backgroundHex: String
    var backgroundPhoto: BackgroundPhoto?
    var stickers: [CanvasSticker] = []
    /// PKDrawing's editable vector data. It is not a wallpaper screenshot.
    var drawingData: Data
    var modifiedAt: Date
    var targetSize: WallpaperSize
    /// Drawing coordinates use a width of 390; this height follows targetSize.
    var drawingHeight: Double
    var drawingSize: CGSize { CGSize(width: 390, height: CGFloat(drawingHeight)) }

    init(canvasID: UUID = UUID(), ownerID: UUID, backgroundHex: String = "#000000",
         targetSize: WallpaperSize = .thisIPhone) {
        self.canvasID = canvasID
        self.ownerID = ownerID
        self.backgroundHex = backgroundHex
        self.backgroundPhoto = nil
        self.drawingData = Data()
        self.modifiedAt = Date()
        self.targetSize = targetSize
        self.drawingHeight = targetSize.drawingHeight
    }

    private enum CodingKeys: String, CodingKey {
        case canvasID, ownerID, backgroundHex, backgroundPhoto, stickers, drawingData, modifiedAt, targetSize, drawingHeight
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        canvasID = try box.decode(UUID.self, forKey: .canvasID)
        ownerID = try box.decode(UUID.self, forKey: .ownerID)
        backgroundHex = try box.decode(String.self, forKey: .backgroundHex)
        backgroundPhoto = try box.decodeIfPresent(BackgroundPhoto.self, forKey: .backgroundPhoto)
        stickers = try box.decodeIfPresent([CanvasSticker].self, forKey: .stickers) ?? []
        drawingData = try box.decode(Data.self, forKey: .drawingData)
        modifiedAt = try box.decode(Date.self, forKey: .modifiedAt)
        // Earlier builds used fixed 390 × 844 coordinates. CanvasStore transforms
        // those strokes to the actual phone aspect ratio before editing them.
        targetSize = try box.decodeIfPresent(WallpaperSize.self, forKey: .targetSize) ?? .thisIPhone
        drawingHeight = try box.decodeIfPresent(Double.self, forKey: .drawingHeight) ?? 844
    }
}

/// The original scaled JPEG stays editable; placement is normalized to the
/// portrait canvas so the partner can render it at their own screen size.
struct BackgroundPhoto: Codable, Equatable {
    var data: Data
    var zoom: Double = 1
    var offsetX: Double = 0
    var offsetY: Double = 0
    var rotation: Double = 0

    init(data: Data, zoom: Double = 1, offsetX: Double = 0,
         offsetY: Double = 0, rotation: Double = 0) {
        self.data = data
        self.zoom = zoom
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.rotation = rotation
    }

    private enum CodingKeys: String, CodingKey {
        case data, file, zoom, offsetX, offsetY, rotation
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if let root = decoder.userInfo[.coupleDrawMediaRoot] as? URL,
           let file = try box.decodeIfPresent(String.self, forKey: .file) {
            data = try LocalMediaFiles.read(file, root: root)
        } else {
            data = try box.decode(Data.self, forKey: .data)
        }
        zoom = try box.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        offsetX = try box.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try box.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
        rotation = try box.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        if let root = encoder.userInfo[.coupleDrawMediaRoot] as? URL {
            try box.encode(LocalMediaFiles.store(data, root: root), forKey: .file)
        } else {
            try box.encode(data, forKey: .data)
        }
        try box.encode(zoom, forKey: .zoom)
        try box.encode(offsetX, forKey: .offsetX)
        try box.encode(offsetY, forKey: .offsetY)
        try box.encode(rotation, forKey: .rotation)
    }
}

/// Position and width are fractions of the portrait canvas, independent of pixels.
struct CanvasSticker: Codable, Identifiable, Equatable {
    let id: UUID
    var data: Data
    var centerX: Double
    var centerY: Double
    var width: Double
    var rotation: Double

    init(id: UUID = UUID(), data: Data, centerX: Double = 0.5,
         centerY: Double = 0.5, width: Double = 0.4, rotation: Double = 0) {
        self.id = id; self.data = data; self.centerX = centerX
        self.centerY = centerY; self.width = width; self.rotation = rotation
    }

    private enum CodingKeys: String, CodingKey { case id, data, file, centerX, centerY, width, rotation }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(UUID.self, forKey: .id)
        if let root = decoder.userInfo[.coupleDrawMediaRoot] as? URL,
           let file = try box.decodeIfPresent(String.self, forKey: .file) {
            data = try LocalMediaFiles.read(file, root: root)
        } else { data = try box.decode(Data.self, forKey: .data) }
        centerX = try box.decode(Double.self, forKey: .centerX)
        centerY = try box.decode(Double.self, forKey: .centerY)
        width = try box.decode(Double.self, forKey: .width)
        rotation = try box.decode(Double.self, forKey: .rotation)
    }
    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(id, forKey: .id)
        if let root = encoder.userInfo[.coupleDrawMediaRoot] as? URL {
            try box.encode(LocalMediaFiles.store(data, root: root), forKey: .file)
        } else { try box.encode(data, forKey: .data) }
        try box.encode(centerX, forKey: .centerX); try box.encode(centerY, forKey: .centerY)
        try box.encode(width, forKey: .width); try box.encode(rotation, forKey: .rotation)
    }
}

extension CodingUserInfoKey {
    static let coupleDrawMediaRoot = CodingUserInfoKey(rawValue: "CoupleDraw.mediaRoot")!
}

enum LocalMediaFiles {
    static func identifier(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func folder(_ root: URL) -> URL { root.appendingPathComponent("media", isDirectory: true) }
    static func path(_ ident: String, root: URL) throws -> URL {
        guard ident.count == 64, ident.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return folder(root).appendingPathComponent(ident)
    }
    static func store(_ data: Data, root: URL) throws -> String {
        try FileManager.default.createDirectory(at: folder(root), withIntermediateDirectories: true)
        let ident = identifier(data)
        let url = try path(ident, root: root)
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        return ident
    }
    static func read(_ ident: String, root: URL) throws -> Data {
        let data = try Data(contentsOf: path(ident, root: root))
        guard identifier(data) == ident else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
    /// Serializes manifest changes and media cleanup across app/Shortcut processes.
    static func withLock<T>(root: URL, _ action: () throws -> T) throws -> T {
        let fd = open(root.appendingPathComponent(".storage.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }
}

struct AppliedRevision: Codable, Identifiable {
    let id: UUID
    let canvasID: UUID
    let authorID: UUID
    let createdAt: Date
    let document: CanvasRecord
    let imageFilename: String
    var recovery: Bool? = nil
}

struct LocalPair: Codable {
    let myUserID: UUID
    let partnerUserID: UUID
    let firstCanvasID: UUID
    let secondCanvasID: UUID
    var sharedCanvasID: UUID? = nil

    func slot(for ownerID: UUID) -> CanvasSlot? {
        if ownerID == myUserID { return .first }
        if ownerID == partnerUserID { return .second }
        return nil
    }
}
