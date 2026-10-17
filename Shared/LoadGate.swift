import Foundation

/// Coalesces launch/scene-active loads, including callbacks immediately after a completed load.
@MainActor
final class LoadGate {
    private var loading = false
    private var lastFinished = Date.distantPast
    func begin(now: Date = Date(), force: Bool = false) -> Bool {
        guard !loading, force || now.timeIntervalSince(lastFinished) > 2 else { return false }
        loading = true
        return true
    }
    func end(now: Date = Date()) {
        loading = false
        lastFinished = now
    }
}
