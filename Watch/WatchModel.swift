import Foundation
import SwiftUI
import WatchKit
import WidgetKit

@MainActor
final class WatchModel: ObservableObject {
    enum SendState { case idle, sending, sent, failed }

    @Published private(set) var isConfigured: Bool
    @Published private(set) var sideLabel: String
    @Published private(set) var serverLevel: Int?
    @Published private(set) var displayLevel: Int?
    @Published private(set) var isOn: Bool?
    @Published private(set) var sendState: SendState = .idle
    @Published private(set) var errorMessage: String?
    /// Bound to the Digital Crown, in app steps (-10…10).
    @Published var crownValue: Double = 0

    let isDemo = DemoMode.isEnabled
    private let client: EightSleepClient
    private let debouncer = Debouncer(delay: 0.6)
    private var sideUserId: String?
    private var revision = 0
    private let loadGate = LoadGate()
    private lazy var updates = LevelUpdateCoordinator(
        power: { [client] in try await client.setPower(userId: $0, on: true) },
        level: { [client] in try await client.setLevel(userId: $0, level: $1, turnOnFirst: false) })

    init() {
        if isDemo {
            client = EightSleepClient(credentials: nil, store: nil)
            isConfigured = true
            sideLabel = "Chase · Left"
            sideUserId = "demo-left"
            isOn = true
            setDisplay(20)
            serverLevel = 20
            SharedSettings.recordLevel(20, isOn: true)
            return
        }
        let store = TokenStore()
        let creds = store.load()
        let selection = SharedSettings.sideSelection
        client = EightSleepClient(credentials: creds, store: store)
        isConfigured = creds != nil && selection != nil
        sideLabel = selection?.label ?? ""
        sideUserId = selection?.sideUserId
        if let last = SharedSettings.lastLevel {
            serverLevel = last
            setDisplay(last)
            isOn = SharedSettings.lastIsOn
        }

        WatchSession.shared.model = self
        WatchSession.shared.activate()
        Task {
            await client.setHandlers(onChange: nil, fallback: {
                await WatchSession.shared.requestFreshContext()?.credentials
            })
        }
    }

    // MARK: Context from the phone

    func apply(_ context: WatchContext) async {
        guard !isDemo else { return }
        guard context.signedIn, let creds = context.credentials else {
            revision += 1
            updates.invalidate()
            debouncer.cancel()
            sendState = .idle
            await client.signOut()
            SharedSettings.clear()
            isConfigured = false
            sideUserId = nil
            serverLevel = nil
            displayLevel = nil
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        // Application context can be stale; don't replace a newer token we refreshed ourselves.
        let current = await client.credentials
        if creds.shouldReplace(current) {
            await client.setCredentials(creds)
        }
        let resetControls = context.shouldResetControls(currentSideUserId: sideUserId)
        if let selection = context.selection {
            SharedSettings.sideSelection = selection
            sideLabel = selection.label
            sideUserId = selection.sideUserId
        }
        isConfigured = sideUserId != nil
        if resetControls {
            revision += 1
            updates.invalidate()
            debouncer.cancel()
            serverLevel = nil
            displayLevel = nil
            isOn = nil
            sendState = .idle
            SharedSettings.recordLevel(nil, isOn: nil)
            WidgetCenter.shared.reloadAllTimelines()
            await updates.waitUntilIdle()
            await refresh(force: true)
        } else if serverLevel == nil {
            await refresh()
        }
    }

    // MARK: Server

    func refresh(force: Bool = false) async {
        guard isConfigured, !isDemo, let sideUserId else { return }
        // Don't clobber taps that haven't been sent yet.
        guard !debouncer.isPending, !updates.isSending, loadGate.begin(force: force) else { return }
        let version = revision
        defer {
            loadGate.end()
            if version != revision, isConfigured { Task { await refresh(force: true) } }
        }
        do {
            let status = try await client.temperature(userId: sideUserId)
            guard version == revision, !debouncer.isPending, !updates.isSending else { return }
            serverLevel = status.currentLevel
            isOn = status.isOn
            if let level = status.currentLevel { setDisplay(level) } else { displayLevel = nil }
            errorMessage = nil
            SharedSettings.recordLevel(status.currentLevel, isOn: status.isOn)
        } catch {
            guard version == revision else { return }
            errorMessage = message(for: error)
        }
    }

    // MARK: Input

    func tap(_ delta: Int) {
        guard let base = displayLevel ?? serverLevel else { return }
        let next = TemperatureFormat.stepped(raw: base, by: delta)
        WKInterfaceDevice.current().play(.click)
        guard next != displayLevel else { return }
        setDisplay(next)
        schedule()
    }

    func crownChanged(to value: Double) {
        guard displayLevel != nil || serverLevel != nil else { return }
        let steps = Int(value.rounded())
        let next = TemperatureFormat.clampRaw(steps * TemperatureFormat.stepSize)
        guard displayLevel.map(TemperatureFormat.appLevel(raw:)) != steps else { return }
        setDisplay(next)
        schedule()
    }

    private func setDisplay(_ raw: Int) {
        displayLevel = raw
        let steps = Double(TemperatureFormat.appLevel(raw: raw))
        if crownValue != steps { crownValue = steps }
    }

    private func schedule() {
        updates.discardQueued()
        if !updates.isSending { sendState = .idle }
        errorMessage = nil
        debouncer.call { [weak self] in await self?.commit() }
    }

    /// One PUT with the final level after taps settle.
    private func commit() async {
        guard let target = displayLevel, let sideUserId else { return }
        if isDemo {
            serverLevel = target
            SharedSettings.recordLevel(target, isOn: true)
            await flashSent()
            return
        }
        sendState = .sending
        updates.submit(userId: sideUserId, level: target, isOn: isOn) { [weak self] result in
            guard let self else { return }
            switch result {
            case .sent(let level, let isOn):
                self.serverLevel = level
                self.isOn = isOn
                SharedSettings.recordLevel(level, isOn: isOn)
                WidgetCenter.shared.reloadAllTimelines()
                if self.displayLevel == level {
                    Task {
                        guard self.displayLevel == level, !self.debouncer.isPending else { return }
                        await self.flashSent()
                    }
                }
            case .failed(let error, let isOn):
                self.isOn = isOn
                self.sendState = self.updates.hasQueuedRequest ? .sending : .failed
                self.errorMessage = self.message(for: error)
                if !self.debouncer.isPending, !self.updates.hasQueuedRequest, let level = self.serverLevel { self.setDisplay(level) }
            }
        }
    }

    private func flashSent() async {
        let version = revision
        sendState = .sent
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if version == revision, sendState == .sent { sendState = .idle }
    }

    private func message(for error: Error) -> String {
        switch error {
        case EightSleepError.notSignedIn: return "Sign in on your iPhone"
        case EightSleepError.needsPhone, EightSleepError.unauthorized, EightSleepError.invalidCredentials:
            return "Open Eight Sleep Remote on your iPhone"
        default: return error.localizedDescription
        }
    }
}
