import SwiftUI

struct PartnerTargetView: View {
    @EnvironmentObject private var store: CanvasStore
    @Environment(\.dismiss) private var dismiss
    @State private var width = ""
    @State private var height = ""
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Partner iPhone screen, in pixels") {
                    TextField("Width", text: $width).keyboardType(.numberPad)
                    TextField("Height", text: $height).keyboardType(.numberPad)
                    Text("Use portrait pixel dimensions. Existing drawing strokes are scaled to the new height and kept editable.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Use this iPhone's size for testing") {
                        let size = WallpaperSize.thisIPhone
                        width = String(size.width)
                        height = String(size.height)
                    }
                    Button("Save partner target") {
                        guard let w = Int(width), let h = Int(height) else {
                            invalid = true
                            return
                        }
                        let size = WallpaperSize(width: w, height: h)
                        guard size.isValid else { invalid = true; return }
                        store.updateTargetSize(size, on: .second)
                        if store.errorMessage == nil { dismiss() }
                    }
                }
                Section {
                    Text("This only changes the preview on your phone. The Shortcut renders the selected wallpaper at the receiving iPhone's size.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Partner target")
            .toolbar { Button("Cancel") { dismiss() } }
            .onAppear {
                let target = store.record(.second).targetSize
                width = String(target.width)
                height = String(target.height)
            }
            .alert("Invalid dimensions", isPresented: $invalid) {
                Button("OK", role: .cancel) { }
            } message: { Text("Enter portrait pixel dimensions, such as 1179 × 2556.") }
        }
    }
}
