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
    @Published private(set) var isOn = false
    @Published private(set) var sendState: SendState = .idle
    @Published private(set) var errorMessage: String?
    /// Bound to the Digital Crown, in app steps (-10…10).
    @Published var crownValue: Double = 0

    let isDemo = DemoMode.isEnabled
    private let client: EightSleepClient
    private let debouncer = Debouncer(delay: 0.6)
    private var sideUserId: String?

    init() {
        if isDemo {
            client = EightSleepClient(credentials: nil, store: nil)
            isConfigured = true
            sideLabel = "Chase · Left"
            sideUserId = "demo-left"
            isOn = true
            setDisplay(30)
            serverLevel = 30
            SharedSettings.recordLevel(30, isOn: true)
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
            isOn = SharedSettings.lastIsOn ?? false
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
            debouncer.cancel()
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
        if current == nil || creds.expiresAt >= current!.expiresAt || current!.accessToken == creds.accessToken {
            await client.setCredentials(creds)
        }
        let oldSide = sideUserId
        if let selection = context.selection {
            SharedSettings.sideSelection = selection
            sideLabel = selection.label
            sideUserId = selection.sideUserId
        }
        isConfigured = sideUserId != nil
        if sideUserId != oldSide || serverLevel == nil {
            await refresh()
        }
    }

    // MARK: Server

    func refresh() async {
        guard isConfigured, !isDemo, let sideUserId else { return }
        // Don't clobber taps that haven't been sent yet.
        guard !debouncer.isPending, sendState != .sending else { return }
        do {
            let status = try await client.temperature(userId: sideUserId)
            guard !debouncer.isPending, sendState != .sending else { return }
            serverLevel = status.currentLevel
            isOn = status.isOn
            setDisplay(status.currentLevel)
            errorMessage = nil
            SharedSettings.recordLevel(status.currentLevel, isOn: status.isOn)
        } catch {
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
        sendState = .idle
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
        do {
            try await client.setLevel(userId: sideUserId, level: target, turnOnFirst: !isOn)
            serverLevel = target
            isOn = true
            SharedSettings.recordLevel(target, isOn: true)
            WidgetCenter.shared.reloadAllTimelines()
            await flashSent()
        } catch {
            sendState = .failed
            errorMessage = message(for: error)
            if let serverLevel, !debouncer.isPending { setDisplay(serverLevel) }
        }
    }

    private func flashSent() async {
        sendState = .sent
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if sendState == .sent { sendState = .idle }
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
