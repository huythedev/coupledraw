import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

struct PairingView: View {
    var invitation: PairingInvite? = nil
    @EnvironmentObject private var store: CanvasStore
    @EnvironmentObject private var sync: PairSync
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var endpoint = PairSync.defaultEndpoint
    @State private var mode = PairingAttempt.Kind.create
    @State private var code = ""
    @State private var token = ""
    @State private var message = ""
    @State private var busy = false
    @State private var retryID = UUID()
    @State private var pairingFailed = false
    @State private var connectingAnother = false

    private var watchID: String {
        guard scenePhase == .active, !busy, let attempt = sync.pairingAttempt else { return "idle" }
        return attempt.secret + retryID.uuidString
    }

    var body: some View {
        NavigationStack {
            Form {
                if sync.configured && sync.pairingAttempt == nil && !connectingAnother {
                    Section {
                        Label("Connected with your partner", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(sync.endpoint).font(.footnote).textSelection(.enabled)
                        Button("Connect with another partner") { connectingAnother = true }
                    }
                } else {
                    Section("Server") {
                        TextField(PairSync.defaultEndpoint, text: $endpoint)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .disabled(sync.pairingAttempt != nil || busy)
                        Text("Use draw.huythedev.com, or enter your own server. Both phones must use the same server.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let attempt = sync.pairingAttempt {
                        pendingSection(attempt)
                    } else {
                        Section {
                            Picker("Pairing", selection: $mode) {
                                Text("Create Pair").tag(PairingAttempt.Kind.create)
                                Text("Join Pair").tag(PairingAttempt.Kind.join)
                            }.pickerStyle(.segmented)
                            if mode == .join {
                                TextField("482 731", text: $code)
                                    .keyboardType(.numberPad)
                                    .textContentType(.oneTimeCode)
                                    .font(.title2.monospaced())
                            }
                            Button {
                                do {
                                    pairingFailed = false
                                    try sync.beginPairing(mode, endpoint: endpoint, code: code)
                                } catch { message = error.localizedDescription }
                            } label: {
                                Label(mode == .create ? "Create Pair" : "Join Pair",
                                      systemImage: mode == .create ? "person.badge.plus" : "person.2")
                            }.disabled(busy || (mode == .join && PairSync.normalizedPairingCode(code) == nil))
                        } footer: {
                            Text(mode == .create ?
                                 "Create a code and share it with your partner. It expires in 5 minutes and can be used once." :
                                 "Enter your partner's six-digit code, or open their invite link. Private credentials are saved automatically.")
                        }
                    }
                }
                if sync.pairingAttempt == nil {
                    Section {
                        DisclosureGroup("Manual pairing with an existing token") {
                            TextField("Server address", text: $endpoint)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            SecureField("This phone's existing A or B token", text: $token)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button(busy ? "Connecting…" : "Connect with token") { connectManually() }
                                .disabled(busy || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Text("For pairs created with the server's create-pair command. Each phone uses its own token.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
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
                    Text("Our art shares completed strokes while both apps are open. Apply saves a wallpaper version for both phones.")
                    Text("When the app is closed, your Shortcut fetches the latest wallpaper when it runs. Pairing waits only while this screen is open.")
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
            .onAppear {
                endpoint = sync.pairingAttempt?.endpoint ?? (sync.endpoint.isEmpty ? PairSync.defaultEndpoint : sync.endpoint)
                accept(invitation)
            }
            .onChange(of: invitation) { _, value in accept(value) }
            .task(id: watchID) { await watchPairing() }
            .alert(sync.updateNotice?.title ?? "Could not connect", isPresented: Binding(
                get: { sync.updateNotice != nil || !message.isEmpty },
                set: { if !$0 { sync.updateNotice = nil; message = "" } })) {
                Button("OK") { sync.updateNotice = nil; message = "" }
            } message: { Text(sync.updateNotice?.errorDescription ?? message) }
        }
    }

    @ViewBuilder private func pendingSection(_ attempt: PairingAttempt) -> some View {
        Section(attempt.kind == .create ? "Invite your partner" : "Joining your partner") {
            if let invite = attempt.invite {
                Text(invite.formattedCode).font(.largeTitle.bold().monospaced())
                    .textSelection(.enabled).accessibilityLabel("Pairing code \(invite.code)")
                PairingQRCode(url: invite.url)
                    .frame(maxWidth: .infinity)
                HStack {
                    ShareLink(item: invite.url, message: Text("Open this invite in CoupleDraw to join me. It expires in 5 minutes.")) {
                        Label("Share invite", systemImage: "square.and.arrow.up")
                    }
                    Spacer()
                    Button("Copy code") { UIPasteboard.general.string = invite.formattedCode }
                }
                if let expires = invite.expiresAt {
                    Text("Code expires at \(expires.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Your partner can tap Join Pair and enter this code, or open the invite link. The QR code includes your server address.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if pairingFailed {
                Button("Retry connecting") { pairingFailed = false; retryID = UUID() }
            } else {
                HStack {
                    ProgressView()
                    Text(sync.completingPairing ? "Saving your private credential…" :
                         (attempt.kind == .create && attempt.code != nil ? "Waiting for your partner…" : "Connecting…"))
                }
            }
            Button(attempt.kind == .create ? "Cancel invite" : "Cancel joining", role: .destructive) {
                busy = true
                Task {
                    do { try await sync.cancelPairing(); pairingFailed = false }
                    catch { message = error.localizedDescription }
                    busy = false
                }
            }.disabled(busy || sync.completingPairing)
        }
    }

    private func accept(_ invite: PairingInvite?) {
        guard let invite, sync.pairingAttempt == nil else { return }
        endpoint = invite.endpoint; code = invite.code; mode = .join
        connectingAnother = true
    }

    private func watchPairing() async {
        guard watchID != "idle" else { return }
        do {
            while !Task.isCancelled && sync.pairingAttempt != nil {
                if try await sync.resumePairing(store: store) {
                    connectingAnother = false
                    token = ""
                    await sync.enablePartnerAlerts()
                    return
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        } catch is CancellationError {
            // Closing this screen or locking the phone keeps recovery in Keychain.
        } catch {
            guard !Task.isCancelled else { return }
            pairingFailed = true
            message = error.localizedDescription
        }
    }

    private func connectManually() {
        busy = true
        Task {
            do {
                let server = try PairSync.normalizedEndpoint(endpoint)
                try await sync.configure(endpoint: server, token: token, store: store)
                token = ""; connectingAnother = false
                await sync.enablePartnerAlerts()
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
}

private struct PairingQRCode: View {
    let url: URL
    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
                                                     from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    var body: some View {
        if let image {
            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                .frame(width: 180, height: 180).padding(16).background(.white)
                .accessibilityLabel("QR code for your temporary CoupleDraw invite")
        }
    }
}
