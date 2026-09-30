import SwiftUI

struct RevisionHistory: View {
    @EnvironmentObject private var store: CanvasStore
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteAllConfirmation = false
    let slot: CanvasSlot

    private var revisions: [AppliedRevision] {
        store.revisions.filter { $0.canvasID == store.record(slot).canvasID }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(revisions) { revision in
                    HStack {
                        Image(uiImage: UIImage(contentsOfFile: store.imageURL(for: revision).path) ?? UIImage())
                            .resizable().scaledToFit().frame(width: 54, height: 96)
                        VStack(alignment: .leading) {
                            if revision.recovery == true {
                                Text("Recovered draft").font(.caption.bold())
                            }
                            Text(revision.createdAt, style: .date)
                            Text(revision.createdAt, style: .time).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShareLink(item: store.imageURL(for: revision),
                                  preview: SharePreview("CoupleDraw Wallpaper")) {
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
