import Foundation
import WatchConnectivity

/// Pushes tokens + side selection to the watch and answers its "needToken" requests.
final class PhoneSession: NSObject, WCSessionDelegate {
    static let shared = PhoneSession()

    weak var model: AppModel?
    private var pending: [String: Any]?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func push(_ context: WatchContext) {
        guard WCSession.isSupported() else { return }
        let dict = context.dictionary()
        let session = WCSession.default
        guard session.activationState == .activated else {
            pending = dict
            return
        }
        try? session.updateApplicationContext(dict)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        if let pending {
            try? session.updateApplicationContext(pending)
            self.pending = nil
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["request"] as? String == "needToken" else {
            replyHandler([:])
            return
        }
        let force = message["force"] as? Bool ?? false
        Task { @MainActor in
            let context = await self.model?.handleNeedToken(force: force) ?? .signedOut
            replyHandler(context.dictionary())
        }
    }
}
