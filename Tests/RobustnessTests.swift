import XCTest

/// A controllable suspension that deliberately ignores Task cancellation, like a late WC reply.
actor TestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

actor HTTPStub {
    struct Reply {
        var status: Int
        var json: String = "{}"
        var headers: [String: String] = [:]
        var gate: TestGate? = nil
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    var onRequest: (() -> Void)?
    init(_ replies: [Reply]) { self.replies = replies }
    func notify(_ action: @escaping () -> Void) { onRequest = action }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw EightSleepError.network("Unexpected extra request") }
        let reply = replies.removeFirst()
        onRequest?()
        if let gate = reply.gate { await gate.wait() }
        return (Data(reply.json.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.status,
                    httpVersion: nil, headerFields: reply.headers)!)
    }
}

final class NetworkingTests: XCTestCase {
    private func credentials() -> Credentials {
        Credentials(accessToken: "old", refreshToken: "refresh", expiresAt: .distantFuture, userId: "me")
    }
    private func client(_ stub: HTTPStub) -> EightSleepClient {
        EightSleepClient(credentials: credentials(), store: nil, transport: { try await stub.send($0) })
    }

    func test401RefreshesAndRetriesOnce() async throws {
        let stub = HTTPStub([
            .init(status: 401),
            .init(status: 200, json: #"{"access_token":"fresh","expires_in":3600}"#),
            .init(status: 200, json: #"{"user":{"userId":"me"}}"#)
        ])
        let api = client(stub)
        let me = try await api.me()
        XCTAssertEqual(me.userId, "me")
        let requests = await stub.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET"])
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
        let saved = await api.credentials
        XCTAssertEqual(saved?.userId, "me") // refresh may omit userId
    }

    func testSecond401IsNotRetried() async {
        let stub = HTTPStub([.init(status: 401),
            .init(status: 200, json: #"{"access_token":"fresh"}"#), .init(status: 401)])
        do { _ = try await client(stub).me(); XCTFail("Expected session error") }
        catch { XCTAssertEqual(error as? EightSleepError, .unauthorized) }
        let requests = await stub.requests
        XCTAssertEqual(requests.count, 3)
    }

    func test429HonorsRetryAfterAndBlocksFurtherRequests() async {
        let stub = HTTPStub([.init(status: 429, headers: ["Retry-After": "120"])])
        let api = EightSleepClient(credentials: credentials(), store: nil,
            now: { Date(timeIntervalSince1970: 1000) }, transport: { try await stub.send($0) })
        for _ in 0..<2 {
            do { _ = try await api.me(); XCTFail("Expected rate limit") }
            catch { XCTAssertEqual(error as? EightSleepError, .rateLimited) }
        }
        let requests = await stub.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(EightSleepClient.retryDate("120", now: Date(timeIntervalSince1970: 1000)),
                       Date(timeIntervalSince1970: 1120))
    }

    func testRetryAfterHTTPDateAndDefault() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(EightSleepClient.retryDate("Thu, 01 Jan 1970 00:02:00 GMT", now: now), now.addingTimeInterval(120))
        XCTAssertEqual(EightSleepClient.retryDate(nil, now: now), now.addingTimeInterval(60))
    }

    func testRefreshFinishingAfterSignOutCannotRestoreCredentials() async throws {
        let gate = TestGate()
        let started = expectation(description: "Refresh suspended")
        let stub = HTTPStub([.init(status: 200, json: #"{"access_token":"late"}"#, gate: gate)])
        await stub.notify { started.fulfill() }
        let api = client(stub)
        let refresh = Task { try await api.refresh() }
        await fulfillment(of: [started], timeout: 2)
        await api.signOut()
        await gate.open()
        do { _ = try await refresh.value; XCTFail("Stale refresh accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        let saved = await api.credentials
        XCTAssertNil(saved)
    }

    func testPhoneFallbackFinishingAfterSignOutCannotRestoreCredentials() async {
        let gate = TestGate()
        let started = expectation(description: "Phone reply suspended")
        let api = EightSleepClient(credentials: Credentials(accessToken: "old", expiresAt: .distantPast), store: nil)
        await api.setHandlers(onChange: nil, fallback: {
            started.fulfill()
            await gate.wait()
            return Credentials(accessToken: "late-phone", expiresAt: .distantFuture)
        })
        let refresh = Task { try await api.refresh() }
        await fulfillment(of: [started], timeout: 2)
        await api.signOut()
        await gate.open()
        do { _ = try await refresh.value; XCTFail("Stale fallback accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        let saved = await api.credentials
        XCTAssertNil(saved)
    }

    func testOlderPhoneFallbackCannotReplaceWatchToken() async {
        let current = Credentials(accessToken: "watch", expiresAt: Date(timeIntervalSince1970: 2000))
        let api = EightSleepClient(credentials: current, store: nil)
        await api.setHandlers(onChange: nil, fallback: {
            Credentials(accessToken: "older-phone", expiresAt: Date(timeIntervalSince1970: 1000))
        })
        do { _ = try await api.refresh(); XCTFail("Older fallback accepted") }
        catch { XCTAssertEqual(error as? EightSleepError, .needsPhone) }
        let saved = await api.credentials
        XCTAssertEqual(saved, current)
    }

    func testConcurrentRefreshUsesOneGrant() async throws {
        let gate = TestGate()
        let started = expectation(description: "Grant started")
        let stub = HTTPStub([.init(status: 200, json: #"{"access_token":"fresh"}"#, gate: gate)])
        await stub.notify { started.fulfill() }
        let api = client(stub)
        let first = Task { try await api.refresh() }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { try await api.refresh() }
        // Actor barrier gives the second caller a chance to join the suspended refresh.
        for _ in 0..<10 { await Task.yield() }
        await gate.open()
        let a = try await first.value
        let b = try await second.value
        XCTAssertEqual(a.accessToken, b.accessToken)
        let requests = await stub.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testPasswordGrant400401403ShowsWrongPassword() async {
        for code in [400, 401, 403] {
            let stub = HTTPStub([.init(status: code)])
            do { _ = try await client(stub).login(email: "test@example.invalid", password: "fake"); XCTFail("Expected failure") }
            catch {
                XCTAssertEqual(error as? EightSleepError, .invalidCredentials)
                XCTAssertEqual(error.localizedDescription, "Wrong email or password.")
            }
        }
        XCTAssertNotEqual(EightSleepError.unauthorized.localizedDescription, EightSleepError.invalidCredentials.localizedDescription)
    }

    func testPartnerProfile403IsOptional() async throws {
        let stub = HTTPStub([.init(status: 403)])
        let profile = try await client(stub).user(id: "partner")
        XCTAssertNil(profile)
    }
}

final class ConservativeStateTests: XCTestCase {
    func testMissingTemperatureFieldsRemainUnknown() throws {
        for json in ["{}", #"{"currentLevel":null,"currentState":{}}"#] {
            let status = try JSONDecoder().decode(TemperatureStatus.self, from: Data(json.utf8))
            XCTAssertNil(status.currentLevel)
            XCTAssertNil(status.stateType)
            XCTAssertNil(status.isOn)
        }
    }

    func testSameSideContextPreservesPendingControls() {
        let same = WatchContext(signedIn: true, accessToken: "new-token", sideUserId: "left")
        XCTAssertFalse(same.shouldResetControls(currentSideUserId: "left"))
        XCTAssertTrue(same.shouldResetControls(currentSideUserId: "right"))
        XCTAssertFalse(WatchContext(signedIn: true).shouldResetControls(currentSideUserId: "left"))
    }

    func testCurrentDeviceIsPreferredWithDevicesFallback() throws {
        let decoder = JSONDecoder()
        let current = try decoder.decode(UserProfile.self, from: Data(#"{"devices":["first"],"currentDevice":{"id":"active"}}"#.utf8))
        XCTAssertEqual(current.preferredDeviceId, "active")
        let fallback = try decoder.decode(UserProfile.self, from: Data(#"{"devices":["first"]}"#.utf8))
        XCTAssertEqual(fallback.preferredDeviceId, "first")
        let empty = try decoder.decode(UserProfile.self, from: Data("{}".utf8))
        XCTAssertNil(empty.preferredDeviceId)
    }

    func testOlderPhoneTokenCannotReplaceWatchToken() {
        let current = Credentials(accessToken: "watch", expiresAt: Date(timeIntervalSince1970: 2000), issuedAt: Date(timeIntervalSince1970: 1000))
        var incoming = Credentials(accessToken: "phone", expiresAt: Date(timeIntervalSince1970: 1999))
        XCTAssertFalse(incoming.shouldReplace(current))
        incoming.expiresAt = current.expiresAt
        incoming.issuedAt = Date(timeIntervalSince1970: 999)
        XCTAssertFalse(incoming.shouldReplace(current))
        incoming.issuedAt = Date(timeIntervalSince1970: 1001)
        XCTAssertTrue(incoming.shouldReplace(current))
        incoming.expiresAt = Date(timeIntervalSince1970: 2001)
        XCTAssertTrue(incoming.shouldReplace(current))
        XCTAssertTrue(incoming.shouldReplace(nil))
    }
}

@MainActor
final class LevelUpdateTests: XCTestCase {
    func testLatestValueWinsWithOnePowerOnAndNoConcurrentWrites() async {
        let gate = TestGate()
        let started = expectation(description: "First PUT started")
        let finished = expectation(description: "Latest PUT completed")
        var levels: [Int] = []
        var powerCalls = 0
        var active = 0
        var maximumActive = 0
        let sender = LevelUpdateCoordinator(power: { _ in powerCalls += 1 }, level: { _, value in
            active += 1
            maximumActive = max(maximumActive, active)
            levels.append(value)
            if value == 20 { started.fulfill(); await gate.wait() }
            active -= 1
        })
        sender.submit(userId: "left", level: 20, isOn: false) { _ in }
        await fulfillment(of: [started], timeout: 2)
        sender.submit(userId: "left", level: 30, isOn: false) { _ in XCTFail("Intermediate target should be dropped") }
        sender.submit(userId: "left", level: 40, isOn: false) { result in
            if case .sent(let level, let isOn) = result {
                XCTAssertEqual(level, 40)
                XCTAssertEqual(isOn, true)
            } else { XCTFail("Expected success") }
            finished.fulfill()
        }
        await gate.open()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(levels, [20, 40])
        XCTAssertEqual(powerCalls, 1)
        XCTAssertEqual(maximumActive, 1)
    }

    func testNewTapDiscardsPreviouslyQueuedTargetUntilDebounceSettles() async {
        let gate = TestGate()
        let started = expectation(description: "First write")
        var levels: [Int] = []
        let sender = LevelUpdateCoordinator(power: { _ in }, level: { _, value in
            levels.append(value)
            if value == 10 { started.fulfill(); await gate.wait() }
        })
        sender.submit(userId: "left", level: 10, isOn: true) { _ in }
        await fulfillment(of: [started], timeout: 2)
        sender.submit(userId: "left", level: 20, isOn: true) { _ in XCTFail("Superseded target") }
        sender.discardQueued() // A new tap to 30 restarts the 600 ms debounce.
        await gate.open()
        await sender.waitUntilIdle()
        XCTAssertEqual(levels, [10])
        sender.submit(userId: "left", level: 30, isOn: true) { _ in }
        await sender.waitUntilIdle()
        XCTAssertEqual(levels, [10, 30])
    }

    func testLevelFailureReportsRollbackAndKeepsLatestQueuedTarget() async {
        let gate = TestGate()
        let started = expectation(description: "First write")
        var powerCalls = 0
        var serverLevel = 0
        var failed = false
        let sender = LevelUpdateCoordinator(power: { _ in powerCalls += 1 }, level: { _, value in
            if value == 10 {
                started.fulfill()
                await gate.wait()
                throw EightSleepError.http(500)
            }
        })
        sender.submit(userId: "left", level: 10, isOn: false) { result in
            if case .failed(_, let isOn) = result {
                failed = true
                XCTAssertEqual(isOn, true) // Power succeeded even though the level PUT failed.
            }
        }
        await fulfillment(of: [started], timeout: 2)
        sender.submit(userId: "left", level: 30, isOn: false) { result in
            if case .sent(let level, _) = result { serverLevel = level }
        }
        await gate.open()
        await sender.waitUntilIdle()
        XCTAssertTrue(failed)
        XCTAssertEqual(serverLevel, 30)
        XCTAssertEqual(powerCalls, 1)
    }

    func testUnknownPowerStateDoesNotTurnSideOn() async {
        let finished = expectation(description: "Sent")
        let sender = LevelUpdateCoordinator(power: { _ in XCTFail("Unknown state must not trigger power-on") }, level: { _, _ in })
        sender.submit(userId: "left", level: 10, isOn: nil) { result in
            if case .sent(_, let isOn) = result { XCTAssertNil(isOn) }
            else { XCTFail("Expected success") }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
    }

    func testSideChangeDiscardsQueuedWritesAndStaleCallbacks() async {
        let gate = TestGate()
        let started = expectation(description: "Started")
        let finished = expectation(description: "New side sent")
        var writes: [String] = []
        let sender = LevelUpdateCoordinator(power: { _ in }, level: { user, _ in
            writes.append(user)
            if user == "left" { started.fulfill(); await gate.wait() }
        })
        sender.submit(userId: "left", level: 10, isOn: true) { _ in XCTFail("Old callback") }
        await fulfillment(of: [started], timeout: 2)
        sender.submit(userId: "left", level: 20, isOn: true) { _ in XCTFail("Old queued callback") }
        sender.invalidate()
        sender.submit(userId: "right", level: -20, isOn: true) { _ in finished.fulfill() }
        await gate.open()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(writes, ["left", "right"])
    }

    func testLoadGateCoalescesLaunchAndSceneActive() {
        let gate = LoadGate()
        let now = Date()
        XCTAssertTrue(gate.begin(now: now))
        XCTAssertFalse(gate.begin(now: now, force: true))
        gate.end(now: now)
        XCTAssertFalse(gate.begin(now: now.addingTimeInterval(1)))
        XCTAssertTrue(gate.begin(now: now.addingTimeInterval(3)))
    }
}
