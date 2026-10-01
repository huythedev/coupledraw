import PencilKit
import SwiftUI

final class FittedCanvasView: PKCanvasView {
    // This canvas edits strokes, not text. Keep PencilKit's responder behavior
    // for lasso selection without presenting a software keyboard.
    private let blankInputView = UIView(frame: .zero)
    override var inputView: UIView? { blankInputView }

    var collaborative = false
    override var undoManager: UndoManager? { collaborative ? nil : super.undoManager }

    var onPasteImages: (([NSItemProvider]) -> Void)?

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        if onPasteImages != nil, itemProviders.contains(where: StickerImages.canLoad) { return true }
        return super.canPaste(itemProviders)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        if let onPasteImages, itemProviders.contains(where: StickerImages.canLoad) {
            onPasteImages(itemProviders)
        } else { super.paste(itemProviders: itemProviders) }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), onPasteImages != nil, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        // Keep PencilKit's native stroke paste when the clipboard isn't an image.
        if super.canPerformAction(#selector(paste(_:)), withSender: sender) {
            super.paste(sender)
        } else if let onPasteImages, UIPasteboard.general.hasImages {
            onPasteImages(UIPasteboard.general.itemProviders)
        } else { super.paste(sender) }
    }

    var drawingAreaSize: CGSize = .zero {
        didSet {
            guard drawingAreaSize != oldValue else { return }
            contentSize = drawingAreaSize
            needsFit = true
            setNeedsLayout()
        }
    }
    private var needsFit = true

    override func layoutSubviews() {
        super.layoutSubviews()
        guard needsFit, bounds.width > 0, bounds.height > 0,
              drawingAreaSize.width > 0, drawingAreaSize.height > 0 else { return }
        needsFit = false
        let fit = min(bounds.width / drawingAreaSize.width,
                      bounds.height / drawingAreaSize.height)
        minimumZoomScale = fit
        maximumZoomScale = max(4, fit * 4)
        zoomScale = fit
        contentOffset = .zero
    }
}

enum DrawingTool: String, CaseIterable, Identifiable {
    case pen, pencil, marker, eraser, pixelEraser, lasso
    var id: String { rawValue }
    var isInk: Bool { self == .pen || self == .pencil || self == .marker }
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .marker: return "highlighter"
        case .eraser: return "eraser"
        case .pixelEraser: return "eraser.fill"
        case .lasso: return "lasso"
        }
    }
    var label: String {
        switch self {
        case .pixelEraser: return "Pixel erase"
        default: return rawValue.capitalized
        }
    }
}

struct CanvasViewport: Equatable {
    let visible: CGRect // fractions of the full canvas, each from 0 to 1
    let zoom: CGFloat // 1 is fitted to the screen

    static func current(_ view: PKCanvasView, drawingSize: CGSize) -> CanvasViewport? {
        guard view.zoomScale > 0, view.minimumZoomScale > 0,
              drawingSize.width > 0, drawingSize.height > 0 else { return nil }
        let raw = CGRect(x: view.contentOffset.x / view.zoomScale / drawingSize.width,
                         y: view.contentOffset.y / view.zoomScale / drawingSize.height,
                         width: view.bounds.width / view.zoomScale / drawingSize.width,
                         height: view.bounds.height / view.zoomScale / drawingSize.height)
        let left = min(max(raw.minX, 0), 1)
        let top = min(max(raw.minY, 0), 1)
        let right = min(max(raw.maxX, 0), 1)
        let bottom = min(max(raw.maxY, 0), 1)
        return CanvasViewport(visible: CGRect(x: left, y: top,
                                              width: max(0, right - left),
                                              height: max(0, bottom - top)),
                              zoom: view.zoomScale / view.minimumZoomScale)
    }
}

struct DrawingSurface: UIViewRepresentable {
    let drawingData: Data
    let drawingSize: CGSize
    let tool: DrawingTool
    let color: UIColor
    let width: CGFloat
    let onChange: (Data) -> Void
    let onReady: (PKCanvasView) -> Void
    var onViewportChange: ((CanvasViewport) -> Void)? = nil
    var collaborative = false
    var onToolBegin: (() -> Void)? = nil
    var onToolEnd: ((Data) -> Void)? = nil
    var onPasteImages: (([NSItemProvider]) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeUIView(context: Context) -> PKCanvasView {
        let view = FittedCanvasView()
        // PencilKit remaps ink for Dark Mode unless the canvas uses a fixed style.
        // Wallpaper backgrounds and shared ink colors must look the same on both phones.
        view.overrideUserInterfaceStyle = .light
        view.collaborative = collaborative
        view.onPasteImages = onPasteImages
        view.backgroundColor = .clear
        view.isOpaque = false
        view.drawingPolicy = .anyInput
        view.contentInsetAdjustmentBehavior = .never
        view.drawingAreaSize = drawingSize
        view.bouncesZoom = true
        view.drawing = (try? PKDrawing(data: drawingData)) ?? PKDrawing()
        context.coordinator.lastInputData = drawingData
        context.coordinator.displayedData = view.drawing.dataRepresentation()
        view.delegate = context.coordinator
        context.coordinator.onToolBegin = onToolBegin
        context.coordinator.onToolEnd = onToolEnd
        context.coordinator.onReady = onReady
        context.coordinator.onViewportChange = onViewportChange
        context.coordinator.applyTool(to: view, tool: tool, color: color, width: width)
        DispatchQueue.main.async {
            onReady(view)
            view.becomeFirstResponder()
            context.coordinator.reportViewport(view)
        }
        return view
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {
        (view as? FittedCanvasView)?.drawingAreaSize = drawingSize
        (view as? FittedCanvasView)?.collaborative = collaborative
        (view as? FittedCanvasView)?.onPasteImages = onPasteImages
        context.coordinator.onChange = onChange
        context.coordinator.onToolBegin = onToolBegin
        context.coordinator.onToolEnd = onToolEnd
        context.coordinator.onReady = onReady
        context.coordinator.onViewportChange = onViewportChange
        context.coordinator.applyTool(to: view, tool: tool, color: color, width: width)
        let coordinator = context.coordinator
        if !coordinator.usingTool && coordinator.lastInputData != drawingData {
            // Keep the input archive separately: PencilKit may re-encode it.
            // Reassigning an unchanged drawing can dismiss a lasso selection.
            if coordinator.displayedData != drawingData {
                coordinator.applyingRemote = true
                view.drawing = (try? PKDrawing(data: drawingData)) ?? PKDrawing()
                coordinator.displayedData = view.drawing.dataRepresentation()
                coordinator.applyingRemote = false
            }
            coordinator.lastInputData = drawingData
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onChange: (Data) -> Void
        var onReady: ((PKCanvasView) -> Void)?
        var onViewportChange: ((CanvasViewport) -> Void)?
        var displayedData: Data?
        var lastInputData: Data?
        var usingTool = false
        var applyingRemote = false
        var onToolBegin: (() -> Void)?
        var onToolEnd: ((Data) -> Void)?
        private var lastViewport: CanvasViewport?
        private var selectedTool: DrawingTool?
        private var selectedColor: UIColor?
        private var selectedWidth: CGFloat?
        init(onChange: @escaping (Data) -> Void) { self.onChange = onChange }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !applyingRemote else { return }
            let data = canvasView.drawing.dataRepresentation()
            guard data != displayedData else { return }
            displayedData = data
            onChange(data)
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            usingTool = true
            onToolBegin?()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            usingTool = false
            let data = canvasView.drawing.dataRepresentation()
            displayedData = data
            onToolEnd?(data)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) { reportViewport(scrollView) }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { reportViewport(scrollView) }

        func reportViewport(_ scrollView: UIScrollView) {
            guard let view = scrollView as? PKCanvasView,
                  let fitted = view as? FittedCanvasView,
                  let viewport = CanvasViewport.current(view, drawingSize: fitted.drawingAreaSize),
                  viewport != lastViewport else { return }
            lastViewport = viewport
            DispatchQueue.main.async { [weak self] in self?.onViewportChange?(viewport) }
        }

        func applyTool(to view: PKCanvasView, tool: DrawingTool, color: UIColor, width: CGFloat) {
            guard selectedTool != tool ||
                    (tool.isInk && (selectedColor?.isEqual(color) != true || selectedWidth != width)) else { return }
            selectedTool = tool
            selectedColor = color
            selectedWidth = width
            switch tool {
            case .pen: view.tool = PKInkingTool(.pen, color: color, width: width)
            case .pencil: view.tool = PKInkingTool(.pencil, color: color, width: width)
            case .marker: view.tool = PKInkingTool(.marker, color: color, width: width)
            case .eraser: view.tool = PKEraserTool(.vector)
            case .pixelEraser: view.tool = PKEraserTool(.bitmap)
            case .lasso: view.tool = PKLassoTool()
            }
        }
    }
}
