import Foundation

/// Tokens (and, on the iPhone only, the login) persisted in the Keychain.
struct Credentials: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var userId: String?
    var email: String?
    var password: String?

    /// True when the token expires within `margin` seconds (default: refresh ~2 min early).
    func needsRefresh(now: Date = Date(), margin: TimeInterval = 120) -> Bool {
        now.addingTimeInterval(margin) >= expiresAt
    }
}

/// `POST https://auth-api.8slp.net/v1/tokens`
struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Double?
    let userId: String?
    let refreshToken: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case userId
        case userIdSnake = "user_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        expiresIn = try? c.decode(Double.self, forKey: .expiresIn)
        refreshToken = try? c.decode(String.self, forKey: .refreshToken)
        userId = (try? c.decode(String.self, forKey: .userId)) ?? (try? c.decode(String.self, forKey: .userIdSnake))
    }
}

/// `GET https://app-api.8slp.net/v1/users/{id}/temperature`
struct TemperatureStatus: Decodable, Equatable {
    var currentLevel: Int
    var currentDeviceLevel: Int?
    var stateType: String

    var isOn: Bool { stateType.lowercased() != "off" }

    init(currentLevel: Int, currentDeviceLevel: Int?, stateType: String) {
        self.currentLevel = currentLevel
        self.currentDeviceLevel = currentDeviceLevel
        self.stateType = stateType
    }

    private enum CodingKeys: String, CodingKey { case currentLevel, currentDeviceLevel, currentState }
    private struct State: Decodable { let type: String }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentLevel = c.lossyInt(forKey: .currentLevel) ?? 0
        currentDeviceLevel = c.lossyInt(forKey: .currentDeviceLevel)
        stateType = (try? c.decode(State.self, forKey: .currentState))?.type ?? "off"
    }
}

/// `user` object from `/v1/users/me` and `/v1/users/{id}`.
struct UserProfile: Decodable, Equatable {
    struct CurrentDevice: Decodable, Equatable {
        let id: String?
        let side: String?
    }
    let userId: String?
    let firstName: String?
    let lastName: String?
    let devices: [String]?
    let currentDevice: CurrentDevice?
}

struct UserEnvelope: Decodable { let user: UserProfile }

/// `GET /v1/devices/{id}?filter=leftUserId,rightUserId,awaySides`
struct DeviceSidesResponse: Decodable {
    struct Result: Decodable {
        let leftUserId: String?
        let rightUserId: String?
        let awayLeftUserId: String?
        let awayRightUserId: String?

        private enum CodingKeys: String, CodingKey { case leftUserId, rightUserId, awaySides }
        private struct Away: Decodable { let leftUserId: String?; let rightUserId: String? }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            leftUserId = try? c.decode(String.self, forKey: .leftUserId)
            rightUserId = try? c.decode(String.self, forKey: .rightUserId)
            let away = try? c.decode(Away.self, forKey: .awaySides)
            awayLeftUserId = away?.leftUserId
            awayRightUserId = away?.rightUserId
        }
    }
    let result: Result
}

extension KeyedDecodingContainer {
    /// Decodes an Int that the server may send as a float.
    func lossyInt(forKey key: Key) -> Int? {
        if let i = try? decode(Int.self, forKey: key) { return i }
        if let d = try? decode(Double.self, forKey: key) { return Int(d.rounded()) }
        return nil
    }
}
