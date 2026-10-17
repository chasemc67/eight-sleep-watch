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
            status = TemperatureStatus(currentLevel: 30, currentDeviceLevel: 22, stateType: "smart")
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
        debouncer.cancel()
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
    func loadAll() async {
        guard !isDemo else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let me = try await client.me()
            guard let deviceId = me.devices?.first ?? me.currentDevice?.id else { throw EightSleepError.noDevice }
            let assignments = try await client.sides(deviceId: deviceId)
            var options: [SideOption] = []
            for a in assignments {
                var name: String?
                if a.userId == me.userId {
                    name = me.firstName
                } else {
                    name = try? await client.user(id: a.userId).firstName // may 403 for other members
                }
                options.append(SideOption(assignment: a, firstName: name))
            }
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
            errorMessage = message(for: error)
        }
    }

    func refreshTemperature() async {
        guard let option = selectedOption else { return }
        if isDemo { return }
        do {
            let s = try await client.temperature(userId: option.assignment.userId)
            status = s
            if !debouncer.isPending { pendingLevel = nil }
            SharedSettings.recordLevel(s.currentLevel, isOn: s.isOn)
            errorMessage = nil
        } catch {
            errorMessage = message(for: error)
        }
    }

    func select(_ side: BedSide) {
        guard side != selectedSide else { return }
        debouncer.cancel()
        pendingLevel = nil
        selectedSide = side
        persistSelection()
        if isDemo {
            status = TemperatureStatus(currentLevel: side == .left ? 30 : -20, currentDeviceLevel: side == .left ? 22 : -12, stateType: "smart")
            return
        }
        status = nil
        Task { await refreshTemperature() }
    }

    private func persistSelection() {
        guard let option = selectedOption else { return }
        SharedSettings.sideSelection = SideSelection(sideUserId: option.assignment.userId, side: option.id, label: option.watchLabel)
        pushContext()
    }

    // MARK: Control

    func step(_ delta: Int) {
        guard let base = displayLevel else { return }
        pendingLevel = TemperatureFormat.stepped(raw: base, by: delta)
        debouncer.call { [weak self] in await self?.commitLevel() }
    }

    private func commitLevel() async {
        guard let target = pendingLevel, let option = selectedOption else { return }
        let wasOn = status?.isOn ?? false
        if isDemo {
            status = TemperatureStatus(currentLevel: target, currentDeviceLevel: status?.currentDeviceLevel, stateType: "smart")
            pendingLevel = nil
            return
        }
        isSending = true
        defer { isSending = false }
        do {
            try await client.setLevel(userId: option.assignment.userId, level: target, turnOnFirst: !wasOn)
            status = TemperatureStatus(currentLevel: target, currentDeviceLevel: status?.currentDeviceLevel,
                                       stateType: wasOn ? (status?.stateType ?? "smart") : "smart")
            if !debouncer.isPending { pendingLevel = nil }
            SharedSettings.recordLevel(target, isOn: true)
            errorMessage = nil
        } catch {
            errorMessage = message(for: error)
            pendingLevel = nil
            await refreshTemperature()
        }
    }

    func setPower(_ on: Bool) async {
        guard let option = selectedOption else { return }
        if isDemo {
            status?.stateType = on ? "smart" : "off"
            return
        }
        do {
            try await client.setPower(userId: option.assignment.userId, on: on)
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
