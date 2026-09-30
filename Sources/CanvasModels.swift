import Foundation
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
        case canvasID, ownerID, backgroundHex, backgroundPhoto, drawingData, modifiedAt, targetSize, drawingHeight
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        canvasID = try box.decode(UUID.self, forKey: .canvasID)
        ownerID = try box.decode(UUID.self, forKey: .ownerID)
        backgroundHex = try box.decode(String.self, forKey: .backgroundHex)
        backgroundPhoto = try box.decodeIfPresent(BackgroundPhoto.self, forKey: .backgroundPhoto)
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
        case data, zoom, offsetX, offsetY, rotation
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        data = try box.decode(Data.self, forKey: .data)
        zoom = try box.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        offsetX = try box.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try box.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
        rotation = try box.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
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
