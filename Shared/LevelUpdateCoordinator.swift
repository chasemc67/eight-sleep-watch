import Foundation

/// One write at a time. During a write, replace the queued request with the latest target.
/// A successful power-on is remembered even if the following level PUT fails.
@MainActor
final class LevelUpdateCoordinator {
    enum Result {
        case sent(Int, Bool?)
        case failed(Error, Bool?)
    }
    typealias Power = (String) async throws -> Void
    typealias Level = (String, Int) async throws -> Void
    private struct Request {
        let userId: String
        let level: Int
        let isOn: Bool?
        let generation: Int
        let completion: (Result) -> Void
    }
    private let power: Power
    private let level: Level
    private var pending: Request?
    private var drainTask: Task<Void, Never>?
    var hasQueuedRequest: Bool { pending != nil }
    private var poweredUsers: Set<String> = []
    private var generation = 0
    private(set) var isSending = false

    init(power: @escaping Power, level: @escaping Level) {
        self.power = power
        self.level = level
    }

    func submit(userId: String, level: Int, isOn: Bool?, completion: @escaping (Result) -> Void) {
        pending = Request(userId: userId, level: level, isOn: isOn, generation: generation, completion: completion)
        guard !isSending else { return }
        isSending = true
        drainTask = Task { await drain() }
    }

    /// A new tap restarts the debounce; a previously settled target is no longer the latest.
    func discardQueued() { pending = nil }

    func waitUntilIdle() async { await drainTask?.value }

    /// Discard queued work and callbacks from a previous side/session; let its in-flight PUT finish.
    func invalidate() {
        generation += 1
        pending = nil
        poweredUsers.removeAll()
    }

    private func drain() async {
        while let request = pending {
            pending = nil
            var state = request.isOn
            if poweredUsers.contains(request.userId) { state = true }
            do {
                if state == false {
                    try await power(request.userId)
                    guard request.generation == generation else { continue }
                    poweredUsers.insert(request.userId)
                    state = true
                }
                try await level(request.userId, request.level)
                guard request.generation == generation else { continue }
                request.completion(.sent(request.level, state))
            } catch {
                guard request.generation == generation else { continue }
                request.completion(.failed(error, state))
            }
        }
        isSending = false
        // Power is cached only within this burst; the next read can report that the bed is off.
        poweredUsers.removeAll()
    }
}
