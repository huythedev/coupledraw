import ImageIO
import SwiftUI

enum BackgroundPhotoLayout {
    private static let imageCache = NSCache<NSData, UIImage>()
    static func clearImageCache() { imageCache.removeAllObjects() }

    static func image(_ data: Data) -> UIImage? {
        let key = data as NSData
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let decoded = UIImage(data: data) else { return nil }
        imageCache.setObject(decoded, forKey: key)
        return decoded
    }

    static func rect(imageSize: CGSize, canvasSize: CGSize, zoom: Double,
                     offsetX: Double, offsetY: Double) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
        let cover = max(canvasSize.width / imageSize.width,
                        canvasSize.height / imageSize.height)
        let factor = cover * CGFloat(min(max(zoom, 0.1), 5))
        let width = imageSize.width * factor
        let height = imageSize.height * factor
        let x = CGFloat(offsetX) * canvasSize.width
        let y = CGFloat(offsetY) * canvasSize.height
        return CGRect(x: (canvasSize.width - width) / 2 + x,
                      y: (canvasSize.height - height) / 2 + y,
                      width: width, height: height)
    }

    static func importJPEG(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PhotoError.invalidImage
        }
        for dimension in [2600, 2200, 1800, 1500] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw PhotoError.invalidImage
            }
            let image = UIImage(cgImage: thumbnail)
            for quality in [0.8, 0.67, 0.54] {
                if let jpeg = image.jpegData(compressionQuality: quality), jpeg.count <= 900_000 {
                    return jpeg
                }
            }
        }
        throw PhotoError.tooLarge
    }

    enum PhotoError: LocalizedError {
        case invalidImage, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "This photo could not be opened. Try a different image."
            case .tooLarge: return "This photo is too large to prepare. Try a smaller image."
            }
        }
    }
}

struct BackgroundPhotoView: View {
    let photo: BackgroundPhoto?
    let color: String

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(UIColor(hex: color))
                if let photo, let image = BackgroundPhotoLayout.image(photo.data) {
                    let frame = BackgroundPhotoLayout.rect(
                        imageSize: image.size, canvasSize: geometry.size,
                        zoom: photo.zoom, offsetX: photo.offsetX, offsetY: photo.offsetY)
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .rotationEffect(.degrees(photo.rotation))
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }
}

/// Follow PencilKit's scroll viewport so the image and the editable strokes
/// stay registered while the user zooms and pans the canvas.
struct ZoomedCanvasBackground: View {
    let photo: BackgroundPhoto?
    let color: String
    let viewport: CanvasViewport?

    var body: some View {
        GeometryReader { geometry in
            let zoom = max(viewport?.zoom ?? 1, 1)
            let width = geometry.size.width * zoom
            let height = geometry.size.height * zoom
            BackgroundPhotoView(photo: photo, color: color)
                .frame(width: width, height: height)
                .offset(x: -(viewport?.visible.minX ?? 0) * width,
                        y: -(viewport?.visible.minY ?? 0) * height)
                .frame(width: geometry.size.width, height: geometry.size.height,
                       alignment: .topLeading)
                .clipped()
        }
    }
}
