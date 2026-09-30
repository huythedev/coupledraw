import AppIntents
import UniformTypeIdentifiers
import UIKit

/// A local Shortcuts action. The Set Wallpaper action must be added by the user
/// after this action, on the device whose Lock Screen is being changed.
struct LatestWallpaperIntent: AppIntent {
    static var title: LocalizedStringResource = "Get My CoupleDraw Wallpaper"
    static var description = IntentDescription("Return the last applied wallpaper image for this iPhone's canvas.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let store = await MainActor.run { CanvasStore() }
        let sync = await MainActor.run { PairSync() }
        await sync.refresh(store: store)
        let imageData = try await MainActor.run { () throws -> Data in
            let choice = WallpaperChoice(rawValue: UserDefaults.standard.string(forKey: "wallpaperChoice") ?? "own") ?? .own
            if choice == .partner && !sync.hasPartnerArt {
                throw WallpaperIntentError.noPartnerArt
            }
            let myCanvasID = store.record(choice.slot).canvasID
            guard let latest = store.revisions.first(where: { $0.canvasID == myCanvasID && $0.recovery != true }) else {
                throw WallpaperIntentError.noAppliedRevision
            }
            if choice == .partner && latest.document.targetSize != .thisIPhone {
                let image = try WallpaperRenderer.render(latest.document, pixels: WallpaperSize.thisIPhone.pixels)
                guard let data = image.pngData() else { throw WallpaperIntentError.imageEncoding }
                return data
            }
            return try Data(contentsOf: store.imageURL(for: latest))
        }
        return .result(value: IntentFile(data: imageData,
                                         filename: "CoupleDraw-Wallpaper.png", type: .png))
    }
}

private enum WallpaperIntentError: LocalizedError {
    case noAppliedRevision, noPartnerArt, imageEncoding
    var errorDescription: String? {
        switch self {
        case .noAppliedRevision: return "Apply a drawing on your selected source before running this shortcut."
        case .noPartnerArt: return "Pair the phones and wait for your partner to Apply on My art."
        case .imageEncoding: return "Could not encode the selected wallpaper."
        }
    }
}
