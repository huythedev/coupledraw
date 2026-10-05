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
        let choice = WallpaperChoice(rawValue: UserDefaults.standard.string(forKey: "wallpaperChoice") ?? "own") ?? .own
        let store = await MainActor.run { CanvasStore(shortcutChoice: choice) }
        let sync = await MainActor.run { PairSync() }
        try await sync.refreshForShortcut(store: store, choice: choice)
        let fileURL = try await MainActor.run { () throws -> URL in
            if choice == .partner && !sync.hasPartnerArt {
                throw WallpaperIntentError.noPartnerArt
            }
            return try store.wallpaperFileForShortcut(on: choice.slot)
        }
        try await sync.acknowledgeShortcutMedia(store: store)
        return .result(value: IntentFile(fileURL: fileURL,
                                         filename: "CoupleDraw-Wallpaper.png", type: .png))
    }
}

private enum WallpaperIntentError: LocalizedError {
    case noPartnerArt
    var errorDescription: String? {
        switch self {
        case .noPartnerArt: return "Pair the phones and wait for your partner to Apply on My art."
        }
    }
}
