import Foundation

/// Raw API levels are -100…100; Eight Sleep's app shows -10…+10 (1 step = 10 raw).
enum TemperatureFormat {
    static let rawRange = -100...100
    static let stepSize = 10

    /// pyEight RAW_TO_FAHRENHEIT_MAP.
    static let rawToFahrenheit: [Int: Int] = [
        -100: 55, -99: 56, -97: 57, -95: 58, -94: 59, -92: 60, -90: 61, -86: 62, -81: 63, -77: 64,
        -72: 65, -68: 66, -63: 67, -58: 68, -54: 69, -49: 70, -44: 71, -40: 72, -35: 73, -31: 74,
        -26: 75, -21: 76, -18: 77, -17: 77, -12: 78, -7: 79, -3: 80, 1: 81, 4: 82, 7: 83,
        10: 84, 14: 85, 16: 86, 17: 86, 20: 87, 23: 88, 26: 89, 29: 90, 32: 91, 35: 92,
        38: 93, 41: 94, 44: 95, 48: 96, 51: 97, 54: 98, 57: 99, 60: 100, 63: 101, 66: 102,
        69: 103, 72: 104, 75: 105, 78: 106, 80: 107, 81: 107, 85: 108, 88: 109, 92: 110, 100: 111,
    ]

    static func clampRaw(_ raw: Int) -> Int {
        min(max(raw, rawRange.lowerBound), rawRange.upperBound)
    }

    /// Raw → app level (-10…+10), rounded half away from zero.
    static func appLevel(raw: Int) -> Int {
        Int((Double(raw) / Double(stepSize)).rounded())
    }

    /// "+3", "−2" (U+2212 minus) or "0".
    static func levelText(raw: Int) -> String {
        let level = appLevel(raw: raw)
        if level > 0 { return "+\(level)" }
        if level < 0 { return "\u{2212}\(-level)" }
        return "0"
    }

    /// Approximate °F using the nearest key in the pyEight table (ties → lower key).
    static func fahrenheit(raw: Int) -> Int {
        let clamped = clampRaw(raw)
        let key = rawToFahrenheit.keys.min { a, b in
            let da = abs(a - clamped), db = abs(b - clamped)
            return da == db ? a < b : da < db
        }!
        return rawToFahrenheit[key]!
    }

    static func fahrenheitText(raw: Int) -> String { "~\(fahrenheit(raw: raw))°F" }

    /// Moves by whole app steps, snapping to the step grid and clamping.
    static func stepped(raw: Int, by steps: Int) -> Int {
        clampRaw((appLevel(raw: raw) + steps) * stepSize)
    }
}
