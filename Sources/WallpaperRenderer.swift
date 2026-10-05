import PencilKit
import UIKit
import ImageIO
import Darwin

enum WallpaperRenderer {
    static let maximumPixels = 6_000_000
    /// The output is pixel-for-pixel the target device size; the editor uses
    /// the same aspect ratio so there is no fixed 390 × 844 crop or letterbox.
    static func render(_ document: CanvasRecord) throws -> UIImage {
        try render(document, pixels: document.targetSize.pixels)
    }

    static func render(_ document: CanvasRecord, pixels: CGSize, useImageCache: Bool = true) throws -> UIImage {
        guard pixels.width.isFinite, pixels.height.isFinite,
              pixels.width > 0, pixels.height > 0, pixels.width <= 5000, pixels.height <= 10000,
              pixels.width * pixels.height <= CGFloat(maximumPixels) else {
            throw RenderError.invalidSize
        }
        let designSize = document.drawingSize
        guard designSize.height.isFinite, (300...2000).contains(designSize.height) else { throw RenderError.invalidSize }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: pixels, format: format)
        let drawing = document.drawingData.isEmpty
            ? PKDrawing() : try PKDrawing(data: document.drawingData)
        let bounds = CGRect(origin: .zero, size: designSize)
        return renderer.image { context in
            UIColor(hex: document.backgroundHex).setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: pixels))
            autoreleasepool {
                guard let photo = document.backgroundPhoto,
                      let image = BackgroundPhotoLayout.image(photo.data, useCache: useImageCache) else { return }
                context.cgContext.saveGState()
                context.cgContext.clip(to: CGRect(origin: .zero, size: pixels))
                let frame = BackgroundPhotoLayout.rect(
                    imageSize: image.size, canvasSize: pixels,
                    zoom: photo.zoom, offsetX: photo.offsetX, offsetY: photo.offsetY)
                context.cgContext.translateBy(x: frame.midX, y: frame.midY)
                context.cgContext.rotate(by: CGFloat(photo.rotation * .pi / 180))
                image.draw(in: CGRect(x: -frame.width / 2, y: -frame.height / 2,
                                      width: frame.width, height: frame.height))
                context.cgContext.restoreGState()
            }
            let scale = min(pixels.width / designSize.width, pixels.height / designSize.height)
            let fit = CGRect(x: (pixels.width - designSize.width * scale) / 2,
                             y: (pixels.height - designSize.height * scale) / 2,
                             width: designSize.width * scale, height: designSize.height * scale)
            // Match the editor's fixed PencilKit appearance even when this
            // export runs in a Dark Mode app or from a Shortcut.
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                if !drawing.strokes.isEmpty {
                    autoreleasepool { drawing.image(from: bounds, scale: max(scale, 1)).draw(in: fit) }
                }
            }
            context.cgContext.saveGState()
            context.cgContext.clip(to: CGRect(origin: .zero, size: pixels))
            for sticker in document.stickers {
                autoreleasepool {
                    guard let image = BackgroundPhotoLayout.image(sticker.data, useCache: useImageCache) else { return }
                    let rect = StickerImages.rect(sticker, imageSize: image.size, canvas: pixels)
                    context.cgContext.saveGState()
                    context.cgContext.translateBy(x: rect.midX, y: rect.midY)
                    context.cgContext.rotate(by: CGFloat(sticker.rotation * .pi / 180))
                    image.draw(in: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
                    context.cgContext.restoreGState()
                }
            }
            context.cgContext.restoreGState()
        }
    }

    /// Encode to disk without allocating a second, complete PNG Data buffer.
    static func writePNG(_ document: CanvasRecord, pixels: CGSize? = nil,
                         to url: URL, useImageCache: Bool = true) throws {
        try autoreleasepool {
            let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let image = try render(document, pixels: pixels ?? document.targetSize.pixels, useImageCache: useImageCache)
            guard let bitmap = image.cgImage,
                  let destination = CGImageDestinationCreateWithURL(temporary as CFURL, "public.png" as CFString, 1, nil) else {
                throw RenderError.imageEncoding
            }
            CGImageDestinationAddImage(destination, bitmap, nil)
            guard CGImageDestinationFinalize(destination), rename(temporary.path, url.path) == 0 else {
                throw RenderError.imageEncoding
            }
        }
    }

    enum RenderError: Error { case invalidSize, imageEncoding }
}

extension UIColor {
    convenience init(hex: String) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: CGFloat((value >> 16) & 255) / 255,
                  green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
