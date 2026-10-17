import Foundation
import WatchConnectivity

/// Receives tokens + side from the phone and asks it for a fresh token when ours can't be refreshed.
final class WatchSession: NSObject, WCSessionDelegate {
    static let shared = WatchSession()

    weak var model: WatchModel?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        deliver(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliver(applicationContext)
    }

    private func deliver(_ dict: [String: Any]) {
        guard let context = WatchContext(dictionary: dict) else { return }
        Task { @MainActor in await self.model?.apply(context) }
    }

    /// Sends "needToken" to the phone if it's reachable; returns its reply.
    func requestFreshContext() async -> WatchContext? {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated, session.isReachable else { return nil }
        let reply: [String: Any]? = await withCheckedContinuation { continuation in
            session.sendMessage(["request": "needToken", "force": true], replyHandler: { reply in
                continuation.resume(returning: reply)
            }, errorHandler: { _ in
                continuation.resume(returning: nil)
            })
        }
        guard let reply, let context = WatchContext(dictionary: reply), context.signedIn else { return nil }
        return context
    }
}
