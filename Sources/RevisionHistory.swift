import SwiftUI

struct RevisionHistory: View {
    @EnvironmentObject private var store: CanvasStore
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteAllConfirmation = false
    @State private var sharedImage: SharedWallpaper?
    let slot: CanvasSlot

    private var revisions: [AppliedRevision] {
        store.revisions.filter { $0.canvasID == store.record(slot).canvasID }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(revisions) { revision in
                    HStack {
                        RevisionThumbnail(revision: revision)
                        VStack(alignment: .leading) {
                            if revision.recovery == true {
                                Text("Recovered draft").font(.caption.bold())
                            }
                            Text(revision.createdAt, style: .date)
                            Text(revision.createdAt, style: .time).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            do { sharedImage = SharedWallpaper(url: try store.cachedWallpaperURL(for: revision)) }
                            catch { store.errorMessage = error.localizedDescription }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share wallpaper manually")
                        if slot != .second && !(slot == .together && store.liveSharedEnabled) {
                            Button("Restore") {
                                store.restore(revision, to: slot)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .overlay {
                if revisions.isEmpty {
                    ContentUnavailableView("No applied revisions yet",
                                           systemImage: "clock",
                                           description: Text("Draw on this canvas and tap Apply to save a revision."))
                }
            }
            .navigationTitle("Applied revisions")
            .sheet(item: $sharedImage) { item in WallpaperShareSheet(url: item.url) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Delete all", role: .destructive) { showDeleteAllConfirmation = true }
                        .disabled(revisions.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Delete all saved revisions of \(slot.title)?",
                                isPresented: $showDeleteAllConfirmation) {
                Button("Delete all revisions", role: .destructive) {
                    store.deleteAllRevisions(on: slot)
                }
            } message: {
                Text("This removes local history and exported images for this canvas. The editable drawing and paired server copy remain. Apply again before running its wallpaper Shortcut.")
            }
            .alert("Could not delete", isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("OK") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "Unknown error") }
        }
    }
}

private struct SharedWallpaper: Identifiable {
    let id = UUID()
    let url: URL
}
private struct WallpaperShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
private struct RevisionThumbnail: View {
    let revision: AppliedRevision
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Color.gray.opacity(0.15) }
        }
        .frame(width: 54, height: 96)
        .task(id: revision.id) {
            let aspect = revision.document.drawingSize.height / revision.document.drawingSize.width
            image = try? WallpaperRenderer.render(revision.document, pixels: CGSize(width: 108, height: 108 * aspect))
        }
    }
}
