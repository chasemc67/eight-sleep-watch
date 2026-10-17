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
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport
    private let now: () -> Date
    private var blockedUntil = Date.distantPast
    private var generation = 0
    private var onChange: ChangeHandler?
    /// Last-resort token source when refresh and password grants fail (the watch asks the phone).
    private var fallback: Fallback?
    private var refreshTask: Task<Credentials, Error>?

    init(credentials: Credentials?, store: TokenStore?, session: URLSession = .shared,
         now: @escaping () -> Date = Date.init, transport: Transport? = nil) {
        self.credentials = credentials
        self.store = store
        self.transport = transport ?? { try await session.data(for: $0) }
        self.now = now
    }

    func setHandlers(onChange: ChangeHandler?, fallback: Fallback?) {
        self.onChange = onChange
        self.fallback = fallback
    }

    /// Replaces the stored credentials (e.g. tokens received from the phone).
    func setCredentials(_ new: Credentials?) {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        credentials = new
        if let new { store?.save(new) } else { store?.clear() }
        onChange?(new)
    }

    func signOut() { setCredentials(nil) }

    // MARK: Auth

    @discardableResult
    func login(email: String, password: String) async throws -> Credentials {
        let version = generation
        let token = try await tokenRequest(["grant_type": "password", "username": email, "password": password])
        guard version == generation else { throw CancellationError() }
        let creds = Credentials(accessToken: token.accessToken, refreshToken: token.refreshToken,
                                expiresAt: now().addingTimeInterval(token.expiresIn ?? 3600),
                                userId: token.userId, email: email, password: password, issuedAt: now())
        setCredentials(creds)
        return creds
    }

    /// Refresh grant → password grant (if stored) → fallback. Concurrent callers share one refresh.
    @discardableResult
    func refresh() async throws -> Credentials {
        let version = generation
        if let refreshTask {
            let value = try await refreshTask.value
            guard version == generation else { throw CancellationError() }
            return value
        }
        let task = Task { () throws -> Credentials in
            let creds = try await self.performRefresh()
            guard version == self.generation else { throw CancellationError() }
            // Saving a refresh does not start a new credential generation.
            self.credentials = creds
            self.store?.save(creds)
            self.onChange?(creds)
            return creds
        }
        refreshTask = task
        defer { if version == generation { refreshTask = nil } }
        return try await task.value
    }

    private func performRefresh() async throws -> Credentials {
        guard let current = credentials else { throw EightSleepError.notSignedIn }
        func merged(_ t: TokenResponse) -> Credentials {
            var c = current
            c.accessToken = t.accessToken
            c.refreshToken = t.refreshToken ?? current.refreshToken
            c.expiresAt = now().addingTimeInterval(t.expiresIn ?? 3600)
            c.userId = t.userId ?? current.userId
            c.issuedAt = now()
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
        if let fallback, let fresh = await fallback(), fresh.shouldReplace(current) {
            return fresh
        }
        throw EightSleepError.needsPhone
    }

    func validAccessToken() async throws -> String {
        guard let creds = credentials else { throw EightSleepError.notSignedIn }
        if creds.needsRefresh(now: now()) { return try await refresh().accessToken }
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
            if fields["grant_type"] == "password" { throw EightSleepError.invalidCredentials }
            throw EightSleepError.unauthorized
        }
    }

    // MARK: Endpoints

    func me() async throws -> UserProfile {
        try decode(UserEnvelope.self, try await authorized("GET", Self.clientAPI.appendingPathComponent("users/me"))).user
    }

    func user(id: String) async throws -> UserProfile? {
        do {
            return try decode(UserEnvelope.self, try await authorized("GET", Self.clientAPI.appendingPathComponent("users/\(id)"))).user
        } catch EightSleepError.http(403) {
            return nil // A household member can keep their profile private.
        }
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
        let version = generation
        let token = try await validAccessToken()
        guard version == generation else { throw CancellationError() }
        do {
            let data = try await send(method, url, body: body, token: token)
            guard version == generation else { throw CancellationError() }
            return data
        } catch EightSleepError.unauthorized {
            guard version == generation else { throw CancellationError() }
            let fresh = try await refresh().accessToken
            guard version == generation else { throw CancellationError() }
            let data = try await send(method, url, body: body, token: fresh)
            guard version == generation else { throw CancellationError() }
            return data
        }
    }

    private func send(_ method: String, _ url: URL, body: [String: Any]?, token: String?) async throws -> Data {
        guard now() >= blockedUntil else { throw EightSleepError.rateLimited }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("okhttp/4.9.3", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let data: Data, response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw EightSleepError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw EightSleepError.unauthorized
        case 429:
            let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            blockedUntil = Self.retryDate(header, now: now())
            throw EightSleepError.rateLimited
        default: throw EightSleepError.http(status)
        }
    }

    static func retryDate(_ header: String?, now: Date) -> Date {
        if let header, let seconds = Double(header), seconds.isFinite {
            return now.addingTimeInterval(max(0, seconds))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        if let header, let date = formatter.date(from: header) { return max(now, date) }
        return now.addingTimeInterval(60)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw EightSleepError.decoding }
    }
}
