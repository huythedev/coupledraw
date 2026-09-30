import SwiftUI
import UIKit

struct PairingView: View {
    @EnvironmentObject private var store: CanvasStore
    @EnvironmentObject private var sync: PairSync
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var token = ""
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.20:8787", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Your A or B pairing token", text: $token)
                        .textInputAutocapitalization(.never)
                    Button(busy ? "Connecting…" : "Connect") {
                        busy = true
                        Task {
                            do {
                                try await sync.configure(endpoint: endpoint, token: token, store: store)
                                await sync.enablePartnerAlerts()
                                if sync.ntfyTopic == nil { dismiss() }
                            } catch { message = error.localizedDescription }
                            busy = false
                        }
                    }.disabled(busy)
                } header: {
                    Text("Connect both phones")
                } footer: {
                    Text("Enter the server address and this phone's A or B token. Use the other token on your partner's phone.")
                }
                if sync.configured {
                    if let topic = sync.ntfyTopic {
                        Section("Alerts through ntfy") {
                            Text("Install the ntfy iPhone app and subscribe to this topic on \(sync.ntfyBaseURL ?? "https://ntfy.sh"). Use your own topic on each phone.")
                                .font(.footnote)
                            Text(topic).font(.footnote.monospaced()).textSelection(.enabled)
                            Button("Copy my ntfy topic") { UIPasteboard.general.string = topic }
                            Text("Keep this topic private. On iOS 27, use a Shortcuts Notification trigger from the ntfy app with the title ‘CoupleDraw wallpaper ready’.")
                                .font(.footnote)
                        }
                    }
                    Section("Partner alerts") {
                        Button(sync.pushCapable ? "Enable partner Apply alerts" : "Enable alerts while app is open") {
                            Task { await sync.enablePartnerAlerts() }
                        }
                        Text(sync.notificationsStatus).font(.footnote)
                        Text(sync.pushCapable ?
                             "With APNs configured, your partner's Apply sends a push alert. iOS 27 Shortcuts can filter it by the title ‘CoupleDraw wallpaper ready’." :
                             "With Personal Team signing, the app shows a local alert after it notices a partner Apply while open. For closed-app alerts, subscribe to your private ntfy topic above.")
                            .font(.footnote)
                    }
                }
                Section("How syncing works") {
                    Text("Keep the Python service running on your Mac or VPS. Use a private-network HTTP address for local testing or HTTPS for a public server.")
                    Text("While both apps are open, Our art shares each person's strokes live. Either person can Apply the combined art. The sync status shows whether the server supports live waiting.")
                        .foregroundStyle(.secondary)
                }
                if sync.configured {
                    Section("Resolve a conflicting local draft") {
                        ForEach(CanvasSlot.allCases) { slot in
                            Button(slot == .together && store.liveSharedEnabled ?
                                   "Replace my Our art strokes with server copy" :
                                   "Replace \(slot.rawValue) with server copy") {
                                Task { await sync.takeServerCopy(slot, store: store) }
                            }
                        }
                        Text("This discards unpublished local edits on that canvas. Applied revisions remain in History.")
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Pair with partner")
            .toolbar { Button("Done") { dismiss() } }
            .onAppear { endpoint = sync.endpoint }
            .alert("Could not connect", isPresented: Binding(get: { !message.isEmpty }, set: { if !$0 { message = "" } })) {
                Button("OK") { message = "" }
            } message: { Text(message) }
        }
    }
}
