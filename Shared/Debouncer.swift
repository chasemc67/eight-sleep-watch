import Foundation

/// Runs only the last action scheduled within `delay` seconds.
@MainActor
final class Debouncer {
    let delay: TimeInterval
    private var task: Task<Void, Never>?

    init(delay: TimeInterval) { self.delay = delay }

    var isPending: Bool { task != nil }

    func call(_ action: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { [delay] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.task = nil
            await action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
