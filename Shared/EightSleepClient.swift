import Foundation

enum EightSleepError: LocalizedError, Equatable {
    case notSignedIn
    case invalidCredentials
    case unauthorized
    case rateLimited
    case needsPhone
    case noDevice
    case http(Int)
    case network(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in on your iPhone"
        case .invalidCredentials: return "Wrong email or password."
        case .unauthorized: return "Session expired — please sign in again."
        case .rateLimited: return "Eight Sleep is rate-limiting, try again in a minute"
        case .needsPhone: return "Open Eight Sleep Remote on your iPhone"
        case .noDevice: return "No Pod found on this account."
        case .http(let code): return "Eight Sleep returned an error (\(code))."
        case .network(let message): return message
        case .decoding: return "Unexpected response from Eight Sleep."
        }
    }
}

/// Minimal client for Eight Sleep's unofficial cloud API (as used by pyEight / eightctl).
actor EightSleepClient {
    // Public OAuth client baked into the Eight Sleep app and every open-source client.
    static let clientId = "0894c7f33bb94800a03f1f4df13a4f38"
    static let clientSecret = "f0954a3ed5763ba3d06834c73731a32f15f168f47d4f164751275def86db0c76"

    static let authURL = URL(string: "https://auth-api.8slp.net/v1/tokens")!
    static let clientAPI = URL(string: "https://client-api.8slp.net/v1")!
    static let appAPI = URL(string: "https://app-api.8slp.net/v1")!

    typealias ChangeHandler = (Credentials?) -> Void
    typealias Fallback = () async -> Credentials?

    private(set) var credentials: Credentials?
    private let store: TokenStore?
    private let session: URLSession
    private var onChange: ChangeHandler?
    /// Last-resort token source when refresh and password grants fail (the watch asks the phone).
    private var fallback: Fallback?
    private var refreshTask: Task<Credentials, Error>?

    init(credentials: Credentials?, store: TokenStore?, session: URLSession = .shared) {
        self.credentials = credentials
        self.store = store
        self.session = session
    }

    func setHandlers(onChange: ChangeHandler?, fallback: Fallback?) {
        self.onChange = onChange
        self.fallback = fallback
    }

    /// Replaces the stored credentials (e.g. tokens received from the phone).
    func setCredentials(_ new: Credentials?) {
        credentials = new
        if let new { store?.save(new) } else { store?.clear() }
        onChange?(new)
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        setCredentials(nil)
    }

    // MARK: Auth

    @discardableResult
    func login(email: String, password: String) async throws -> Credentials {
        let token = try await tokenRequest(["grant_type": "password", "username": email, "password": password])
        let creds = Credentials(accessToken: token.accessToken, refreshToken: token.refreshToken,
                                expiresAt: Date().addingTimeInterval(token.expiresIn ?? 3600),
                                userId: token.userId, email: email, password: password)
        setCredentials(creds)
        return creds
    }

    /// Refresh grant → password grant (if stored) → fallback. Concurrent callers share one refresh.
    @discardableResult
    func refresh() async throws -> Credentials {
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        let creds = try await task.value
        setCredentials(creds)
        return creds
    }

    private func performRefresh() async throws -> Credentials {
        guard let current = credentials else { throw EightSleepError.notSignedIn }
        func merged(_ t: TokenResponse) -> Credentials {
            var c = current
            c.accessToken = t.accessToken
            c.refreshToken = t.refreshToken ?? current.refreshToken
            c.expiresAt = Date().addingTimeInterval(t.expiresIn ?? 3600)
            c.userId = t.userId ?? current.userId
            return c
        }
        if let refreshToken = current.refreshToken {
            do {
                return merged(try await tokenRequest(["grant_type": "refresh_token", "refresh_token": refreshToken]))
            } catch EightSleepError.rateLimited {
                throw EightSleepError.rateLimited
            } catch {
                // fall through to the password grant
            }
        }
        if let email = current.email, let password = current.password {
            return merged(try await tokenRequest(["grant_type": "password", "username": email, "password": password]))
        }
        if let fallback, let fresh = await fallback() {
            return fresh
        }
        throw EightSleepError.needsPhone
    }

    func validAccessToken() async throws -> String {
        guard let creds = credentials else { throw EightSleepError.notSignedIn }
        if creds.needsRefresh() { return try await refresh().accessToken }
        return creds.accessToken
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var body = fields
        body["client_id"] = Self.clientId
        body["client_secret"] = Self.clientSecret
        do {
            let data = try await send("POST", Self.authURL, body: body, token: nil)
            return try decode(TokenResponse.self, data)
        } catch EightSleepError.unauthorized, EightSleepError.http(400), EightSleepError.http(403) {
            throw EightSleepError.invalidCredentials
        }
    }

    // MARK: Endpoints

    func me() async throws -> UserProfile {
        try decode(UserEnvelope.self, try await authorized("GET", Self.clientAPI.appendingPathComponent("users/me"))).user
    }

    func user(id: String) async throws -> UserProfile {
        try decode(UserEnvelope.self, try await authorized("GET", Self.clientAPI.appendingPathComponent("users/\(id)"))).user
    }

    func sides(deviceId: String) async throws -> [SideAssignment] {
        var components = URLComponents(url: Self.clientAPI.appendingPathComponent("devices/\(deviceId)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "filter", value: "leftUserId,rightUserId,awaySides")]
        let data = try await authorized("GET", components.url!)
        return SideResolver.assignments(from: try decode(DeviceSidesResponse.self, data).result)
    }

    func temperature(userId: String) async throws -> TemperatureStatus {
        try decode(TemperatureStatus.self, try await authorized("GET", temperatureURL(userId)))
    }

    func setPower(userId: String, on: Bool) async throws {
        _ = try await authorized("PUT", temperatureURL(userId), body: ["currentState": ["type": on ? "smart" : "off"]])
    }

    /// Sets the raw target level (-100…100), turning the side on first if it is off.
    func setLevel(userId: String, level: Int, turnOnFirst: Bool) async throws {
        if turnOnFirst { try await setPower(userId: userId, on: true) }
        _ = try await authorized("PUT", temperatureURL(userId), body: ["currentLevel": TemperatureFormat.clampRaw(level)])
    }

    private func temperatureURL(_ userId: String) -> URL {
        Self.appAPI.appendingPathComponent("users/\(userId)/temperature")
    }

    // MARK: Transport

    /// Bearer request that refreshes and retries once on 401.
    private func authorized(_ method: String, _ url: URL, body: [String: Any]? = nil) async throws -> Data {
        let token = try await validAccessToken()
        do {
            return try await send(method, url, body: body, token: token)
        } catch EightSleepError.unauthorized {
            let fresh = try await refresh().accessToken
            return try await send(method, url, body: body, token: fresh)
        }
    }

    private func send(_ method: String, _ url: URL, body: [String: Any]?, token: String?) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("okhttp/4.9.3", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EightSleepError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw EightSleepError.unauthorized
        case 429: throw EightSleepError.rateLimited
        default: throw EightSleepError.http(status)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw EightSleepError.decoding }
    }
}
