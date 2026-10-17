import Foundation

enum AppGroup {
    static let id = "group.com.AnomalousResearch.EightSleepWatch"
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
}

/// The side this device controls (persisted in App Group defaults).
struct SideSelection: Codable, Equatable {
    var sideUserId: String
    var side: BedSide
    var label: String
}

/// Small App Group-backed settings shared by app, watch app and widget.
enum SharedSettings {
    private enum Key {
        static let selection = "sideSelection"
        static let lastLevel = "lastLevel"
        static let lastIsOn = "lastIsOn"
        static let lastUpdated = "lastUpdated"
    }

    static var sideSelection: SideSelection? {
        get {
            guard let data = AppGroup.defaults.data(forKey: Key.selection) else { return nil }
            return try? JSONDecoder().decode(SideSelection.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                AppGroup.defaults.set(data, forKey: Key.selection)
            } else {
                AppGroup.defaults.removeObject(forKey: Key.selection)
            }
        }
    }

    static var lastLevel: Int? {
        AppGroup.defaults.object(forKey: Key.lastLevel) as? Int
    }

    static var lastIsOn: Bool? {
        AppGroup.defaults.object(forKey: Key.lastIsOn) as? Bool
    }

    static func recordLevel(_ raw: Int, isOn: Bool) {
        let d = AppGroup.defaults
        d.set(raw, forKey: Key.lastLevel)
        d.set(isOn, forKey: Key.lastIsOn)
        d.set(Date(), forKey: Key.lastUpdated)
    }

    static func clear() {
        let d = AppGroup.defaults
        [Key.selection, Key.lastLevel, Key.lastIsOn, Key.lastUpdated].forEach { d.removeObject(forKey: $0) }
    }
}

enum DemoMode {
    /// Launch with `-demo` or `ESR_DEMO=1` to show fake data without networking.
    static var isEnabled: Bool {
        let info = ProcessInfo.processInfo
        return info.arguments.contains("-demo") || info.environment["ESR_DEMO"] == "1"
    }
}
