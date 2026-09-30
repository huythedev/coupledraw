import PencilKit
import SwiftUI

/// A large editing workspace for the selected editable canvas. Changes are
/// saved through the same CanvasStore as the compact preview.
struct FullScreenCanvasView: View {
    @EnvironmentObject private var store: CanvasStore
    @EnvironmentObject private var sync: PairSync
    @Environment(\.dismiss) private var dismiss
    let slot: CanvasSlot
    @Binding var tool: DrawingTool
    @Binding var inkColor: Color
    @Binding var size: Double
    @State private var canvasView: PKCanvasView?
    @State private var showClearConfirmation = false
    @State private var showPhotoEditor = false
    @State private var viewport: CanvasViewport?

    private var record: CanvasRecord { store.displayedRecord(slot) }
    private var shared: Bool { slot == .together && store.whiteboard != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.title).font(.headline)
                    Text(shared ? "Draw, move or erase any stroke · syncs after each stroke" :
                         "Two fingers to move or zoom")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) { showClearConfirmation = true } label: {
                    Label(shared ? "Clear all" : "Clear", systemImage: "trash")
                }
                .accessibilityLabel(shared ? "Clear all shared strokes" : "Clear drawing")
                .buttonStyle(.bordered)
                Button("Done") { dismiss() }.fontWeight(.semibold)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            if shared {
                Text((store.whiteboard?.hasPending == true ? "Saving edits · " : "") + sync.status)
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.bottom, 6)
            }
            GeometryReader { geometry in
                let drawingSize = record.drawingSize
                let fit = min(geometry.size.width / drawingSize.width,
                              geometry.size.height / drawingSize.height)
                ZStack {
                    ZoomedCanvasBackground(photo: record.backgroundPhoto,
                                           color: record.backgroundHex,
                                           viewport: viewport)
                    DrawingSurface(drawingData: record.drawingData,
                                   drawingSize: drawingSize,
                                   tool: tool,
                                   color: UIColor(inkColor).resolvedColor(
                                       with: UITraitCollection(userInterfaceStyle: .light)),
                                   width: size,
                                   onChange: { data in
                                       if shared {
                                           store.whiteboard?.drawingChanged(data)
                                           sync.scheduleSharedDraft(store: store)
                                       } else if store.record(slot).drawingData != data {
                                           store.updateDrawing(data, on: slot)
                                           sync.markDirty(slot)
                                       }
                                   }, onReady: { canvasView = $0 },
                                   onViewportChange: { viewport = $0 },
                                   collaborative: shared,
                                   onToolBegin: { if shared { store.whiteboard?.beginEditing() } },
                                   onToolEnd: { data in
                                       if shared {
                                           store.whiteboard?.endEditing(data)
                                           sync.scheduleSharedDraft(store: store)
                                       }
                                   })
                    .id("\(record.canvasID.uuidString)-\(record.drawingHeight)-\(shared)")
                }
                .frame(width: drawingSize.width * fit, height: drawingSize.height * fit)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(.gray, lineWidth: 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .overlay(alignment: .topTrailing) {
                if let viewport, viewport.zoom > 1.05 {
                    navigator(viewport)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }

            VStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(DrawingTool.allCases) { option in
                            Button { tool = option } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: option.symbol).font(.title3)
                                    Text(option.label).font(.caption2.weight(.medium))
                                }
                                .frame(minWidth: 62)
                                .padding(.vertical, 8)
                                .foregroundStyle(option == tool ? Color.white : Color.primary)
                                .background(option == tool ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground),
                                            in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(option == tool ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal)
                }

                HStack(spacing: 12) {
                    if tool.isInk {
                        ColorPicker("Ink color", selection: $inkColor).labelsHidden()
                        Slider(value: $size, in: 2...36)
                            .accessibilityLabel("Stroke size")
                        Text("\(Int(size))").font(.caption.monospacedDigit()).frame(width: 28)
                    } else {
                        Text(tool == .lasso ? "Circle strokes to select and move them" : "Drag over strokes to erase")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        if shared { store.whiteboard?.undo(); sync.scheduleSharedDraft(store: store) }
                        else { canvasView?.undoManager?.undo() }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .accessibilityLabel("Undo")
                    Button {
                        if shared { store.whiteboard?.redo(); sync.scheduleSharedDraft(store: store) }
                        else { canvasView?.undoManager?.redo() }
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .accessibilityLabel("Redo")
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)

                HStack(spacing: 12) {
                    Button { showPhotoEditor = true } label: {
                        Label("Photo", systemImage: "photo")
                    }
                    .buttonStyle(.bordered)
                    if record.backgroundPhoto == nil {
                        Button { setBackground("#000000") } label: {
                            Circle().fill(.black).frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(.gray, lineWidth: 1))
                        }
                        .accessibilityLabel("Black background")
                        Button { setBackground("#FFFFFF") } label: {
                            Circle().fill(.white).frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(.gray, lineWidth: 1))
                        }
                        .accessibilityLabel("White background")
                        ColorPicker("Custom canvas color", selection: backgroundBinding).labelsHidden()
                    } else {
                        Text("Photo background").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Fit") {
                        if let canvasView {
                            canvasView.setZoomScale(canvasView.minimumZoomScale, animated: true)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 12)
            .background(Color(uiColor: .systemBackground))
        }
        .background(Color(uiColor: .systemBackground))
        .onDisappear {
            if shared, let canvasView, store.whiteboard?.isEditing == true {
                store.whiteboard?.endEditing(canvasView.drawing.dataRepresentation())
                sync.scheduleSharedDraft(store: store)
            }
        }
        .sheet(isPresented: $showPhotoEditor) {
            BackgroundPhotoEditor(slot: slot)
                .environmentObject(store).environmentObject(sync)
        }
        .confirmationDialog(shared ? "Clear all strokes from Our art?" :
                            "Clear all strokes from \(slot.title)?",
                            isPresented: $showClearConfirmation) {
            Button(shared ? "Clear all strokes" : "Clear drawing", role: .destructive) {
                if shared {
                    store.whiteboard?.clear()
                    sync.scheduleSharedDraft(store: store)
                } else {
                    store.clearCurrentDrawing(on: slot)
                    sync.markDirty(slot)
                }
            }
        } message: {
            Text(shared ? "This clears all strokes from the shared board on both phones. The background and saved History remain. You can Undo this while no one has changed those strokes." :
                 "This clears the current editable drawing on this phone. The background and saved History remain. Tap Apply to share the empty drawing.")
        }
        .alert("Could not save", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "Unknown error") }
    }

    private func setBackground(_ hex: String) {
        store.updateBackground(hex, on: slot)
        sync.markDirty(slot)
    }

    private func navigator(_ viewport: CanvasViewport) -> some View {
        let size = record.drawingSize
        let width: CGFloat = 72
        let height = width * size.height / size.width
        return VStack(spacing: 5) {
            Text("\(Int(viewport.zoom * 100))% · position")
                .font(.caption2.bold()).monospacedDigit()
            ZStack(alignment: .topLeading) {
                BackgroundPhotoView(photo: record.backgroundPhoto,
                                    color: record.backgroundHex)
                CanvasArtworkView(drawingData: record.drawingData,
                                  drawingSize: size)
                    .equatable()
                Rectangle()
                    .fill(Color.accentColor.opacity(0.16))
                    .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 2))
                    .frame(width: max(2, viewport.visible.width * width),
                           height: max(2, viewport.visible.height * height))
                    .offset(x: viewport.visible.minX * width,
                            y: viewport.visible.minY * height)
            }
            .frame(width: width, height: height)
            .clipped()
            .overlay(Rectangle().strokeBorder(.white, lineWidth: 1))
        }
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .shadow(radius: 4)
        .accessibilityLabel("Canvas position at \(Int(viewport.zoom * 100)) percent zoom")
    }

    private var backgroundBinding: Binding<Color> {
        Binding(get: { Color(UIColor(hex: record.backgroundHex)) }, set: { value in
            let ui = UIColor(value)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            let hex = String(format: "#%02X%02X%02X", Int(red * 255),
                             Int(green * 255), Int(blue * 255))
            setBackground(hex)
        })
    }
}
