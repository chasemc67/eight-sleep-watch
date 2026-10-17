import SwiftUI

@main
struct EightSleepRemoteApp: App {
    @StateObject private var model = AppModel()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if model.isSignedIn {
                    ControlView()
                } else {
                    LoginView()
                }
            }
            .environmentObject(model)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, model.isSignedIn { Task { await model.loadAll() } }
            }
        }
    }
}
