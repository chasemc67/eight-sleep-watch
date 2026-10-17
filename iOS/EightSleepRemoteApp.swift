import SwiftUI

@main
struct EightSleepRemoteApp: App {
    @StateObject private var model = AppModel()

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
        }
    }
}
