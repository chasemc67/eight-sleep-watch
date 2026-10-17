import XCTest

final class TemperatureFormatTests: XCTestCase {
    func testLevelText() {
        XCTAssertEqual(TemperatureFormat.levelText(raw: 30), "+3")
        XCTAssertEqual(TemperatureFormat.levelText(raw: -20), "\u{2212}2")
        XCTAssertEqual(TemperatureFormat.levelText(raw: 0), "0")
        XCTAssertEqual(TemperatureFormat.levelText(raw: 4), "0")
        XCTAssertEqual(TemperatureFormat.levelText(raw: 26), "+3")
        XCTAssertEqual(TemperatureFormat.levelText(raw: -25), "\u{2212}3")
        XCTAssertEqual(TemperatureFormat.levelText(raw: 100), "+10")
    }

    func testFahrenheitLookup() {
        XCTAssertEqual(TemperatureFormat.fahrenheit(raw: -100), 55)
        XCTAssertEqual(TemperatureFormat.fahrenheit(raw: 10), 84)
        XCTAssertEqual(TemperatureFormat.fahrenheit(raw: 30), 90)    // nearest 29
        XCTAssertEqual(TemperatureFormat.fahrenheit(raw: 0), 81)     // nearest 1
        XCTAssertEqual(TemperatureFormat.fahrenheit(raw: 100), 111)
        XCTAssertEqual(TemperatureFormat.fahrenheit(raw: 250), 111)  // clamped
        XCTAssertEqual(TemperatureFormat.fahrenheitText(raw: 10), "~84°F")
    }

    func testSteppingSnapsAndClamps() {
        XCTAssertEqual(TemperatureFormat.stepped(raw: 30, by: 1), 40)
        XCTAssertEqual(TemperatureFormat.stepped(raw: 33, by: 1), 40)
        XCTAssertEqual(TemperatureFormat.stepped(raw: 30, by: -1), 20)
        XCTAssertEqual(TemperatureFormat.stepped(raw: 100, by: 1), 100)
        XCTAssertEqual(TemperatureFormat.stepped(raw: -100, by: -1), -100)
    }
}

final class SideResolverTests: XCTestCase {
    func testLeftAndRight() {
        let a = SideResolver.assignments(leftUserId: "L", rightUserId: "R")
        XCTAssertEqual(a, [SideAssignment(side: .left, userId: "L"), SideAssignment(side: .right, userId: "R")])
    }

    func testSoloWhenSameOrSingle() {
        XCTAssertEqual(SideResolver.assignments(leftUserId: "A", rightUserId: "A"), [SideAssignment(side: .solo, userId: "A")])
        XCTAssertEqual(SideResolver.assignments(leftUserId: nil, rightUserId: "B"), [SideAssignment(side: .solo, userId: "B")])
        XCTAssertEqual(SideResolver.assignments(leftUserId: "", rightUserId: nil), [])
    }

    func testAwaySidesWin() {
        // Away mode collapsed the top-level ids onto one user.
        let a = SideResolver.assignments(leftUserId: "R", rightUserId: "R", awayLeftUserId: "L", awayRightUserId: nil)
        XCTAssertEqual(a, [SideAssignment(side: .left, userId: "L"), SideAssignment(side: .right, userId: "R")])
    }

    func testDefaultAssignment() {
        let a = SideResolver.assignments(leftUserId: "L", rightUserId: "R")
        XCTAssertEqual(SideResolver.defaultAssignment(in: a, myUserId: "L", mySide: "right")?.side, .right)
        XCTAssertEqual(SideResolver.defaultAssignment(in: a, myUserId: "R", mySide: nil)?.side, .right)
        XCTAssertEqual(SideResolver.defaultAssignment(in: a, myUserId: "X", mySide: nil)?.side, .left)
    }

    func testLabels() {
        XCTAssertEqual(SideResolver.pickerLabel(side: .left, firstName: "Chase"), "Left · Chase")
        XCTAssertEqual(SideResolver.pickerLabel(side: .right, firstName: nil), "Right")
        XCTAssertEqual(SideResolver.watchLabel(side: .left, firstName: "Chase"), "Chase · Left")
        XCTAssertEqual(SideResolver.watchLabel(side: .right, firstName: nil), "Right side")
    }
}

final class DecodingTests: XCTestCase {
    func testTokenResponse() throws {
        let json = #"{"access_token":"abc","expires_in":3600,"userId":"u1","token_type":"bearer"}"#
        let t = try JSONDecoder().decode(TokenResponse.self, from: Data(json.utf8))
        XCTAssertEqual(t.accessToken, "abc")
        XCTAssertEqual(t.expiresIn, 3600)
        XCTAssertEqual(t.userId, "u1")
        XCTAssertNil(t.refreshToken)

        let refreshed = #"{"access_token":"def","expires_in":3599.5,"refresh_token":"r2"}"#
        let r = try JSONDecoder().decode(TokenResponse.self, from: Data(refreshed.utf8))
        XCTAssertEqual(r.refreshToken, "r2")
        XCTAssertNil(r.userId)
    }

    func testTemperatureResponse() throws {
        let json = #"{"currentLevel":30,"currentDeviceLevel":-12.4,"currentState":{"type":"smart"},"smart":{"bedTimeLevel":10}}"#
        let t = try JSONDecoder().decode(TemperatureStatus.self, from: Data(json.utf8))
        XCTAssertEqual(t, TemperatureStatus(currentLevel: 30, currentDeviceLevel: -12, stateType: "smart"))
        XCTAssertEqual(t.isOn, true)

        let off = try JSONDecoder().decode(TemperatureStatus.self, from: Data(#"{"currentLevel":-20,"currentState":{"type":"off"}}"#.utf8))
        XCTAssertEqual(off.isOn, false)
        XCTAssertNil(off.currentDeviceLevel)
    }

    func testDeviceSidesResponse() throws {
        let json = #"{"result":{"leftUserId":"A","rightUserId":"A","awaySides":{"rightUserId":"B"}}}"#
        let r = try JSONDecoder().decode(DeviceSidesResponse.self, from: Data(json.utf8))
        XCTAssertEqual(SideResolver.assignments(from: r.result),
                       [SideAssignment(side: .left, userId: "A"), SideAssignment(side: .right, userId: "B")])
    }

    func testMeResponse() throws {
        let json = #"{"user":{"userId":"u1","firstName":"Chase","devices":["dev1"],"currentDevice":{"id":"dev1","side":"left"}}}"#
        let me = try JSONDecoder().decode(UserEnvelope.self, from: Data(json.utf8)).user
        XCTAssertEqual(me.devices, ["dev1"])
        XCTAssertEqual(me.currentDevice?.side, "left")
    }

    func testWatchContextRoundTripOmitsPassword() {
        let creds = Credentials(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1000),
                                userId: "u", email: "e@x.com", password: "secret")
        let ctx = WatchContext(credentials: creds, selection: SideSelection(sideUserId: "u", side: .left, label: "Chase · Left"))
        let dict = ctx.dictionary()
        XCTAssertNil(dict["password"])
        XCTAssertNil(dict["email"])
        XCTAssertFalse(dict.values.contains { ($0 as? String) == "secret" })
        let back = WatchContext(dictionary: dict)
        XCTAssertEqual(back, ctx)
        XCTAssertNil(back?.credentials?.password)
        XCTAssertNil(back?.credentials?.email)
    }
}

@MainActor
final class DebouncerTests: XCTestCase {
    func testCoalescesRapidCalls() async throws {
        let debouncer = Debouncer(delay: 0.1)
        var fired: [Int] = []
        for i in 1...5 { debouncer.call { fired.append(i) } }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(fired, [5])
    }
}
