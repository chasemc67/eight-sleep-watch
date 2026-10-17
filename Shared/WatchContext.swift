import Foundation

/// The payload the phone sends to the watch over WatchConnectivity. Never contains the password.
struct WatchContext: Equatable {
    var signedIn: Bool
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?
    var userId: String?
    var sideUserId: String?
    var sideLabel: String?
    var side: BedSide?

    static let signedOut = WatchContext(signedIn: false)

    init(signedIn: Bool, accessToken: String? = nil, refreshToken: String? = nil, expiresAt: Date? = nil,
         userId: String? = nil, sideUserId: String? = nil, sideLabel: String? = nil, side: BedSide? = nil) {
        self.signedIn = signedIn
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userId = userId
        self.sideUserId = sideUserId
        self.sideLabel = sideLabel
        self.side = side
    }

    init(credentials: Credentials?, selection: SideSelection?) {
        guard let credentials else { self.init(signedIn: false); return }
        self.init(signedIn: true, accessToken: credentials.accessToken, refreshToken: credentials.refreshToken,
                  expiresAt: credentials.expiresAt, userId: credentials.userId,
                  sideUserId: selection?.sideUserId, sideLabel: selection?.label, side: selection?.side)
    }

    init?(dictionary d: [String: Any]) {
        guard let signedIn = d["signedIn"] as? Bool else { return nil }
        self.init(signedIn: signedIn,
                  accessToken: d["accessToken"] as? String,
                  refreshToken: d["refreshToken"] as? String,
                  expiresAt: (d["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0) },
                  userId: d["userId"] as? String,
                  sideUserId: d["sideUserId"] as? String,
                  sideLabel: d["sideLabel"] as? String,
                  side: (d["side"] as? String).flatMap(BedSide.init(rawValue:)))
    }

    /// Property-list dictionary for `updateApplicationContext` / message replies.
    func dictionary() -> [String: Any] {
        var d: [String: Any] = ["signedIn": signedIn, "sentAt": Date().timeIntervalSince1970]
        d["accessToken"] = accessToken
        d["refreshToken"] = refreshToken
        d["expiresAt"] = expiresAt?.timeIntervalSince1970
        d["userId"] = userId
        d["sideUserId"] = sideUserId
        d["sideLabel"] = sideLabel
        d["side"] = side?.rawValue
        return d
    }

    /// Watch-side credentials (no email/password).
    var credentials: Credentials? {
        guard signedIn, let accessToken else { return nil }
        return Credentials(accessToken: accessToken, refreshToken: refreshToken,
                           expiresAt: expiresAt ?? .distantPast, userId: userId)
    }

    var selection: SideSelection? {
        guard let sideUserId else { return nil }
        let side = side ?? .solo
        return SideSelection(sideUserId: sideUserId, side: side, label: sideLabel ?? SideResolver.watchLabel(side: side, firstName: nil))
    }
}
