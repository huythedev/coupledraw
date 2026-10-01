import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum StickerImages {
    static func prepare(_ image: UIImage) throws -> Data {
        guard image.size.width > 0, image.size.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
        // Rasterize the first frame while keeping transparency and orientation.
        for longest in [CGFloat(1200), 900, 600, 400] {
            let factor = min(1, longest / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.opaque = false
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            if let data = rendered.pngData(), data.count <= 500_000 { return data }
        }
        throw CocoaError(.fileReadTooLarge)
    }

    enum ImportError: LocalizedError {
        case noImage, unreadableImage, canvasFull
        var errorDescription: String? {
            switch self {
            case .noImage: return "Copy the image itself, then tap Paste. Text and image links cannot be used as stickers."
            case .unreadableImage: return "The copied image could not be opened. Try copying it again, or import it from Photos or Files."
            case .canvasFull: return "Remove a sticker before adding another. This canvas can hold up to 12 stickers within its image limit."
            }
        }
    }

    static func canLoad(_ provider: NSItemProvider) -> Bool {
        provider.canLoadObject(ofClass: UIImage.self) ||
            provider.registeredTypeIdentifiers.contains { UTType($0)?.conforms(to: .image) == true }
    }

    static func load(_ providers: [NSItemProvider], completion: @escaping (Result<UIImage, Error>) -> Void) {
        // A copied item may offer text first, or an object representation that
        // fails even though its PNG/JPEG representation is usable. Try both.
        let images = providers.filter(canLoad)
        func finish(_ result: Result<UIImage, Error>) {
            DispatchQueue.main.async { completion(result) }
        }
        guard !images.isEmpty else { finish(.failure(ImportError.noImage)); return }
        func tryProvider(_ index: Int) {
            guard index < images.count else { finish(.failure(ImportError.unreadableImage)); return }
            let provider = images[index]
            let types = provider.registeredTypeIdentifiers.filter { UTType($0)?.conforms(to: .image) == true }
            func tryData(_ typeIndex: Int) {
                guard typeIndex < types.count else { tryProvider(index + 1); return }
                provider.loadDataRepresentation(forTypeIdentifier: types[typeIndex]) { data, _ in
                    if let data, let image = UIImage(data: data) { finish(.success(image)) }
                    else {
                        provider.loadFileRepresentation(forTypeIdentifier: types[typeIndex]) { url, _ in
                            // Item-provider file URLs expire after this callback.
                            if let url, let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                                finish(.success(image))
                            } else { tryData(typeIndex + 1) }
                        }
                    }
                }
            }
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    if let image = object as? UIImage { finish(.success(image)) }
                    else { tryData(0) }
                }
            } else { tryData(0) }
        }
        tryProvider(0)
    }

    static func adding(_ image: UIImage, to stickers: [CanvasSticker]) throws -> [CanvasSticker] {
        guard stickers.count < 12 else { throw ImportError.canvasFull }
        let sticker = CanvasSticker(data: try prepare(image))
        guard stickers.reduce(sticker.data.count, { $0 + $1.data.count }) <= 1_500_000 else {
            throw ImportError.canvasFull
        }
        return stickers + [sticker]
    }

    static func rect(_ sticker: CanvasSticker, imageSize: CGSize, canvas: CGSize) -> CGRect {
        let width = CGFloat(sticker.width) * canvas.width
        let height = width * imageSize.height / max(imageSize.width, 1)
        return CGRect(x: CGFloat(sticker.centerX) * canvas.width - width / 2,
                      y: CGFloat(sticker.centerY) * canvas.height - height / 2,
                      width: width, height: height)
    }
}

struct StickerArtworkView: View {
    let stickers: [CanvasSticker]
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(stickers) { sticker in
                    if let image = BackgroundPhotoLayout.image(sticker.data) {
                        let rect = StickerImages.rect(sticker, imageSize: image.size, canvas: geometry.size)
                        Image(uiImage: image).resizable()
                            .frame(width: rect.width, height: rect.height)
                            .rotationEffect(.degrees(sticker.rotation))
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
    }
}

struct ZoomedStickerArtwork: View {
    let stickers: [CanvasSticker]
    let viewport: CanvasViewport?
    var body: some View {
        GeometryReader { geometry in
            let zoom = max(viewport?.zoom ?? 1, 1)
            let width = geometry.size.width * zoom, height = geometry.size.height * zoom
            StickerArtworkView(stickers: stickers)
                .frame(width: width, height: height)
                .offset(x: -(viewport?.visible.minX ?? 0) * width,
                        y: -(viewport?.visible.minY ?? 0) * height)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
        }
        .allowsHitTesting(false)
    }
}

struct StickerEditor: View {
    @EnvironmentObject private var store: CanvasStore
    @EnvironmentObject private var sync: PairSync
    @Environment(\.dismiss) private var dismiss
    let slot: CanvasSlot
    @State private var stickers: [CanvasSticker] = []
    @State private var selection: UUID?
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showKeyboard = false
    @State private var showFiles = false
    @State private var message = ""
    private var record: CanvasRecord { store.displayedRecord(slot) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Tap a sticker to select it. Drag to move, pinch to resize, and twist to rotate.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                GeometryReader { geometry in
                    let aspect = record.drawingSize.height / record.drawingSize.width
                    let width = min(geometry.size.width, geometry.size.height / aspect)
                    let canvas = CGSize(width: width, height: width * aspect)
                    ZStack {
                        BackgroundPhotoView(photo: record.backgroundPhoto, color: record.backgroundHex)
                        CanvasArtworkView(drawingData: record.drawingData, drawingSize: record.drawingSize)
                            .allowsHitTesting(false)
                        ForEach(stickers) { sticker in
                            StickerHandle(sticker: sticker, canvas: canvas, selected: selection == sticker.id,
                                          select: { selection = sticker.id },
                                          update: { update($0) })
                        }
                    }
                    .frame(width: canvas.width, height: canvas.height)
                    .clipped()
                    .overlay(Rectangle().stroke(.gray, lineWidth: 1))
                    .onDrop(of: [UTType.image.identifier], isTargeted: nil) { providers in
                        guard providers.contains(where: StickerImages.canLoad) else { return false }
                        StickerImages.load(providers, completion: receive)
                        return true
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let selected = stickers.first(where: { $0.id == selection }) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(stickers) { sticker in
                                Button { selection = sticker.id } label: {
                                    if let image = BackgroundPhotoLayout.image(sticker.data) {
                                        Image(uiImage: image).resizable().scaledToFit().frame(width: 36, height: 36)
                                            .padding(4)
                                            .background(sticker.id == selection ? Color.accentColor.opacity(0.2) : .clear,
                                                        in: RoundedRectangle(cornerRadius: 6))
                                    }
                                }.accessibilityLabel("Select sticker")
                            }
                        }.padding(.horizontal)
                    }
                    HStack {
                        Text("Size").font(.caption)
                        Slider(value: Binding(get: { log10(selected.width) }, set: {
                            var sticker = selected; sticker.width = pow(10, $0); update(sticker)
                        }), in: -2...1)
                    }.padding(.horizontal)
                    HStack {
                        Button("Center") {
                            var sticker = selected; sticker.centerX = 0.5; sticker.centerY = 0.5
                            update(sticker)
                        }
                        Button("Reset tilt") { var sticker = selected; sticker.rotation = 0; update(sticker) }
                        Spacer()
                        Button("Delete", role: .destructive) {
                            stickers.removeAll { $0.id == selected.id }
                            selection = stickers.last?.id
                            save()
                        }
                    }.buttonStyle(.bordered).padding(.horizontal)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        PasteStickerControl(onPaste: { StickerImages.load($0, completion: receive) })
                            .frame(width: 110, height: 40)
                        PhotosPicker(selection: $pickedPhoto, matching: .images) {
                            Label("Photos", systemImage: "photo")
                        }
                        Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
                        Button { showKeyboard = true } label: { Label("Keyboard", systemImage: "face.smiling") }
                    }.buttonStyle(.bordered).padding(.horizontal)
                }
                Text("Stickers save with the draft and are shared when you Apply.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .navigationTitle("Stickers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .onAppear { stickers = record.stickers; selection = stickers.last?.id }
            .onChange(of: pickedPhoto) { _, item in
                Task {
                    do {
                        guard let data = try await item?.loadTransferable(type: Data.self),
                              let image = UIImage(data: data) else { return }
                        add(image)
                    } catch { message = error.localizedDescription }
                    pickedPhoto = nil
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    guard let image = UIImage(data: try Data(contentsOf: url)) else { throw CocoaError(.fileReadCorruptFile) }
                    add(image)
                } catch { message = error.localizedDescription }
            }
            .sheet(isPresented: $showKeyboard) {
                KeyboardStickerPanel { image in add(image); showKeyboard = false }
            }
            .alert("Could not add sticker", isPresented: Binding(
                get: { !message.isEmpty }, set: { if !$0 { message = "" } }
            )) { Button("OK") { message = "" } } message: { Text(message) }
        }
    }

    private func add(_ image: UIImage) {
        do {
            stickers = try StickerImages.adding(image, to: stickers)
            selection = stickers.last?.id
            save()
        } catch { message = error.localizedDescription }
    }
    private func receive(_ result: Result<UIImage, Error>) {
        switch result {
        case .success(let image): add(image)
        case .failure(let error): message = error.localizedDescription
        }
    }
    private func update(_ sticker: CanvasSticker) {
        guard let index = stickers.firstIndex(where: { $0.id == sticker.id }) else { return }
        stickers[index] = sticker; save()
    }
    private func save() { store.updateStickers(stickers, on: slot); sync.markDirty(slot) }
}

private struct StickerHandle: View {
    let sticker: CanvasSticker
    let canvas: CGSize
    let selected: Bool
    let select: () -> Void
    let update: (CanvasSticker) -> Void
    @GestureState private var transform = StickerTransform()

    var body: some View {
        if let image = BackgroundPhotoLayout.image(sticker.data) {
            let rect = StickerImages.rect(sticker, imageSize: image.size, canvas: canvas)
            Image(uiImage: image).resizable()
                .frame(width: rect.width, height: rect.height)
                .overlay(Rectangle().stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                .scaleEffect(transform.scale)
                .rotationEffect(.degrees(sticker.rotation) + transform.angle)
                .position(x: rect.midX + transform.translation.width, y: rect.midY + transform.translation.height)
                .onTapGesture(perform: select)
                .gesture(DragGesture().simultaneously(with: MagnificationGesture())
                    .simultaneously(with: RotationGesture())
                    .updating($transform) { value, state, _ in
                        state.translation = value.first?.first?.translation ?? .zero
                        state.scale = value.first?.second ?? 1
                        state.angle = value.second ?? .zero
                    }
                    .onChanged { _ in select() }
                    .onEnded { value in
                        let movement = value.first?.first?.translation ?? .zero
                        var result = sticker
                        result.centerX = min(100, max(-100, result.centerX + Double(movement.width / canvas.width)))
                        result.centerY = min(100, max(-100, result.centerY + Double(movement.height / canvas.height)))
                        result.width = min(10, max(0.01, result.width * Double(value.first?.second ?? 1)))
                        result.rotation = (result.rotation + (value.second?.degrees ?? 0)).truncatingRemainder(dividingBy: 360)
                        update(result)
                    })
        }
    }
}

private struct StickerTransform {
    var translation = CGSize.zero
    var scale: CGFloat = 1
    var angle = Angle.zero
}

struct PasteStickerControl: UIViewRepresentable {
    let onPaste: ([NSItemProvider]) -> Void
    func makeUIView(context: Context) -> StickerPasteReceiver { StickerPasteReceiver(onPaste: onPaste) }
    func updateUIView(_ uiView: StickerPasteReceiver, context: Context) { uiView.onPaste = onPaste }
}

final class StickerPasteReceiver: UIView {
    var onPaste: ([NSItemProvider]) -> Void
    init(onPaste: @escaping ([NSItemProvider]) -> Void) {
        self.onPaste = onPaste
        super.init(frame: .zero)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier])
        let control = UIPasteControl()
        control.target = self
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([control.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     control.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     control.topAnchor.constraint(equalTo: topAnchor),
                                     control.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        itemProviders.contains(where: StickerImages.canLoad)
    }
    override func paste(itemProviders: [NSItemProvider]) {
        onPaste(itemProviders)
    }
}

private struct KeyboardStickerPanel: View {
    let onImage: (UIImage) -> Void
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard stickers").font(.headline)
            Text("Switch to the emoji keyboard and choose a sticker. You can also paste an image here.")
                .font(.footnote).foregroundStyle(.secondary)
            StickerKeyboardInput(onImage: onImage, onText: { text = $0 })
                .frame(height: 100)
            Button("Add typed emoji") {
                let string = String(text.prefix(8)) as NSString
                let font = UIFont.systemFont(ofSize: 150)
                let size = string.size(withAttributes: [.font: font])
                guard size.width > 0, size.height > 0 else { return }
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                onImage(UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    string.draw(at: .zero, withAttributes: [.font: font])
                })
            }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("Supported keyboard stickers become a still image. If a keyboard only provides text or a link, copy its image and use Paste.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .presentationDetents([.medium, .large])
    }
}

private struct StickerKeyboardInput: UIViewRepresentable {
    let onImage: (UIImage) -> Void
    let onText: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage, onText: onText) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .systemFont(ofSize: 50)
        view.allowsEditingTextAttributes = true
        view.pasteConfiguration = UIPasteConfiguration(forAccepting: UIImage.self)
        if #available(iOS 18.0, *) { view.supportsAdaptiveImageGlyph = true }
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 12
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }
    func updateUIView(_ uiView: UITextView, context: Context) {}

    final class Coordinator: NSObject, UITextViewDelegate {
        let onImage: (UIImage) -> Void
        let onText: (String) -> Void
        private var delivered = false
        init(onImage: @escaping (UIImage) -> Void, onText: @escaping (String) -> Void) {
            self.onImage = onImage; self.onText = onText
        }
        func textViewDidChange(_ textView: UITextView) {
            guard !delivered else { return }
            var image: UIImage?
            let text = textView.attributedText ?? NSAttributedString(string: "")
            text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, stop in
                if let attachment = attributes[.attachment] as? NSTextAttachment {
                    image = attachment.image
                    if image == nil, let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents {
                        image = UIImage(data: data)
                    }
                }
                if #available(iOS 18.0, *), let glyph = attributes[.adaptiveImageGlyph] as? NSAdaptiveImageGlyph {
                    image = UIImage(data: glyph.imageContent)
                }
                if image != nil { stop.pointee = true }
            }
            if let image {
                delivered = true
                textView.resignFirstResponder()
                DispatchQueue.main.async { self.onImage(image) }
            } else { onText(textView.text ?? "") }
        }
    }
}
