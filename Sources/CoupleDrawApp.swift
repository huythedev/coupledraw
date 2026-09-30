import SwiftUI

@main struct CoupleDrawApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @StateObject private var store = CanvasStore()
    @StateObject private var sync = PairSync()

    var body: some Scene {
        WindowGroup {
            EditorView()
                .environmentObject(store)
                .environmentObject(sync)
        }
    }
}
