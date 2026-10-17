import Foundation

enum BedSide: String, Codable, CaseIterable {
    case left, right, solo

    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .solo: return "Solo"
        }
    }
}

struct SideAssignment: Equatable, Hashable, Codable {
    let side: BedSide
    let userId: String
}

enum SideResolver {
    /// Away mode can collapse/omit the top-level ids, so `awaySides` values win when present.
    /// One id, or the same id on both sides, means a solo bed.
    static func assignments(leftUserId: String?, rightUserId: String?,
                            awayLeftUserId: String? = nil, awayRightUserId: String? = nil) -> [SideAssignment] {
        let left = nonEmpty(awayLeftUserId) ?? nonEmpty(leftUserId)
        let right = nonEmpty(awayRightUserId) ?? nonEmpty(rightUserId)
        switch (left, right) {
        case let (l?, r?) where l == r: return [SideAssignment(side: .solo, userId: l)]
        case let (l?, r?): return [SideAssignment(side: .left, userId: l), SideAssignment(side: .right, userId: r)]
        case let (l?, nil): return [SideAssignment(side: .solo, userId: l)]
        case let (nil, r?): return [SideAssignment(side: .solo, userId: r)]
        case (nil, nil): return []
        }
    }

    static func assignments(from result: DeviceSidesResponse.Result) -> [SideAssignment] {
        assignments(leftUserId: result.leftUserId, rightUserId: result.rightUserId,
                    awayLeftUserId: result.awayLeftUserId, awayRightUserId: result.awayRightUserId)
    }

    /// Prefer the side reported by `currentDevice.side`, then the side owned by the user, then the first.
    static func defaultAssignment(in assignments: [SideAssignment], myUserId: String?, mySide: String?) -> SideAssignment? {
        if let side = mySide.flatMap({ BedSide(rawValue: $0.lowercased()) }),
           let match = assignments.first(where: { $0.side == side }) {
            return match
        }
        if let myUserId, let match = assignments.first(where: { $0.userId == myUserId }) {
            return match
        }
        return assignments.first
    }

    /// Picker label: "Left · Chase" (or just "Left").
    static func pickerLabel(side: BedSide, firstName: String?) -> String {
        guard let name = nonEmpty(firstName) else { return side.title }
        return "\(side.title) · \(name)"
    }

    /// Watch label: "Chase · Left" (or "Left side").
    static func watchLabel(side: BedSide, firstName: String?) -> String {
        guard let name = nonEmpty(firstName) else { return side == .solo ? "Bed" : "\(side.title) side" }
        return side == .solo ? name : "\(name) · \(side.title)"
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
