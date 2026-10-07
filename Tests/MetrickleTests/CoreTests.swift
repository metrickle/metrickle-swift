import XCTest
@testable import Metrickle

final class CoreTests: XCTestCase {
    func testBatchRequestAndJSONShape() async throws {
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)
        client.track("signup_started", properties: ["plan": "pro", "seats": 3, "trial": true, "coupon": nil, "empty": ""])
        client.track("no_props")
        await client.flushNow()

        let req = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://in.metrickle.com/v1/batch")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-metrickle-key"), "k")
        let ua = try XCTUnwrap(req.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertEqual(ua, "metrickle-ios/\(Metrickle.sdkVersion) (iOS 17.2; iPhone15,2)")
        XCTAssertNil(ua.range(of: "bot|crawl|spider|slurp|headless|lighthouse|pingdom|uptime|monitor|preview|curl|wget", options: [.regularExpression, .caseInsensitive]))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(json["writeKey"] as? String, "k")
        XCTAssertTrue(json["sentAt"] is NSNumber)
        let ctx = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertEqual(ctx["platform"] as? String, "ios")
        XCTAssertEqual(ctx["library"] as? [String: String], ["name": "metrickle-ios", "version": Metrickle.sdkVersion])
        XCTAssertEqual((ctx["device"] as? [String: Any])?["type"] as? String, "mobile")
        XCTAssertEqual((ctx["screen"] as? [String: Int])?["width"], 393)
        XCTAssertEqual((ctx["app"] as? [String: String])?["version"], "2.4.1")
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        let e = events[0]
        XCTAssertEqual(e["type"] as? String, "track")
        XCTAssertEqual(e["name"] as? String, "signup_started")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(e["id"] as? String)))
        XCTAssertTrue(e["ts"] is NSNumber)
        XCTAssertNotNil(e["anonymousId"] as? String)
        XCTAssertNotNil(e["sessionId"] as? String)
        XCTAssertNil(e["userId"]) // omitted, not null
        let props = try XCTUnwrap(e["properties"] as? [String: Any])
        XCTAssertEqual(props["plan"] as? String, "pro")
        XCTAssertEqual(props["seats"] as? Int, 3)
        XCTAssertEqual(props["trial"] as? Bool, true)
        XCTAssertTrue(props["coupon"] is NSNull)
        XCTAssertNil(events[1]["properties"], "empty properties are dropped")
        XCTAssertTrue(String(decoding: try XCTUnwrap(req.httpBody), as: UTF8.self).contains(#""seats":3"#))
        client.stopTimer()
    }

    func testPropertySanitizing() throws {
        var props: Properties = ["long": .string(String(repeating: "x", count: 2000)), "nan": .number(.nan), "inf": .number(.infinity)]
        for i in 0..<100 { props["k\(i)"] = .number(Double(i)) }
        let out = try XCTUnwrap(Metrickle.sanitize(props))
        XCTAssertEqual(out.count, 64)
        XCTAssertEqual(Metrickle.sanitize(["long": .string(String(repeating: "é", count: 2000))])?["long"], .string(String(repeating: "é", count: 1024)))
        XCTAssertEqual(Metrickle.sanitize(["nan": .number(.nan)])?["nan"], .null)
        XCTAssertNil(Metrickle.sanitize([:]))
        XCTAssertEqual(truncate("a😀b", 2), "a") // never splits a surrogate pair
    }

    func testCookielessSendsNoIds() async throws {
        let transport = RecordingTransport()
        let client = makeClient(storage: nil, transport: transport)
        client.track("x")
        await client.flushNow()
        let e = try XCTUnwrap(transport.events.first)
        XCTAssertNil(e.anonymousId)
        XCTAssertNil(e.sessionId)
        client.stopTimer()
    }

    func testFailedSendsAreRequeuedInOrderWithBackoff() async {
        let clock = TestClock()
        let transport = RecordingTransport(statuses: [500, 200])
        let client = makeClient(transport: transport, clock: clock)
        client.track("a")
        client.track("b")
        let first = await client.flushNow()
        XCTAssertFalse(first)
        let skipped = await client.flushNow() // still backing off (1s)
        XCTAssertFalse(skipped)
        XCTAssertEqual(transport.batches.count, 1)
        clock.advance(1_001)
        let second = await client.flushNow()
        XCTAssertTrue(second)
        XCTAssertEqual(transport.batches.count, 2)
        XCTAssertEqual(transport.batches[1].events.map(\.name), ["a", "b"])
        client.stopTimer()
    }

    func testClientErrorsDropAndRateLimitsRetry() async {
        let transport = RecordingTransport(statuses: [400, 429, -1, 200])
        let client = makeClient(transport: transport)
        client.track("bad")
        await client.flushNow() // 400: dropped
        client.track("limited")
        await client.flushNow() // 429: kept
        await client.flushAll() // network error: kept
        await client.flushAll()
        XCTAssertEqual(transport.batches.map { $0.events.map(\.name) }, [["bad"], ["limited"], ["limited"], ["limited"]])
        client.stopTimer()
    }

    func testBackgroundFlushSendsEverythingInChunks() async {
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)
        client.stopTimer()
        client.q.sync { client.flushLocked(force: false, completion: nil) } // nothing queued yet
        for i in 0..<19 { client.track("e\(i)") }
        client.sync()
        client.q.sync { for i in 19..<250 { client.capture(.track, "e\(i)") } } // no auto-flush race: queued in one go
        await sleep(ms: 50)
        await client.flushAll()
        let sizes = transport.batches.map(\.events.count)
        XCTAssertTrue(sizes.allSatisfy { $0 <= 100 })
        XCTAssertEqual(sizes.reduce(0, +), 250)
        XCTAssertEqual(Set(transport.events.map(\.name)).count, 250)
    }

    func testQueueSurvivesRestartAndDropsOldEvents() async throws {
        let storage = MemoryStorage()
        let clock = TestClock()
        let offline = RecordingTransport(statuses: [-1])
        let a = makeClient(storage: storage, transport: offline, clock: clock)
        a.track("old")
        a.sync()
        clock.advance(8 * 86_400_000)
        a.track("fresh")
        await a.flushNow() // fails: both requeued and persisted
        a.stopTimer()
        a.q.sync { a.saveQueue() }
        XCTAssertNotNil(storage.get("mk_queue"))

        let transport = RecordingTransport()
        let b = makeClient(storage: storage, transport: transport, clock: clock)
        await b.flushNow()
        XCTAssertEqual(transport.events.map(\.name), ["fresh"])
        XCTAssertEqual(storage.get("mk_aid"), transport.events.first?.anonymousId)
        b.q.sync { b.saveQueue() }
        XCTAssertNil(storage.get("mk_queue"))
        b.stopTimer()
    }

    func testQueueIsCappedAt1000DroppingOldest() async {
        let client = makeClient(transport: RecordingTransport(statuses: [500]))
        client.stopTimer()
        client.q.sync { for i in 0..<1005 { client.capture(.track, "e\(i)") } }
        await sleep(ms: 100) // the auto-flush at 20 events fails and its 100 events go back in front
        let names = client.q.sync { client.queue.map(\.name) }
        XCTAssertEqual(names.count, 1000)
        XCTAssertEqual(names.first, "e5")
        XCTAssertEqual(names.last, "e1004")
    }

    func testIdentifyResetOptOutAndSuperProperties() async throws {
        let storage = MemoryStorage()
        let transport = RecordingTransport()
        let client = makeClient(storage: storage, transport: transport)
        client.sync()
        let anon = storage.get("mk_aid")
        client.register(["plan": "pro"])
        client.identify("user-9", traits: ["email_domain": "acme.com"])
        client.track("x", properties: ["n": 1])
        client.reset()
        client.track("y")
        await client.flushNow()
        client.optOut() // discards anything unsent
        client.track("dropped")
        XCTAssertTrue(client.isOptedOut)
        XCTAssertEqual(storage.get("mk_optout"), "1")
        client.optIn()
        client.track("z")
        client.track("$reserved")
        await client.flushNow()

        let events = transport.events
        XCTAssertEqual(events.map(\.name), ["$identify", "x", "y", "z"])
        XCTAssertEqual(events[0].type, .identify)
        XCTAssertEqual(events[0].userId, "user-9")
        XCTAssertEqual(events[0].traits, ["email_domain": "acme.com"])
        XCTAssertEqual(events[1].userId, "user-9")
        XCTAssertEqual(events[1].properties, ["plan": "pro", "n": 1])
        XCTAssertNil(events[2].userId)
        XCTAssertNotEqual(events[2].anonymousId, anon)
        XCTAssertEqual(events[2].properties, ["plan": "pro"])
        XCTAssertNil(storage.get("mk_uid"))
        client.stopTimer()
    }

    func testNoNetworkAfterOptOut() async {
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)
        client.optOut()
        client.track("x")
        client.refreshConfig()
        await client.flushNow()
        let feedback = await client.feedback.submit(category: .bug, message: "Broken")
        XCTAssertFalse(feedback.ok)
        await sleep(ms: 50)
        XCTAssertTrue(transport.requests.isEmpty)
        client.stopTimer()
    }

    func testOptedOutFirstLaunchCreatesNoId() async {
        let storage = MemoryStorage(["mk_optout": "1"])
        let client = makeClient(storage: storage)
        client.sync()
        XCTAssertNil(storage.get("mk_aid"))
        XCTAssertNil(client.identity.anonymousId)
        client.stopTimer()
    }

    func testOptedOutWithStoredIdDoesNotUseIt() {
        let storage = MemoryStorage(["mk_optout": "1", "mk_aid": "old-id"])
        let client = makeClient(storage: storage)
        client.sync()
        XCTAssertNil(client.identity.anonymousId)
        client.stopTimer()
    }

    func testOptOutRemovesStoredIdsButKeepsUserAndConsent() async {
        let storage = MemoryStorage()
        let client = makeClient(storage: storage)
        client.identify("user-9")
        client.consent(replay: true)
        client.track("x")
        client.sync()
        XCTAssertNotNil(storage.get("mk_aid"))
        XCTAssertNotNil(storage.get("mk_sid"))
        client.q.sync { client.saveQueue() }
        XCTAssertNotNil(storage.get("mk_queue"))
        client.optOut()
        client.sync()
        XCTAssertNil(storage.get("mk_aid"))
        XCTAssertNil(storage.get("mk_sid"))
        XCTAssertNil(storage.get("mk_queue"))
        XCTAssertEqual(storage.get("mk_uid"), "user-9")
        XCTAssertEqual(storage.get("mk_consent"), "replay")
        XCTAssertEqual(client.identity, Metrickle.Identity(anonymousId: nil, userId: "user-9", sessionId: nil))
        client.stopTimer()
    }

    func testResetWhileOptedOutCreatesNoId() {
        let storage = MemoryStorage()
        let client = makeClient(storage: storage)
        client.optOut()
        client.reset()
        client.sync()
        XCTAssertNil(storage.get("mk_aid"))
        XCTAssertNil(client.identity.anonymousId)
        client.stopTimer()
    }

    func testOptInCreatesIdAndRefetchesConfig() async {
        let storage = MemoryStorage(["mk_optout": "1"])
        let transport = RecordingTransport()
        let client = makeClient(storage: storage, transport: transport)
        client.sync()
        XCTAssertNil(storage.get("mk_aid"))
        client.optIn()
        client.sync()
        let id = client.identity.anonymousId
        XCTAssertNotNil(id)
        XCTAssertEqual(storage.get("mk_aid"), id)
        XCTAssertNil(storage.get("mk_optout"))
        await sleep(ms: 50)
        XCTAssertEqual(transport.requests.map { $0.url?.path }, ["/v1/config"])
        client.stopTimer()
    }

    func testSessionsTimeOutAndPassiveEventsDoNotExtend() async throws {
        let clock = TestClock(0)
        let transport = RecordingTransport()
        let client = makeClient(transport: transport, clock: clock, options: .init(flushInterval: 3600, sessionTimeout: 1))
        clock.set(1)
        client.screen("A")
        clock.set(5_000)
        client.q.async { client.capture(.track, "$app_background") }
        clock.set(6_000)
        client.screen("B")
        await client.flushNow()
        let ids = transport.events.map(\.sessionId)
        XCTAssertEqual(ids[1], ids[0])
        XCTAssertNotEqual(ids[2], ids[0])
        client.stopTimer()
    }

    func testScreensSetPathReferrerAndUTurns() async throws {
        let clock = TestClock()
        let transport = RecordingTransport()
        let client = makeClient(transport: transport, clock: clock)
        client.screen("Home")
        clock.advance(10_000)
        client.screen("Pricing", properties: ["variant": "b"])
        client.track("cta_click")
        clock.advance(3_000)
        client.screen("Home")
        await client.flushNow()
        let e = transport.events
        XCTAssertEqual(e.map(\.name), ["$screen", "$screen", "cta_click", "$u_turn", "$screen"])
        XCTAssertEqual(e[1].type, .screen)
        XCTAssertEqual(e[1].path, "Pricing")
        XCTAssertEqual(e[1].title, "Pricing")
        XCTAssertEqual(e[1].referrer, "Home")
        XCTAssertEqual(e[1].properties, ["variant": "b"])
        XCTAssertEqual(e[2].path, "Pricing")
        XCTAssertEqual(e[3].path, "Pricing")
        XCTAssertEqual(e[3].properties, ["back_to": "Home", "dwell_ms": 3000])
        XCTAssertEqual(e[4].referrer, "Pricing")
        client.stopTimer()
    }

    func testFormErrorsCollapseDuplicates() async {
        let clock = TestClock()
        let transport = RecordingTransport()
        let client = makeClient(transport: transport, clock: clock)
        client.formError(form: "checkout", field: "card_number", reason: "invalid")
        client.formError(form: "checkout", field: "card_number", reason: "invalid")
        client.formError(form: "checkout", field: "postcode", reason: "required")
        client.sync()
        clock.advance(1_600)
        client.formError(form: "checkout", field: "card_number", reason: "invalid")
        client.formError(form: nil, field: "email", reason: "format")
        await client.flushNow()
        let e = transport.events
        XCTAssertEqual(e.count, 4)
        XCTAssertEqual(e[0].name, "$form_error")
        XCTAssertEqual(e[0].properties, ["form": "checkout", "field": "card_number", "reason": "invalid"])
        XCTAssertEqual(e[3].properties?["form"], .null)
        client.stopTimer()
    }

    func testBeforeSendCanEditOrDrop() async {
        let transport = RecordingTransport()
        let options = Metrickle.Options(flushInterval: 3600, beforeSend: { e in
            if e.name == "secret" { return nil }
            var e = e
            e.properties?["email"] = nil
            return e
        })
        let client = makeClient(transport: transport, options: options)
        client.track("secret")
        client.track("signup", properties: ["email": "a@b.c", "plan": "pro"])
        await client.flushNow()
        XCTAssertEqual(transport.events.map(\.name), ["signup"])
        XCTAssertEqual(transport.events[0].properties, ["plan": "pro"])
        client.stopTimer()
    }

    func testConsentIsPersisted() {
        let storage = MemoryStorage()
        let client = makeClient(storage: storage)
        client.consent(replay: true)
        XCTAssertTrue(client.hasReplayConsent)
        XCTAssertEqual(storage.get("mk_consent"), "replay")
        client.consent(replay: false)
        XCTAssertFalse(client.hasReplayConsent)
        XCTAssertEqual(storage.get("mk_consent"), "")
        client.stopTimer()
    }

    func testConfigFetchUsesWriteKeyAndAppliesAccent() async throws {
        let config = Data(##"{"v":1,"campaigns":[],"feedback":{"branding":{"accent":"#1f6fcf"}}}"##.utf8)
        let transport = RecordingTransport(config: config)
        let client = makeClient(transport: transport, options: .init(host: "https://example.test/", flushInterval: 3600), fetchConfig: true)
        await sleep(ms: 100)
        client.sync()
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://example.test/v1/config?key=k")
        XCTAssertEqual(client.accent.get(), "#1f6fcf")
        client.stopTimer()
    }

    func testFeedbackSubmission() async throws {
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)
        client.screen("Checkout")
        client.setA11y(["screen_reader", "large_text"])
        let result = await client.feedback.submit(category: .accessibility, message: "  The pay button has no label  ", rating: 2,
                                                  screenshot: "data:image/jpeg;base64,AAAA")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.id, "fb_1")
        let req = try XCTUnwrap(transport.requests.first { $0.url?.path == "/v1/feedback" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(body["writeKey"] as? String, "k")
        XCTAssertEqual(body["category"] as? String, "accessibility")
        XCTAssertEqual(body["message"] as? String, "The pay button has no label")
        XCTAssertEqual(body["rating"] as? Int, 2)
        XCTAssertEqual(body["path"] as? String, "Checkout")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["appVersion"] as? String, "2.4.1")
        XCTAssertEqual(body["a11y"] as? [String], ["screen_reader", "large_text"])
        XCTAssertEqual(body["locale"] as? String, "en-GB")
        XCTAssertEqual((body["device"] as? [String: String])?["model"], "iPhone15,2")
        XCTAssertNotNil(body["anonymousId"] as? String)
        XCTAssertNotNil(body["sessionId"] as? String)
        XCTAssertEqual(body["screenshot"] as? String, "data:image/jpeg;base64,AAAA")
        client.stopTimer()
    }

    func testFeedbackSwitchedOffForPlatform() async throws {
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)
        XCTAssertTrue(client.feedback.isEnabled)
        let json = #"{"v":1,"campaigns":[],"feedback":{"platforms":["web","android"],"enabled":true}}"#
        client.apply(try JSONDecoder().decode(SdkConfig.self, from: Data(json.utf8)))
        XCTAssertFalse(client.feedback.isEnabled)
        let result = await client.feedback.submit(category: .bug, message: "Broken")
        XCTAssertFalse(result.ok)
        XCTAssertNil(transport.requests.first { $0.url?.path == "/v1/feedback" })
        // Configs from before the setting existed allow every platform.
        client.apply(try JSONDecoder().decode(SdkConfig.self, from: Data(#"{"v":1,"campaigns":[],"feedback":{"enabled":true}}"#.utf8)))
        XCTAssertTrue(client.feedback.isEnabled)
        client.stopTimer()
    }

    func testContrastMatchesJS() {
        XCTAssertEqual(contrastRatio("#1f6fcf", "#ffffff"), 4.960978540464101, accuracy: 1e-9)
        XCTAssertEqual(contrastRatio("#777777", "#ffffff"), 4.478089453577214, accuracy: 1e-9)
        XCTAssertEqual(contrastRatio("#000000", "#ffffff"), 21, accuracy: 1e-9)
        XCTAssertEqual(contrastRatio("#007aff", "#1c1c1e"), 4.235707691731371, accuracy: 1e-9)
        XCTAssertEqual(textOn("#1f6fcf"), "#ffffff")
        XCTAssertEqual(textOn("#777777"), "#000000")
        XCTAssertEqual(textOn("#007aff"), "#000000")
    }
}

final class UTurnTests: XCTestCase {
    func testBackToThePreviousScreenAfterAShortStay() {
        var nav = UTurnDetector(thresholdMs: 7_000)
        XCTAssertNil(nav.visit("/a", at: 0))
        XCTAssertNil(nav.visit("/b", at: 10_000))
        XCTAssertEqual(nav.visit("/a", at: 13_000), UTurn(from: "/b", to: "/a", dwellMs: 3_000))
        // Staying long enough is a normal visit, not a u-turn.
        XCTAssertNil(nav.visit("/c", at: 20_000))
        XCTAssertNil(nav.visit("/a", at: 40_000))
        // Re-renders of the same screen are ignored.
        XCTAssertNil(nav.visit("/a", at: 41_000))
    }
}
