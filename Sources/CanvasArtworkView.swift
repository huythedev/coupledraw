import PencilKit
import SwiftUI

/// Read-only previews render the complete document bounds. A PKCanvasView is a
/// scroll view and can retain an offset or zoom, clipping strokes in thumbnails.
struct CanvasArtworkView: View, Equatable {
    let drawingData: Data
    let drawingSize: CGSize

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.drawingSize == rhs.drawingSize && lhs.drawingData == rhs.drawingData
    }

    var body: some View {
        GeometryReader { geometry in
            if let image = Self.image(data: drawingData, size: drawingSize) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .allowsHitTesting(false)
    }

    static func image(data: Data, size: CGSize) -> UIImage? {
        guard !data.isEmpty, size.width > 0, size.height > 0,
              let drawing = try? PKDrawing(data: data) else { return nil }
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: CGRect(origin: .zero, size: size), scale: 1)
        }
        return image
    }
}

/// Place read-only shared strokes under the local PencilKit canvas using the
/// same viewport as the background photo.
struct ZoomedCanvasArtworkView: View {
    let drawingData: Data
    let drawingSize: CGSize
    let viewport: CanvasViewport?

    var body: some View {
        GeometryReader { geometry in
            let zoom = max(viewport?.zoom ?? 1, 1)
            let width = geometry.size.width * zoom
            let height = geometry.size.height * zoom
            CanvasArtworkView(drawingData: drawingData, drawingSize: drawingSize)
                .equatable()
                .frame(width: width, height: height)
                .offset(x: -(viewport?.visible.minX ?? 0) * width,
                        y: -(viewport?.visible.minY ?? 0) * height)
                .frame(width: geometry.size.width, height: geometry.size.height,
                       alignment: .topLeading)
                .clipped()
        }
        .allowsHitTesting(false)
    }
}
