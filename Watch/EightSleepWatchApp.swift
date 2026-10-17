import SwiftUI

@main
struct EightSleepWatchApp: App {
    @StateObject private var model = WatchModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.refresh() } }
                }
        }
    }
}
