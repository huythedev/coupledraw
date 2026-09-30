import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var store: CanvasStore
    @EnvironmentObject private var sync: PairSync
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("wallpaperChoice") private var wallpaperChoice = WallpaperChoice.own.rawValue
    @State private var slot: CanvasSlot = .first
    @State private var tool: DrawingTool = .pen
    @State private var inkColor: Color = .white
    @State private var size: Double = 6
    @State private var appliedToast: String?
    @State private var toastID: UUID?
    @State private var applying = false
    @State private var showHistory = false
    @State private var showSetup = false
    @State private var showTarget = false
    @State private var showPairing = false
    @State private var showFullScreen = false

    private var record: CanvasRecord { store.displayedRecord(slot) }
    private var editable: Bool { slot != .second }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Make a little space together").font(.title2.bold())
                        Text("Draw on a canvas, then choose what this phone shows.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    canvasSection
                    lockScreenSection
                    destinations
                    syncStatus
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .overlay(alignment: .top) {
                if let appliedToast {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appliedToast).font(.subheadline.bold())
                            Text("Run your Shortcut to update the wallpaper")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                }
            }
            .navigationTitle("CoupleDraw")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { if editable { actionBar } }
        }
        .onAppear {
            sync.prepareForLockedShortcuts()
            store.refreshMineTarget()
            sync.start(store: store)
            Task { await sync.resumePartnerAlerts() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                sync.prepareForLockedShortcuts()
                store.refreshMineTarget()
                sync.start(store: store)
                Task { await sync.resumePartnerAlerts() }
            }
            if phase == .inactive { sync.stop() }
            if phase == .background { sync.suspend() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .coupleDrawPushToken)) { _ in
            Task { await sync.sendDeviceRegistration() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .coupleDrawPushFailure)) { event in
            sync.notificationsStatus = "Push registration failed: \(event.object as? String ?? "Unknown error")"
        }
        .onOpenURL { url in
            guard url.scheme == "coupledraw", url.host == "open" else { return }
            toastID = nil
            appliedToast = nil
            showHistory = false
            showSetup = false
            showTarget = false
            showPairing = false
            showFullScreen = false
            slot = .first
        }
        .sheet(isPresented: $showHistory) { RevisionHistory(slot: slot) }
        .sheet(isPresented: $showSetup) { WallpaperSetupView() }
        .sheet(isPresented: $showTarget) { PartnerTargetView() }
        .sheet(isPresented: $showPairing) { PairingView() }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenCanvasView(slot: slot, tool: $tool, inkColor: $inkColor, size: $size)
                .environmentObject(store).environmentObject(sync)
        }
        .alert("Could not save", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "Unknown error") }
    }

    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Canvas", systemImage: "scribble.variable").font(.headline)
            Picker("Canvas", selection: $slot) {
                ForEach(CanvasSlot.allCases) { option in Text(option.title).tag(option) }
            }
            .pickerStyle(.segmented)
            Text(slot.help).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            preview
            HStack {
                let target = record.targetSize
                Label("\(target.width) × \(target.height) px", systemImage: "iphone")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if slot == .second {
                    Button("Preview size") { showTarget = true }
                        .font(.caption.weight(.semibold))
                } else {
                    Label("Tap to draw", systemImage: "hand.tap")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20))
    }

    private var preview: some View {
        Group {
            if slot == .second && !sync.hasPartnerArt {
                ContentUnavailableView("Waiting for your partner",
                                       systemImage: "heart.text.square",
                                       description: Text("Pair your phones, then ask your partner to Apply their art."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let drawingSize = record.drawingSize
                    let fit = min(geometry.size.width / drawingSize.width,
                                  geometry.size.height / drawingSize.height)
                    ZStack {
                        BackgroundPhotoView(photo: record.backgroundPhoto,
                                            color: record.backgroundHex)
                        CanvasArtworkView(drawingData: record.drawingData,
                                          drawingSize: drawingSize)
                            .equatable()
                    }
                    .frame(width: drawingSize.width * fit, height: drawingSize.height * fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if editable { showFullScreen = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(editable ? "Open \(slot.title) drawing editor" : "Partner's art preview")
        .accessibilityAddTraits(editable ? .isButton : .isImage)
        .frame(height: 350)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private var lockScreenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("My Lock Screen shows", systemImage: "lock.iphone").font(.headline)
            Picker("Wallpaper source", selection: $wallpaperChoice) {
                ForEach(WallpaperChoice.allCases) { choice in
                    Text(choice.label).tag(choice.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Text(wallpaperExplanation).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20))
    }

    private var destinations: some View {
        HStack(spacing: 8) {
            destination("History", symbol: "clock.arrow.circlepath") { showHistory = true }
            destination("Pair", symbol: "person.2") { showPairing = true }
            destination("Setup", symbol: "gearshape") { showSetup = true }
        }
    }

    private func destination(_ title: String, symbol: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private var syncStatus: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text(sync.status).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button { showFullScreen = true } label: {
                Label("Draw", systemImage: "pencil.tip.crop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button { applyDrawing() } label: {
                Label("Apply", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(applying)
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var wallpaperExplanation: String {
        let choice = WallpaperChoice(rawValue: wallpaperChoice) ?? .own
        if choice == .partner && !sync.hasPartnerArt {
            return "Waiting for your partner to Apply. This choice is only for this iPhone."
        }
        return "Your Shortcut uses \(choice.label). Changing canvases above does not change this choice."
    }

    private func applyDrawing() {
        let selected = slot
        Task { @MainActor in
            guard !applying else { return }
            applying = true
            defer { applying = false }
            if selected == .together, store.whiteboard != nil {
                guard await sync.applyWhiteboard(store: store) else { return }
            } else {
                guard store.apply(selected) != nil else { return }
                let snapshot = store.displayedRecord(selected)
                sync.markDirty(selected)
                await sync.publish(snapshot, slot: selected, store: store)
            }
            let id = UUID()
            toastID = id
            withAnimation(.easeInOut(duration: 0.25)) { appliedToast = "\(selected.title) applied" }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard toastID == id else { return }
            withAnimation(.easeInOut(duration: 0.25)) { appliedToast = nil }
            toastID = nil
        }
    }
}
