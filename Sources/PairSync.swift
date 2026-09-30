import CryptoKit
import Foundation
import Security
import Combine
import UIKit
import UserNotifications

struct SyncedRevision: Codable {
    let source: String
    let revision: Int
    let author: String
    let backgroundHex: String
    let backgroundPhoto: BackgroundPhoto?
    let drawingData: Data
    let drawingHeight: Double
    var stickers: [CanvasSticker]? = nil
}

private struct ServerState: Decodable {
    let role: String
    let pushConfigured: Bool?
    let ntfyTopic: String?
    let ntfyBaseURL: String?
    let items: [SyncedRevision]
    let sharedBase: SyncedRevision?
    let drafts: [SharedDraft]?
    let draftRevisions: [String: Int]?
    let hasPartnerArt: Bool?
    let boardProtocol: Int?
    let mediaProtocol: Int?
    let boardSeedTag: String?
    let board: BoardUpdate?
}

private struct SharedDraft: Decodable {
    let role: String
    let revision: Int
    let drawingData: Data
    let drawingHeight: Double
}

private struct BoardSeed: Encodable {
    let seedTag: String
    let strokes: [SharedStroke]
}
private struct BoardConflict: Decodable { let board: BoardUpdate? }

private struct DeviceRegistration: Encodable { let deviceToken: String }

private struct DeviceRegistrationResult: Decodable {
    let registered: Bool
    let pushConfigured: Bool
}

private struct PublishBody: Encodable {
    let source: String
    let expectedRevision: Int
    let boardRevision: Int?
    let backgroundHex: String
    let backgroundPhoto: BackgroundPhoto?
    let drawingData: Data
    let drawingHeight: Double
    let stickers: [CanvasSticker]
}

private struct ServerError: Decodable { let error: String }

@MainActor final class PairSync: ObservableObject {
    @Published private(set) var status = "Local only"
    @Published private(set) var role: String?
    @Published private(set) var hasPartnerArt = false
    @Published private(set) var pushConfigured = false
    @Published private(set) var ntfyTopic: String?
    @Published private(set) var ntfyBaseURL: String?
    @Published var notificationsStatus = "Partner alerts are off"
    @Published private(set) var endpoint = UserDefaults.standard.string(forKey: "syncEndpoint") ?? ""
    private var token: String { SecretStore.read() ?? "" }
    private var versions: [CanvasSlot: Int] = {
        let saved = UserDefaults.standard.dictionary(forKey: "syncVersions") as? [String: Int] ?? [:]
        return Dictionary(uniqueKeysWithValues: saved.compactMap { entry in
            CanvasSlot(rawValue: entry.key).map { ($0, entry.value) }
        })
    }()
    private var dirty: Set<CanvasSlot> = Set(
        (UserDefaults.standard.stringArray(forKey: "syncDirty") ?? [])
            .compactMap { CanvasSlot(rawValue: $0) }.filter { $0 != .second })
    private var loop: Task<Void, Never>?
    private var stateETag: String?
    private var knownSnapshotVersions: [String: Int] = [:]
    private var knownDraftVersions: [String: Int] = [:]
    private var knowsSharedBase = false
    private var longPollSupported = false
    private var longPollAttempted = false
    private var longPollWaitSeconds = 20
    private var retryShortWait = false
    private var supportsStickerSync = false
    private weak var activeBoard: SharedWhiteboard?
    private var sessionID = UUID()
    private var draftTask: Task<Void, Never>?
    private var draftUploadFailed = false

    var configured: Bool { !endpoint.isEmpty && !token.isEmpty }
    /// Upgrades a token stored by earlier builds while the app is unlocked.
    func prepareForLockedShortcuts() { SecretStore.migrateLegacyTokenIfNeeded() }
    var pushCapable: Bool {
        #if PUSH_ENABLED
        return true
        #else
        return false
        #endif
    }

    static func allowsServerURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 || octets[0] == 127 ||
            (octets[0] == 100 && (64...127).contains(octets[1])) ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
    }

    func configure(endpoint raw: String, token: String, store: CanvasStore) async throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let newToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newToken.isEmpty else { throw SyncError.missingToken }
        guard let url = URL(string: trimmed), Self.allowsServerURL(url) else { throw SyncError.invalidServerURL }
        let oldEndpoint = endpoint, oldToken = self.token
        let oldVersions = versions, oldDirty = dirty, oldRole = role
        let changedPair = trimmed != oldEndpoint || newToken != oldToken
        if changedPair {
            stop()
            draftTask?.cancel()
            draftTask = nil
            activeBoard = nil
            sessionID = UUID()
            draftUploadFailed = false
            stateETag = nil
            knownSnapshotVersions = [:]
            knownDraftVersions = [:]
            knowsSharedBase = false
            longPollSupported = false
            longPollAttempted = false
            longPollWaitSeconds = 20
            retryShortWait = false
        }
        endpoint = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        do {
            try SecretStore.write(newToken)
            guard let state = try await fetch(force: true) else { throw SyncError.response }
            guard state.role == "A" || state.role == "B" else { throw SyncError.response }
            if changedPair {
                for slot in CanvasSlot.allCases {
                    if slot == .second { dirty.remove(slot); continue }
                    let local = store.record(slot)
                    if !local.drawingData.isEmpty || local.backgroundHex != "#000000" || local.backgroundPhoto != nil || !local.stickers.isEmpty {
                        dirty.insert(slot)
                    }
                }
            }
            UserDefaults.standard.set(endpoint, forKey: "syncEndpoint")
            if changedPair { versions = [:]; store.deactivateWhiteboard() }
            persistState()
            role = state.role
            pushConfigured = state.pushConfigured ?? false
            ntfyTopic = state.ntfyTopic
            ntfyBaseURL = state.ntfyBaseURL
            try await incorporate(state, store: store)
            status = connectedStatus(for: state.role)
            start(store: store)
        } catch {
            sessionID = UUID()
            endpoint = oldEndpoint
            try? SecretStore.write(oldToken)
            UserDefaults.standard.set(oldEndpoint, forKey: "syncEndpoint")
            versions = oldVersions; dirty = oldDirty; role = oldRole
            persistState()
            stateETag = nil
            knownSnapshotVersions = [:]; knownDraftVersions = [:]; knowsSharedBase = false
            if changedPair {
                store.deactivateWhiteboard()
                start(store: store)
            }
            throw error
        }
    }

    private var boardIdentity: String {
        SHA256.hash(data: Data((endpoint + "|" + token).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func start(store: CanvasStore) {
        guard configured, loop == nil else { return }
        do {
            try store.resumeWhiteboard(identity: boardIdentity)
            activeBoard = store.whiteboard
        } catch { store.errorMessage = error.localizedDescription }
        loop = Task { [weak self] in
            guard let self else { return }
            await self.refresh(store: store)
            while !Task.isCancelled {
                await self.refresh(store: store, waitForChange: true)
                if Task.isCancelled { break }
                // A recent server holds the request for up to 20 seconds. Older
                // servers answer immediately, so check them less often.
                try? await Task.sleep(for: self.longPollSupported ? .milliseconds(200) :
                                      self.retryShortWait ? .seconds(1) : .seconds(30))
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    /// Keep queued whiteboard edits on disk for the next foreground session.
    func suspend() {
        stop()
        sessionID = UUID()
        draftTask?.cancel()
        draftTask = nil
    }

    /// A Shortcut gets one fresh response even when the main app is suspended.
    /// Do not return a stale paired wallpaper if this request fails.
    func refreshForShortcut(store: CanvasStore) async throws {
        guard configured else { return }
        guard let state = try await fetch(force: true) else { throw SyncError.response }
        role = state.role
        pushConfigured = state.pushConfigured ?? false
        ntfyTopic = state.ntfyTopic
        ntfyBaseURL = state.ntfyBaseURL
        try await incorporate(state, store: store)
    }

    func enablePartnerAlerts() async {
        guard configured else { notificationsStatus = "Pair first to enable alerts."; return }
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard allowed else { notificationsStatus = "Allow CoupleDraw notifications in iPhone Settings."; return }
            UserDefaults.standard.set(true, forKey: "partnerAlertsEnabled")
            guard pushCapable && pushConfigured else {
                notificationsStatus = "Local alerts enabled while CoupleDraw is open."
                return
            }
            UIApplication.shared.registerForRemoteNotifications()
            await sendDeviceRegistration()
        } catch { notificationsStatus = "Could not enable alerts: \(error.localizedDescription)" }
    }

    func resumePartnerAlerts() async {
        guard pushCapable else { return }
        guard UserDefaults.standard.bool(forKey: "partnerAlertsEnabled") else { return }
        UIApplication.shared.registerForRemoteNotifications()
        await sendDeviceRegistration()
    }

    func sendDeviceRegistration() async {
        guard pushCapable else { return }
        guard configured, UserDefaults.standard.bool(forKey: "partnerAlertsEnabled") else { return }
        guard let deviceToken = UserDefaults.standard.string(forKey: "apnsDeviceToken") else {
            notificationsStatus = "Waiting for iOS to register for push alerts…"
            return
        }
        do {
            var request = try authorizedRequest(path: "/v1/device")
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(DeviceRegistration(deviceToken: deviceToken))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SyncError.response }
            guard http.statusCode == 200 else { throw serverError(data) }
            let result = try JSONDecoder().decode(DeviceRegistrationResult.self, from: data)
            pushConfigured = result.pushConfigured
            notificationsStatus = result.registered && result.pushConfigured ?
                "Partner alerts enabled" : "APNs is not configured on the server."
        } catch { notificationsStatus = "Could not register this phone for alerts: \(error.localizedDescription)" }
    }

    func markDirty(_ slot: CanvasSlot) {
        guard slot != .second else { return }
        dirty.insert(slot)
        persistState()
    }

    func scheduleSharedDraft(store: CanvasStore) {
        guard configured, let board = store.whiteboard, board.hasPending, draftTask == nil else { return }
        let session = sessionID
        draftTask = Task { [weak self, weak board] in
            guard let self, let board else { return }
            // Batch quick events without keeping a three-second polling timer alive.
            try? await Task.sleep(for: .milliseconds(150))
            while !Task.isCancelled && self.sessionID == session, let patch = board.nextPatch {
                do {
                    var request = try self.authorizedRequest(path: "/v1/board/ops")
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(String(board.revision), forHTTPHeaderField: "X-CoupleDraw-Board")
                    request.httpBody = try JSONEncoder().encode(patch)
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard !Task.isCancelled, self.sessionID == session else { break }
                    guard let http = response as? HTTPURLResponse else { throw SyncError.response }
                    if http.statusCode == 409,
                       let conflict = try? JSONDecoder().decode(BoardConflict.self, from: data),
                       let current = conflict.board {
                        // Keep a visible recovery copy before resolving overlapping edits.
                        guard store.apply(.together, recovery: true) != nil else { throw SyncError.server("Could not keep a recovery copy. Edits are still queued.") }
                        try board.resolveConflict(current)
                        self.draftUploadFailed = true
                        store.errorMessage = "Your partner changed the same stroke first. Your version is saved in History; the shared board has refreshed."
                        break
                    }
                    guard http.statusCode == 200 else { throw self.serverError(data) }
                    try board.receive(JSONDecoder().decode(BoardUpdate.self, from: data), acknowledging: patch.id)
                    self.draftUploadFailed = false
                } catch {
                    if Task.isCancelled { break }
                    self.draftUploadFailed = true
                    self.status = "Edits saved on this phone · waiting to sync: \(error.localizedDescription)"
                    break
                }
            }
            if self.sessionID == session { self.draftTask = nil }
        }
    }

    func flushSharedDraft(store: CanvasStore) async -> Bool {
        scheduleSharedDraft(store: store)
        if let draftTask { await draftTask.value }
        guard let board = store.whiteboard, !board.hasPending, !board.isEditing else { return false }
        do {
            if let state = try await fetch(force: true) { try await incorporate(state, store: store) }
            return !board.hasPending
        } catch { status = "Could not refresh the shared board: \(error.localizedDescription)"; return false }
    }

    /// The server checks the board version and commits one immutable revision.
    /// Save locally only after that commit, so an Apply toast means it really synced.
    func applyWhiteboard(store: CanvasStore) async -> Bool {
        guard configured, let role, let board = store.whiteboard else { return false }
        for _ in 0..<3 {
            guard await flushSharedDraft(store: store) else {
                store.errorMessage = "Your edits are saved on this phone. Reconnect before applying the shared board."
                return false
            }
            let record = store.displayedRecord(.together)
            guard record.stickers.isEmpty || supportsStickerSync else {
                store.errorMessage = "Update the Python server to this version before sharing stickers. Your draft is saved locally."
                return false
            }
            let capturedRevision = board.revision
            do {
                var request = try authorizedRequest(path: "/v1/apply")
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(PublishBody(
                    source: "together", expectedRevision: versions[.together] ?? 0,
                    boardRevision: capturedRevision,
                    backgroundHex: record.backgroundHex, backgroundPhoto: record.backgroundPhoto,
                    drawingData: record.drawingData, drawingHeight: record.drawingHeight,
                    stickers: record.stickers))
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw SyncError.response }
                if http.statusCode == 409 { continue }
                guard http.statusCode == 200 else { throw serverError(data) }
                let item = try JSONDecoder().decode(SyncedRevision.self, from: data)
                if item.revision > (versions[.together] ?? 0) {
                    try store.acceptRemote(item, on: .together, localRole: role, keepSharedBase: true)
                    versions[.together] = item.revision
                }
                dirty.remove(.together)
                persistState()
                status = "Our art saved for both phones · revision \(item.revision)"
                return true
            } catch {
                store.errorMessage = "Apply could not be confirmed: \(error.localizedDescription). Reconnect and try again."
                return false
            }
        }
        store.errorMessage = "The board is still changing. Finish the current strokes, then tap Apply again."
        return false
    }

    func takeServerCopy(_ slot: CanvasSlot, store: CanvasStore) async {
        dirty.remove(slot)
        versions.removeValue(forKey: slot)
        if let role { knownSnapshotVersions[source(for: slot, role: role)] = nil }
        // Queued whiteboard edits are never silently discarded by a refresh.
        stateETag = nil
        persistState()
        await refresh(store: store)
    }

    private func persistState() {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: versions.map { ($0.key.rawValue, $0.value) }),
                                  forKey: "syncVersions")
        UserDefaults.standard.set(dirty.map(\.rawValue), forKey: "syncDirty")
    }

    func refresh(store: CanvasStore, waitForChange: Bool = false) async {
        guard configured else { return }
        do {
            guard let state = try await fetch(waitForChange: waitForChange) else {
                scheduleSharedDraft(store: store)
                return
            }
            role = state.role
            pushConfigured = state.pushConfigured ?? false
            ntfyTopic = state.ntfyTopic
            ntfyBaseURL = state.ntfyBaseURL
            try await incorporate(state, store: store)
            let message = connectedStatus(for: state.role)
            retryShortWait = false
            if status != message && !draftUploadFailed { status = message }
            scheduleSharedDraft(store: store)
        } catch {
            if Task.isCancelled { return }
            stateETag = nil
            knownSnapshotVersions = [:]
            knownDraftVersions = [:]
            knowsSharedBase = false
            if waitForChange {
                longPollAttempted = true
                longPollSupported = false
                // Some reverse proxies close idle connections before 20 seconds.
                // A shorter wait can keep instant updates working on those VPSes.
                retryShortWait = longPollWaitSeconds == 20
                longPollWaitSeconds = 10
            }
            status = "Sync paused: \(error.localizedDescription)"
        }
    }

    private func connectedStatus(for role: String) -> String {
        if !longPollAttempted { return "Connected as \(role) · checking live sync" }
        return longPollSupported ? "Connected as \(role) · live while open" :
            "Connected as \(role) · checking every 30s"
    }

    private func incorporate(_ state: ServerState, store: CanvasStore) async throws {
        supportsStickerSync = state.mediaProtocol == 1
        if state.boardProtocol != 1 {
            throw SyncError.server("Update the Python server to this source version to enable the shared whiteboard.")
        }
        if state.boardProtocol == 1 {
            try store.activateWhiteboard(identity: boardIdentity)
            activeBoard = store.whiteboard
            if let board = store.whiteboard {
                if let update = state.board { try board.receive(update) }
                else if board.revision == 0, let seedTag = state.boardSeedTag {
                    var strokes: [SharedStroke] = []
                    if let base = state.sharedBase {
                        strokes += try SharedStroke.split(base.drawingData, height: base.drawingHeight)
                    }
                    for draft in state.drafts ?? [] {
                        strokes += try SharedStroke.split(draft.drawingData, height: draft.drawingHeight)
                    }
                    var request = try authorizedRequest(path: "/v1/board/seed")
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(BoardSeed(seedTag: seedTag, strokes: strokes))
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        // Fetch all legacy layers again on a concurrent migration.
                        stateETag = nil; knowsSharedBase = false; knownDraftVersions = [:]
                        throw serverError(data)
                    }
                    try board.receive(JSONDecoder().decode(BoardUpdate.self, from: data))
                }
            }
        }
        if let hasPartnerArt = state.hasPartnerArt {
            self.hasPartnerArt = hasPartnerArt
        } else {
            hasPartnerArt = state.items.contains { slot(for: $0.source, role: state.role) == .second }
        }
        for item in state.items {
            guard let slot = slot(for: item.source, role: state.role) else { continue }
            let previous = versions[slot] ?? 0
            if item.revision > previous && (slot == .together && store.liveSharedEnabled || !dirty.contains(slot)) {
                do {
                    try store.acceptRemote(item, on: slot, localRole: state.role,
                                           keepSharedBase: slot == .together && store.liveSharedEnabled,
                                           keepSharedBackground: dirty.contains(.together))
                    versions[slot] = item.revision
                    persistState()
                    if ntfyTopic == nil && (!pushCapable || !pushConfigured),
                       item.author != state.role,
                       UserDefaults.standard.bool(forKey: "partnerAlertsEnabled"),
                       UIApplication.shared.applicationState == .active {
                        await showLocalPartnerAlert(for: item)
                    }
                } catch { status = "Could not render remote drawing: \(error.localizedDescription)" }
            }
        }
    }

    private func showLocalPartnerAlert(for item: SyncedRevision) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "CoupleDraw wallpaper ready"
        content.body = "Your partner applied a new drawing."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "partner-\(item.source)-\(item.revision)",
                                            content: content, trigger: nil)
        try? await center.add(request)
    }

    func publish(_ record: CanvasRecord, slot: CanvasSlot, store: CanvasStore) async {
        guard slot != .second else { status = "Only your partner can publish Partner's art."; return }
        guard configured else { return }
        if role == nil { await refresh(store: store) }
        guard let role else { return }
        guard record.stickers.isEmpty || supportsStickerSync else {
            status = "Saved on this phone. Update the Python server before sharing stickers."
            store.errorMessage = status
            return
        }
        let source = source(for: slot, role: role)
        do {
            var request = try authorizedRequest(path: "/v1/apply")
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(PublishBody(
                source: source, expectedRevision: versions[slot] ?? 0, boardRevision: nil,
                backgroundHex: record.backgroundHex, backgroundPhoto: record.backgroundPhoto,
                drawingData: record.drawingData,
                drawingHeight: record.drawingHeight, stickers: record.stickers))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SyncError.response }
            if http.statusCode == 409 {
                status = "Edit conflict on \(slot.rawValue). Your local drawing is safe; ask your partner to pause, then resolve before publishing."
                return
            }
            guard http.statusCode == 200 else { throw serverError(data) }
            let item = try JSONDecoder().decode(SyncedRevision.self, from: data)
            versions[slot] = item.revision
            if item.backgroundPhoto != record.backgroundPhoto {
                persistState()
                status = "Saved locally; update the Python server to sync photo backgrounds."
                return
            }
            dirty.remove(slot)
            persistState()
            status = "Published \(slot.rawValue) · revision \(item.revision)"
        } catch { status = "Saved locally; sync failed: \(error.localizedDescription)" }
    }

    private func fetch(force: Bool = false, waitForChange: Bool = false) async throws -> ServerState? {
        let session = sessionID
        var request = try authorizedRequest(path: "/v1/state")
        if let activeBoard, activeBoard.revision > 0, !force {
            request.setValue(String(activeBoard.revision), forHTTPHeaderField: "X-CoupleDraw-Board")
        }
        if !force, let stateETag { request.setValue(stateETag, forHTTPHeaderField: "If-None-Match") }
        if !force {
            if !knownSnapshotVersions.isEmpty {
                request.setValue(knownSnapshotVersions.sorted { $0.key < $1.key }
                    .map { "\($0.key):\($0.value)" }.joined(separator: ","),
                                 forHTTPHeaderField: "X-CoupleDraw-Snapshots")
            }
            if !knownDraftVersions.isEmpty {
                request.setValue(knownDraftVersions.sorted { $0.key < $1.key }
                    .map { "\($0.key):\($0.value)" }.joined(separator: ","),
                                 forHTTPHeaderField: "X-CoupleDraw-Drafts")
            }
            if knowsSharedBase { request.setValue("1", forHTTPHeaderField: "X-CoupleDraw-Base-Known") }
        }
        if waitForChange && stateETag != nil {
            request.setValue("wait=\(longPollWaitSeconds)", forHTTPHeaderField: "Prefer")
            request.timeoutInterval = TimeInterval(longPollWaitSeconds + 15)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard session == sessionID, !Task.isCancelled else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw SyncError.response }
        if waitForChange {
            longPollAttempted = true
            longPollSupported = http.value(forHTTPHeaderField: "X-CoupleDraw-Long-Poll") == "1"
        }
        if http.statusCode == 304 {
            retryShortWait = false
            if let role {
                let message = connectedStatus(for: role)
                if status != message && !draftUploadFailed { status = message }
            }
            return nil
        }
        guard http.statusCode == 200 else { throw serverError(data) }
        let state = try JSONDecoder().decode(ServerState.self, from: data)
        stateETag = http.value(forHTTPHeaderField: "ETag")
        for item in state.items { knownSnapshotVersions[item.source] = max(knownSnapshotVersions[item.source] ?? 0, item.revision) }
        for draft in state.drafts ?? [] { knownDraftVersions[draft.role] = draft.revision }
        if state.drafts != nil { knowsSharedBase = true }
        return state
    }

    private func authorizedRequest(path: String) throws -> URLRequest {
        guard let url = URL(string: endpoint + path) else { throw SyncError.configuration }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private func serverError(_ data: Data) -> Error {
        SyncError.server((try? JSONDecoder().decode(ServerError.self, from: data).error) ?? "Server rejected request")
    }

    private func source(for slot: CanvasSlot, role: String) -> String {
        switch slot {
        case .first: return role == "A" ? "a" : "b"
        case .second: return role == "A" ? "b" : "a"
        case .together: return "together"
        }
    }

    private func slot(for source: String, role: String) -> CanvasSlot? {
        switch source {
        case "a": return role == "A" ? .first : .second
        case "b": return role == "A" ? .second : .first
        case "together": return .together
        default: return nil
        }
    }

    enum SyncError: LocalizedError {
        case configuration, invalidServerURL, missingToken, response, server(String)
        var errorDescription: String? {
            switch self {
            case .configuration: return "Check your server URL and pairing token."
            case .invalidServerURL: return "Enter an HTTPS URL, or an HTTP URL using a private LAN or Tailscale IP address. Do not include an API path."
            case .missingToken: return "Enter your A or B pairing token from the create-pair command on your server."
            case .response: return "Invalid sync server response."
            case .server(let message): return message
            }
        }
    }
}

private enum SecretStore {
    private static let account = "CoupleDrawPairTokenAfterFirstUnlock"
    private static let legacyAccount = "CoupleDrawPairToken"

    static func read() -> String? {
        read(account: account) ?? read(account: legacyAccount)
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func migrateLegacyTokenIfNeeded() {
        guard read(account: account) == nil,
              let previousToken = read(account: legacyAccount) else { return }
        try? write(previousToken)
    }

    static func write(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account]
        let value = Data(token.utf8)
        let update = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: value] as CFDictionary)
        if update == errSecItemNotFound {
            let item = query.merging([
                kSecValueData as String: value,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw PairSync.SyncError.configuration
            }
        } else if update != errSecSuccess {
            throw PairSync.SyncError.configuration
        }
        // Never remove the old item until the locked-accessible replacement exists.
        let legacyQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                          kSecAttrAccount as String: legacyAccount]
        SecItemDelete(legacyQuery as CFDictionary)
    }
}
