import SwiftUI

@main struct CoupleDrawApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @StateObject private var store = CanvasStore()
    @StateObject private var sync = PairSync()
    @StateObject private var backgroundExperiment = BackgroundLocationExperiment()

    var body: some Scene {
        WindowGroup {
            EditorView()
                .environmentObject(store)
                .environmentObject(sync)
                .environmentObject(backgroundExperiment)
        }
    }
}
