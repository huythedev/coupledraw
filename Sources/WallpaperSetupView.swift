import SwiftUI

struct WallpaperSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var backgroundExperiment: BackgroundLocationExperiment

    var body: some View {
        NavigationStack {
            Form {
                Section("1 · Draw and apply") {
                    Label("Choose My art or Our art on the main screen, tap Draw, then tap Apply after editing.",
                          systemImage: "pencil.tip")
                    Text("Apply saves a revision and sends it to your partner when paired.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("2 · Choose this phone's wallpaper") {
                    Label("Under My Lock Screen shows, choose My art, Partner's art, or Our art.",
                          systemImage: "lock.iphone")
                    Text("This choice is separate from the canvas you are editing.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("3 · Create a Shortcut") {
                    Text("Add Get My CoupleDraw Wallpaper → Set Wallpaper. Pass its image to Set Wallpaper and select Lock Screen.")
                    Text("If Set Wallpaper offers Show Preview, turn it off. Run the Shortcut once and grant any first-use permissions. Test it before adding an automation.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Optional automation") {
                    Text("An App → Is Closed automation can run the tested Shortcut after you leave CoupleDraw. An ntfy notification automation may react to partner updates. iOS controls whether these run while locked and whether Set Wallpaper asks for confirmation.")
                        .font(.footnote)
                    Text("The Shortcut checks the paired service when invoked. While CoupleDraw is open, a waiting connection receives partner changes promptly. Older servers are checked about every 30 seconds.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Open from the Lock Screen") {
                    Text("Long-press the Lock Screen → Customize → Lock Screen → Add Widgets → CoupleDraw. Tap the widget to open the editor; iOS may ask you to unlock first.")
                        .font(.footnote)
                }
                Section("Advanced · Background sync experiment") {
                    Toggle("Try background location sync", isOn: Binding(
                        get: { backgroundExperiment.enabled },
                        set: { backgroundExperiment.setEnabled($0) }))
                    Text(backgroundExperiment.message).font(.footnote).foregroundStyle(.secondary)
                    if backgroundExperiment.canRequestAlways {
                        Button("Request Always access") { backgroundExperiment.requestAlwaysAccess() }
                    }
                    Text("This may show location indicators and use substantial battery. Coordinates are discarded. iOS can still stop polling; location cannot set wallpaper or trigger Shortcuts.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Wallpaper setup")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
