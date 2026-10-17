import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    struct SideOption: Identifiable, Hashable {
        let assignment: SideAssignment
        let firstName: String?
        var id: BedSide { assignment.side }
        var pickerLabel: String { SideResolver.pickerLabel(side: assignment.side, firstName: firstName) }
        var watchLabel: String { SideResolver.watchLabel(side: assignment.side, firstName: firstName) }
    }

    @Published private(set) var isSignedIn: Bool
    @Published private(set) var sides: [SideOption] = []
    @Published private(set) var selectedSide: BedSide?
    @Published private(set) var status: TemperatureStatus?
    /// Target shown immediately while taps are being debounced.
    @Published private(set) var pendingLevel: Int?
    @Published private(set) var isBusy = false
    @Published private(set) var isSending = false
    @Published var errorMessage: String?

    let isDemo = DemoMode.isEnabled
    private let client: EightSleepClient
    private let debouncer = Debouncer(delay: 0.6)
    private let loadGate = LoadGate()
    private var revision = 0
    private lazy var updates = LevelUpdateCoordinator(
        power: { [client] in try await client.setPower(userId: $0, on: true) },
        level: { [client] in try await client.setLevel(userId: $0, level: $1, turnOnFirst: false) })

    var displayLevel: Int? { pendingLevel ?? status?.currentLevel }
    var selectedOption: SideOption? { sides.first { $0.id == selectedSide } }

    init() {
        let store = TokenStore()
        if isDemo {
            client = EightSleepClient(credentials: nil, store: nil)
            isSignedIn = true
            sides = [
                SideOption(assignment: SideAssignment(side: .left, userId: "demo-left"), firstName: "Chase"),
                SideOption(assignment: SideAssignment(side: .right, userId: "demo-right"), firstName: "Partner"),
            ]
            selectedSide = .left
            status = TemperatureStatus(currentLevel: 20, currentDeviceLevel: 20, stateType: "smart")
        } else {
            let creds = store.load()
            client = EightSleepClient(credentials: creds, store: store)
            isSignedIn = creds != nil
        }

        PhoneSession.shared.model = self
        PhoneSession.shared.activate()

        guard !isDemo else { return }
        Task {
            await client.setHandlers(onChange: { _ in
                Task { @MainActor in AppModel.pushContextFromSession() }
            }, fallback: nil)
            if isSignedIn { await loadAll() }
        }
    }

    private static func pushContextFromSession() {
        PhoneSession.shared.model?.pushContext()
    }

    // MARK: Auth

    func signIn(email: String, password: String) async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.login(email: email.trimmingCharacters(in: .whitespaces), password: password)
            isSignedIn = true
            await loadAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        revision += 1
        updates.invalidate()
        debouncer.cancel()
        isSending = false
        await client.signOut()
        SharedSettings.clear()
        isSignedIn = false
        sides = []
        selectedSide = nil
        status = nil
        pendingLevel = nil
        errorMessage = nil
        PhoneSession.shared.push(.signedOut)
    }

    // MARK: Loading

    /// Loads the account's Pod, its sides and names, then the selected side's temperature.
    func loadAll(force: Bool = false) async {
        guard !isDemo, isSignedIn, loadGate.begin(force: force) else { return }
        let version = revision
        defer { loadGate.end() }
        isBusy = true
        defer { isBusy = false }
        do {
            let me = try await client.me()
            guard let deviceId = me.preferredDeviceId else { throw EightSleepError.noDevice }
            let assignments = try await client.sides(deviceId: deviceId)
            var options: [SideOption] = []
            for a in assignments {
                var name: String?
                if a.userId == me.userId {
                    name = me.firstName
                } else {
                    name = try await client.user(id: a.userId)?.firstName // 403 means a private profile
                }
                options.append(SideOption(assignment: a, firstName: name))
            }
            guard version == revision, isSignedIn else { return }
            sides = options

            let saved = SharedSettings.sideSelection
            if let saved, let match = options.first(where: { $0.assignment.userId == saved.sideUserId }) {
                selectedSide = match.id
            } else {
                let storedUserId = await client.credentials?.userId
                let myUserId = me.userId ?? storedUserId
                selectedSide = SideResolver.defaultAssignment(in: assignments, myUserId: myUserId,
                                                              mySide: me.currentDevice?.side)?.side
            }
            persistSelection()
            await refreshTemperature()
        } catch {
            guard version == revision else { return }
            errorMessage = message(for: error)
        }
    }

    func refreshTemperature() async {
        guard let option = selectedOption else { return }
        if isDemo { return }
        guard !debouncer.isPending, !updates.isSending else { return }
        let version = revision
        do {
            let s = try await client.temperature(userId: option.assignment.userId)
            guard version == revision, !debouncer.isPending, !updates.isSending else { return }
            status = s
            pendingLevel = nil
            SharedSettings.recordLevel(s.currentLevel, isOn: s.isOn)
            errorMessage = nil
        } catch {
            guard version == revision else { return }
            errorMessage = message(for: error)
        }
    }

    func select(_ side: BedSide) {
        guard side != selectedSide else { return }
        revision += 1
        updates.invalidate()
        isSending = false
        debouncer.cancel()
        pendingLevel = nil
        selectedSide = side
        persistSelection()
        if isDemo {
            status = TemperatureStatus(currentLevel: side == .left ? 20 : -20, currentDeviceLevel: side == .left ? 22 : -12, stateType: "smart")
            return
        }
        status = nil
        Task {
            await updates.waitUntilIdle()
            await refreshTemperature()
        }
    }

    private func persistSelection() {
        guard let option = selectedOption else { return }
        SharedSettings.sideSelection = SideSelection(sideUserId: option.assignment.userId, side: option.id, label: option.watchLabel)
        pushContext()
    }

    // MARK: Control

    func step(_ delta: Int) {
        guard !isSending || updates.isSending, let base = displayLevel else { return }
        updates.discardQueued()
        pendingLevel = TemperatureFormat.stepped(raw: base, by: delta)
        debouncer.call { [weak self] in await self?.commitLevel() }
    }

    private func commitLevel() async {
        guard let target = pendingLevel, let option = selectedOption else { return }
        if isDemo {
            status = TemperatureStatus(currentLevel: target, currentDeviceLevel: status?.currentDeviceLevel, stateType: "smart")
            pendingLevel = nil
            return
        }
        isSending = true
        updates.submit(userId: option.assignment.userId, level: target, isOn: status?.isOn) { [weak self] result in
            guard let self else { return }
            switch result {
            case .sent(let level, let isOn):
                self.status = TemperatureStatus(currentLevel: level, currentDeviceLevel: self.status?.currentDeviceLevel,
                                                stateType: isOn.map { $0 ? "smart" : "off" })
                if self.pendingLevel == level { self.pendingLevel = nil }
                SharedSettings.recordLevel(level, isOn: isOn)
                self.errorMessage = nil
            case .failed(let error, let isOn):
                self.status?.stateType = isOn.map { $0 ? "smart" : "off" }
                self.errorMessage = self.message(for: error)
                if !self.debouncer.isPending, !self.updates.hasQueuedRequest { self.pendingLevel = nil }
            }
            self.isSending = self.pendingLevel != nil && !self.debouncer.isPending
        }
    }

    func setPower(_ on: Bool) async {
        guard let option = selectedOption, !updates.isSending, !debouncer.isPending, !isSending else { return }
        if isDemo {
            status?.stateType = on ? "smart" : "off"
            return
        }
        updates.invalidate()
        isSending = true
        let version = revision
        defer { isSending = false }
        do {
            try await client.setPower(userId: option.assignment.userId, on: on)
            guard version == revision else { return }
            status?.stateType = on ? "smart" : "off"
            await refreshTemperature()
        } catch {
            errorMessage = message(for: error)
        }
    }

    // MARK: Watch

    func watchContext() async -> WatchContext {
        WatchContext(credentials: await client.credentials, selection: SharedSettings.sideSelection)
    }

    func pushContext() {
        guard !isDemo else { return }
        Task { PhoneSession.shared.push(await watchContext()) }
    }

    /// The watch's token expired: refresh (password grant if needed) and reply with fresh context.
    func handleNeedToken(force: Bool) async -> WatchContext {
        guard !isDemo, let creds = await client.credentials else { return .signedOut }
        if force || creds.needsRefresh() {
            _ = try? await client.refresh()
        }
        return await watchContext()
    }

    private func message(for error: Error) -> String {
        if case EightSleepError.unauthorized = error { return "Session expired — sign out and sign in again." }
        return error.localizedDescription
    }
}
