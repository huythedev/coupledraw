import AVFoundation
import PhotosUI
import PencilKit
import SwiftUI
import UniformTypeIdentifiers

struct BackgroundPhotoEditor: View {
    @EnvironmentObject private var store: CanvasStore
    @EnvironmentObject private var sync: PairSync
    @Environment(\.dismiss) private var dismiss
    let slot: CanvasSlot

    @State private var photo: BackgroundPhoto?
    @State private var initialized = false
    @State private var selectedItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var cameraDenied = false
    @State private var loading = false
    @State private var errorMessage: String?
    @GestureState private var drag = CGSize.zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var rotation = Angle.zero

    private var record: CanvasRecord { store.displayedRecord(slot) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Drag to move, pinch to zoom, and twist to rotate the photo. The frame shows what will appear on the wallpaper. Your strokes stay in place.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                GeometryReader { outer in
                    let drawingSize = record.drawingSize
                    let fit = min(outer.size.width / drawingSize.width,
                                  outer.size.height / drawingSize.height)
                    let canvasSize = CGSize(width: drawingSize.width * fit,
                                            height: drawingSize.height * fit)
                    photoCanvas(size: canvasSize)
                        .frame(width: canvasSize.width, height: canvasSize.height)
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal)

                if photo != nil {
                    HStack {
                        Image(systemName: "minus.magnifyingglass")
                        Slider(value: Binding(get: { photo?.zoom ?? 1 }, set: { value in
                            photo?.zoom = value
                        }), in: 0.1...5)
                        .accessibilityLabel("Photo zoom")
                        Image(systemName: "plus.magnifyingglass")
                        Text("\(Int((photo?.zoom ?? 1) * 100))%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                    .padding(.horizontal)
                    HStack {
                        Image(systemName: "rotate.left")
                        Slider(value: Binding(get: { photo?.rotation ?? 0 }, set: { value in
                            photo?.rotation = value
                        }), in: -180...180)
                        .accessibilityLabel("Photo rotation")
                        Image(systemName: "rotate.right")
                        Text("\(Int(photo?.rotation ?? 0))°")
                            .font(.caption.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                        Button("Reset") {
                            photo?.zoom = 1
                            photo?.offsetX = 0
                            photo?.offsetY = 0
                            photo?.rotation = 0
                        }
                    }
                    .padding(.horizontal)
                }

                HStack(spacing: 8) {
                    Button { openCamera() } label: {
                        Label("Camera", systemImage: "camera")
                    }
                    .buttonStyle(.bordered)
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { showFileImporter = true } label: {
                        Label("Files", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    if photo != nil {
                        Button(role: .destructive) { photo = nil } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Remove photo")
                    }
                }
                .font(.subheadline)
                .disabled(loading)
                .padding(.bottom, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Frame background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        store.updateBackgroundPhoto(photo, on: slot)
                        if store.errorMessage == nil {
                            sync.markDirty(slot)
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(loading)
                }
            }
            .onAppear {
                if !initialized { photo = record.backgroundPhoto; initialized = true }
            }
            .onChange(of: selectedItem) { _, item in
                guard let item else { return }
                loading = true
                Task { @MainActor in
                    do {
                        guard let bytes = try await item.loadTransferable(type: Data.self) else {
                            throw BackgroundPhotoLayout.PhotoError.invalidImage
                        }
                        await prepare(bytes)
                    } catch {
                        errorMessage = error.localizedDescription
                        loading = false
                    }
                    selectedItem = nil
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraCapture(onCapture: { bytes in
                    showCamera = false
                    loading = true
                    Task { @MainActor in await prepare(bytes) }
                }, onCancel: { showCamera = false }, onFailure: {
                    showCamera = false
                    errorMessage = "Could not read the captured photo. Please try again."
                })
                .ignoresSafeArea()
            }
            .alert("Camera access is off", isPresented: $cameraDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Allow camera access in Settings to take a background photo. You can also choose Photos or Files.")
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let bytes = try Data(contentsOf: url)
                    loading = true
                    Task { @MainActor in await prepare(bytes) }
                } catch { errorMessage = error.localizedDescription }
            }
            .overlay { if loading { ProgressView("Preparing photo…").padding().background(.regularMaterial) } }
            .alert("Could not load photo", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK") { errorMessage = nil } } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
        .presentationDetents([.large])
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "This device has no available camera. Choose Photos or Files instead."
            return
        }
        Task { @MainActor in
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: showCamera = true
            case .notDetermined:
                if await AVCaptureDevice.requestAccess(for: .video) { showCamera = true }
                else { cameraDenied = true }
            default: cameraDenied = true
            }
        }
    }

    @MainActor private func prepare(_ bytes: Data) async {
        do {
            let jpeg = try await Task.detached(priority: .userInitiated) {
                try BackgroundPhotoLayout.importJPEG(bytes)
            }.value
            photo = BackgroundPhoto(data: jpeg)
        } catch { errorMessage = error.localizedDescription }
        loading = false
    }

    private func photoCanvas(size: CGSize) -> some View {
        ZStack {
            Color(UIColor(hex: record.backgroundHex))
            if let photo, let image = BackgroundPhotoLayout.image(photo.data) {
                let zoom = min(max(photo.zoom * Double(pinch), 0.1), 5)
                let frame = BackgroundPhotoLayout.rect(
                    imageSize: image.size, canvasSize: size, zoom: zoom,
                    offsetX: photo.offsetX + Double(drag.width / size.width),
                    offsetY: photo.offsetY + Double(drag.height / size.height))
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .rotationEffect(.degrees(photo.rotation + rotation.degrees))
                    .position(x: frame.midX, y: frame.midY)
            }
            CanvasArtworkView(drawingData: record.drawingData,
                              drawingSize: record.drawingSize)
                .equatable()
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                photo?.offsetX += Double(value.translation.width / size.width)
                photo?.offsetY += Double(value.translation.height / size.height)
            }
        )
        .simultaneousGesture(MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in
                photo?.zoom = min(max((photo?.zoom ?? 1) * Double(value), 0.1), 5)
            }
        )
        .simultaneousGesture(RotationGesture()
            .updating($rotation) { value, state, _ in state = value }
            .onEnded { value in
                photo?.rotation = ((photo?.rotation ?? 0) + value.degrees)
                    .truncatingRemainder(dividingBy: 360)
            }
        )
    }
}
