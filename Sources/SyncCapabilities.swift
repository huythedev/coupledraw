import Foundation

/// Wire protocol versions are independent of app/build versions. A future
/// implementation advertises every older version it still understands.
struct SyncCapabilities: Decodable {
    let apiVersions: [Int]
    let protocols: [String: [Int]]
    let peerProtocols: [String: [Int]]?
    let whiteboardReady: Bool?

    static let clientProtocols: [String: [Int]] = [
        "wallpaper": [1], "photos": [1], "stickers": [1], "whiteboard": [1],
        "legacyDrafts": [1], "mediaRelay": [2], "pairing": [1], "boardHistory": [1]
    ]

    func supports(_ feature: String, withPartner: Bool = false) -> Bool {
        let client = Self.clientProtocols[feature] ?? []
        let common = Set(client).intersection(protocols[feature] ?? [])
        guard !common.isEmpty else { return false }
        if withPartner, let peerProtocols {
            return !common.intersection(peerProtocols[feature] ?? []).isEmpty
        }
        // Servers predating discovery, and partners not seen yet, are probed
        // through the existing v1 endpoints rather than blocking normal use.
        return true
    }

    func missing(_ feature: String, withPartner: Bool = false) -> UpdateNotice? {
        guard !supports(feature, withPartner: withPartner) else { return nil }
        let versions = supports(feature) ? peerProtocols?[feature] ?? [] : protocols[feature] ?? []
        let tooNew = (versions.min() ?? 0) > (Self.clientProtocols[feature]?.max() ?? 0)
        let target: UpdateNotice.Target = tooNew ? .app : supports(feature) ? .partner : .server
        return UpdateNotice(feature: feature, target: target)
    }
}

struct UpdateNotice: Identifiable, LocalizedError, Equatable {
    enum Target: String, Codable { case server, app, partner }
    let feature: String
    let target: Target
    var id: String { target.rawValue + ":" + feature }
    var title: String { "Update needed" }
    var featureName: String {
        switch feature {
        case "whiteboard", "boardHistory": return "live shared drawing"
        case "legacyDrafts": return "shared draft syncing"
        case "photos": return "photo backgrounds"
        case "stickers": return "sharing stickers"
        case "pairing": return "Create Pair and Join Pair"
        default: return "this feature"
        }
    }
    var errorDescription: String? {
        let action: String
        switch target {
        case .server: action = "Update the CoupleDraw server"
        case .app: action = "Update CoupleDraw on this iPhone"
        case .partner: action = "Ask your partner to update CoupleDraw"
        }
        return "\(action) to use \(featureName). Your drawings stay on this phone, and other supported features still work." +
            (feature == "pairing" ? " You can also connect with an existing token under Manual pairing." : "")
    }
    var guideURL: URL {
        URL(string: target == .server
            ? "https://github.com/huythedev/coupledraw/blob/main/docs/server.md"
            : "https://github.com/huythedev/coupledraw/releases/latest")!
    }
}
