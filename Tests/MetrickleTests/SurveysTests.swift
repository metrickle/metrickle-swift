import XCTest
@testable import Metrickle

private let day: Int64 = 86_400_000

private func campaign(_ patch: (inout Targeting) -> Void = { _ in }, id: String = "cmp_1") -> CampaignConfig {
    var t = Targeting(trigger: Trigger(kind: .load, delayMs: 0), sampleRate: 1, frequency: Frequency(kind: .once))
    patch(&t)
    return CampaignConfig(id: id, questions: [
        Question(id: "nps", type: .nps, prompt: "How likely are you to recommend us?", required: true),
        Question(id: "why", type: .text, prompt: "Why?", required: false),
    ], targeting: t, version: 1)
}

private let base = EligibilityContext(anonymousId: "anon-1", userId: nil, platform: "web", appVersion: "2.4.1", a11y: [], now: 100 * day)

final class SurveysTests: XCTestCase {
    /// Same values as `unitHash` in surveys.ts (computed with Bun).
    func testUnitHashMatchesJS() {
        XCTAssertEqual(unitHash(""), 0.5043428998906165, accuracy: 1e-15)
        XCTAssertEqual(unitHash("a"), 0.8908105595037341, accuracy: 1e-15)
        XCTAssertEqual(unitHash("anon-1:cmp_1"), 0.10740100289694965, accuracy: 1e-15)
        XCTAssertEqual(unitHash("u1:cmp_2"), 0.9209592742845416, accuracy: 1e-15)
        XCTAssertEqual(unitHash("héllo 😀:x"), 0.07844235422089696, accuracy: 1e-15) // UTF-16 code units, surrogates included
    }

    func testMatchPattern() {
        XCTAssertTrue(matchPattern("/checkout*", "/checkout/done"))
        XCTAssertTrue(matchPattern("Home", "Home"))
        XCTAssertFalse(matchPattern("Home", "Home2"))
        XCTAssertFalse(matchPattern("2.4*", nil))
        XCTAssertTrue(matchPattern("*", ""))
    }

    func testTargeting() {
        let empty = SurveyState()
        XCTAssertTrue(eligible(campaign(), base, empty))
        XCTAssertFalse(eligible(campaign { $0.platforms = ["ios"] }, base, empty))
        XCTAssertTrue(eligible(campaign { $0.appVersions = ["2.4*"] }, base, empty))
        XCTAssertFalse(eligible(campaign { $0.appVersions = ["2.3*", "3.0.0"] }, base, empty))
        XCTAssertFalse(eligible(campaign { $0.a11y = ["screen_reader"] }, base, empty))
        var sr = base
        sr.a11y = ["screen_reader"]
        XCTAssertTrue(eligible(campaign { $0.a11y = ["screen_reader"] }, sr, empty))
        XCTAssertFalse(eligible(campaign { $0.identifiedOnly = true }, base, empty))
        var identified = base
        identified.userId = "u1"
        XCTAssertTrue(eligible(campaign { $0.identifiedOnly = true }, identified, empty))
        XCTAssertFalse(eligible(campaign { $0.sampleRate = 0 }, base, empty))
        // Sampling is deterministic per user and campaign.
        let r = unitHash("anon-1:cmp_1")
        XCTAssertTrue(eligible(campaign { $0.sampleRate = r + 0.001 }, base, empty))
        XCTAssertFalse(eligible(campaign { $0.sampleRate = r }, base, empty))
    }

    func testFrequencyCapsAndGlobalCooldown() {
        let now = base.now
        func shown(_ s: CampaignState, last: Int64? = nil) -> SurveyState {
            SurveyState(last: last ?? now - 40 * day, c: ["cmp_1": s])
        }
        XCTAssertFalse(eligible(campaign(), base, shown(CampaignState(shown: now - 400 * day)))) // once
        let ua = campaign { $0.frequency = Frequency(kind: .untilAnswered, days: 30) }
        XCTAssertTrue(eligible(ua, base, shown(CampaignState(shown: now - 40 * day, dismissed: now - 40 * day))))
        XCTAssertFalse(eligible(ua, base, shown(CampaignState(shown: now - 10 * day), last: now - 10 * day)))
        XCTAssertFalse(eligible(ua, base, shown(CampaignState(shown: now - 40 * day, answered: now - 40 * day))))
        let rec = campaign { $0.frequency = Frequency(kind: .recurring, days: 30) }
        XCTAssertTrue(eligible(rec, base, shown(CampaignState(shown: now - 31 * day, answered: now - 31 * day))))
        XCTAssertFalse(eligible(rec, base, shown(CampaignState(shown: now - 29 * day))))
        // Another survey shown in the last day blocks everything.
        XCTAssertFalse(eligible(campaign(id: "cmp_2"), base, SurveyState(last: now - globalCooldownMs + 1000)))
    }

    func testStateJSONMatchesJSShape() throws {
        let js = #"{"last":1700000000000,"c":{"cmp_1":{"shown":1700000000000,"dismissed":1700000001000}}}"#
        let state = try JSONDecoder().decode(SurveyState.self, from: Data(js.utf8))
        XCTAssertEqual(state, SurveyState(last: 1_700_000_000_000, c: ["cmp_1": CampaignState(shown: 1_700_000_000_000, dismissed: 1_700_000_001_000)]))
    }

    func testConfigDecodingSkipsUnknownCampaigns() throws {
        let json = #"""
        {"v":1,"campaigns":[
          {"id":"a","version":2,"questions":[{"id":"q","type":"nps","prompt":"How likely?"}],"targeting":{"trigger":{"kind":"page","match":"Checkout*"}}},
          {"id":"b","version":1,"questions":[{"id":"q","type":"hologram","prompt":"?"}],"targeting":{"trigger":{"kind":"load"}}}
        ],"feedback":{"enabled":true,"branding":{"poweredBy":false,"accent":"#1f6fcf"}},"heatmaps":{"enabled":false,"sampleRate":1}}
        """#
        let cfg = try JSONDecoder().decode(SdkConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.campaigns.map(\.id), ["a"])
        let a = cfg.campaigns[0]
        XCTAssertEqual(a.questions[0].required, true)
        XCTAssertEqual(a.targeting.trigger.delayMs, 0)
        XCTAssertEqual(a.targeting.sampleRate, 1)
        XCTAssertEqual(a.targeting.frequency.kind, .once)
        XCTAssertEqual(cfg.feedback?.branding?.accent, "#1f6fcf")
    }

    func testEnginePageTriggerShowsOnceAndAnswersBecomeEvents() async throws {
        let storage = MemoryStorage()
        let transport = RecordingTransport()
        let client = makeClient(storage: storage, transport: transport)
        let surveys = Locked<[ActiveSurvey]>([])
        let first = expectation(description: "shown")
        client.surveys.onShow { s in
            surveys.update { $0.append(s) }
            first.fulfill()
        }
        client.q.async {
            client.apply(SdkConfig(campaigns: [campaign { $0.trigger = Trigger(kind: .page, match: "Checkout*", delayMs: 0) }]))
        }

        client.screen("Pricing")
        await sleep(ms: 100)
        XCTAssertEqual(surveys.get().count, 0)

        client.screen("Checkout Done")
        await fulfillment(of: [first], timeout: 2)
        let s = try XCTUnwrap(surveys.get().first)
        s.shown()
        s.answer(s.campaign.questions[0], Answer(score: 3))
        s.answer(s.campaign.questions[1], Answer(text: "  The pay button did nothing  "))
        s.complete()

        // Frequency "once": never again, even on the trigger screen.
        client.screen("Checkout Again")
        await sleep(ms: 100)
        XCTAssertEqual(surveys.get().count, 1)

        await client.flushNow()
        let events = transport.events.filter { $0.name.hasPrefix("$survey_") }
        XCTAssertEqual(events.map(\.name), ["$survey_shown", "$survey_answered", "$survey_answered"])
        let nps = events[1].properties!, why = events[2].properties!
        XCTAssertEqual(nps["campaign"], "cmp_1")
        XCTAssertEqual(nps["version"], 1)
        XCTAssertEqual(nps["question"], "nps")
        XCTAssertEqual(nps["type"], "nps")
        XCTAssertEqual(nps["score"], 3)
        XCTAssertEqual(nps["value"], .null)
        XCTAssertEqual(nps["text"], .null)
        XCTAssertEqual(nps["completed"], .null)
        XCTAssertEqual(why["question"], "why")
        XCTAssertEqual(why["text"], "The pay button did nothing")
        XCTAssertEqual(why["completed"], true)
        XCTAssertEqual(nps["response"], why["response"])
        XCTAssertEqual(events[1].path, "Checkout Done")

        let saved = try JSONDecoder().decode(SurveyState.self, from: Data(XCTUnwrap(storage.get("mk_surveys")).utf8))
        XCTAssertNotNil(saved.c["cmp_1"]?.shown)
        XCTAssertNotNil(saved.last)
        client.stopTimer()
    }

    func testDismissRecordsPositionAndAnswerCount() async throws {
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)
        let shown = expectation(description: "shown")
        let box = Locked<ActiveSurvey?>(nil)
        client.surveys.onShow { s in box.set(s); shown.fulfill() }
        client.q.async { client.apply(SdkConfig(campaigns: [campaign()])) }
        await fulfillment(of: [shown], timeout: 2)
        let s = try XCTUnwrap(box.get())
        s.shown()
        s.answer(s.campaign.questions[0], Answer(score: 9))
        s.dismiss(atIndex: 1)
        await client.flushNow()
        let dismissed = try XCTUnwrap(transport.events.first { $0.name == "$survey_dismissed" })
        XCTAssertEqual(dismissed.properties?["at"], 1)
        XCTAssertEqual(dismissed.properties?["answered"], 1)
        client.stopTimer()
    }

    func testCookielessClientsNeverShowSurveys() async {
        let client = makeClient(storage: nil)
        let count = Locked(0)
        client.surveys.onShow { _ in count.update { $0 += 1 } }
        client.q.async { client.apply(SdkConfig(campaigns: [campaign()])) }
        client.screen("Home")
        await sleep(ms: 100)
        XCTAssertEqual(count.get(), 0)
        client.stopTimer()
    }

    func testNoRendererMeansNoSurvey() async {
        // On macOS there is no built-in sheet, so without onShow nothing is presented or recorded.
        let transport = RecordingTransport()
        let client = makeClient(transport: transport)
        client.q.async { client.apply(SdkConfig(campaigns: [campaign()])) }
        client.screen("Home")
        await sleep(ms: 100)
        await client.flushNow()
        XCTAssertFalse(transport.events.contains { $0.name.hasPrefix("$survey_") })
        client.stopTimer()
    }

    // MARK: Follow-ups

    /// Same vectors as "follow-up matching" in surveys.test.ts.
    func testFollowUpMatches() {
        let nps = FollowUpWhen(questionId: "nps", min: 0, max: 6)
        let cases: [(FollowUpWhen?, [String: Answer], Bool)] = [
            (nil, [:], true),
            (nps, ["nps": Answer(score: 3)], true),
            (nps, ["nps": Answer(score: 0)], true),
            (nps, ["nps": Answer(score: 6)], true),
            (nps, ["nps": Answer(score: 7)], false),
            (FollowUpWhen(questionId: "nps", min: 9), ["nps": Answer(score: 10)], true),
            (nps, [:], false),
            (nps, ["nps": Answer()], false),
            (FollowUpWhen(questionId: "why", choices: ["Price", "Speed"]), ["why": Answer(values: ["Speed", "Other"])], true),
            (FollowUpWhen(questionId: "why", choices: ["Price"]), ["why": Answer(values: ["Speed"])], false),
            (FollowUpWhen(questionId: "why", choices: ["Price"]), ["why": Answer(score: 3)], false),
        ]
        for (i, (when, answers, expected)) in cases.enumerated() {
            XCTAssertEqual(followUpMatches(when, answers), expected, "case \(i)")
        }
    }

    func testFollowUpDecodingIsLossy() throws {
        let json = #"""
        {"v":1,"campaigns":[
          {"id":"a","version":1,"questions":[{"id":"nps","type":"nps","prompt":"?"}],"targeting":{"trigger":{"kind":"load"}},
           "followUp":{"studyId":"std_1","kind":"moderated","prompt":"Talk to us?","when":{"questionId":"nps","max":6},"incentive":"A £20 voucher","durationMin":30}},
          {"id":"b","version":1,"questions":[{"id":"nps","type":"nps","prompt":"?"}],"targeting":{"trigger":{"kind":"load"}},
           "followUp":{"studyId":"std_2","kind":"hologram","prompt":"?"}},
          {"id":"c","version":1,"questions":[{"id":"nps","type":"nps","prompt":"?"}],"targeting":{"trigger":{"kind":"load"}},"followUp":"nonsense"}
        ]}
        """#
        let cfg = try JSONDecoder().decode(SdkConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.campaigns.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(cfg.campaigns[0].followUp, FollowUpConfig(
            studyId: "std_1", kind: .moderated, prompt: "Talk to us?", when: FollowUpWhen(questionId: "nps", max: 6),
            incentive: "A £20 voucher", durationMin: 30))
        XCTAssertNil(cfg.campaigns[1].followUp)
        XCTAssertNil(cfg.campaigns[2].followUp)
    }

    func testFollowUpCopyMatchesWeb() {
        XCTAssertEqual(followUpDescription(FollowUpConfig(studyId: "s", kind: .moderated, prompt: "?", durationMin: 30)),
                       "A 30-minute video call at a time that suits you.")
        XCTAssertEqual(followUpDescription(FollowUpConfig(studyId: "s", kind: .moderated, prompt: "?")),
                       "A video call at a time that suits you.")
        XCTAssertEqual(followUpDescription(FollowUpConfig(studyId: "s", kind: .unmoderated, prompt: "?")),
                       "A short self-guided test of the site. Takes about 10–15 minutes.")
    }

    func testSafeInviteURL() {
        XCTAssertEqual(safeInviteURL("https://app.example.com/s/abc", host: "https://in.example.com")?.absoluteString, "https://app.example.com/s/abc")
        XCTAssertNil(safeInviteURL("http://app.example.com/s/abc", host: "https://in.example.com"))
        XCTAssertNotNil(safeInviteURL("http://localhost:8787/s/abc", host: "http://localhost:8787"))
        XCTAssertNil(safeInviteURL("javascript:alert(1)", host: "http://localhost:8787"))
        XCTAssertNil(safeInviteURL(nil, host: "https://in.example.com"))
        XCTAssertNil(safeInviteURL("not a url", host: "https://in.example.com"))
    }

    private func followUpSurvey(_ followUp: FollowUpConfig?, transport: RecordingTransport,
                                host: String = "https://in.example.com") async throws -> (Metrickle, ActiveSurvey) {
        let client = makeClient(transport: transport, options: .init(host: host, flushInterval: 3600))
        let shown = expectation(description: "shown")
        let box = Locked<ActiveSurvey?>(nil)
        client.surveys.onShow { s in box.set(s); shown.fulfill() }
        var c = campaign()
        c.followUp = followUp
        let config = SdkConfig(campaigns: [c])
        client.q.async { client.apply(config) }
        await fulfillment(of: [shown], timeout: 2)
        return (client, try XCTUnwrap(box.get()))
    }

    func testQualifyingResponseGetsLinkAndRecordsFollowUpOnce() async throws {
        let transport = RecordingTransport()
        transport.invite = (201, Data(#"{"url":"https://app.example.com/s/abc"}"#.utf8))
        let fu = FollowUpConfig(studyId: "std_1", kind: .moderated, prompt: "Talk to us?",
                                when: FollowUpWhen(questionId: "nps", max: 6), durationMin: 30)
        let (client, s) = try await followUpSurvey(fu, transport: transport)
        client.identify("user-9")
        s.shown()
        s.answer(s.campaign.questions[0], Answer(score: 4))
        s.complete()
        XCTAssertEqual(s.followUp?.studyId, "std_1")
        XCTAssertTrue(s.qualifies())
        let url = await s.invite()
        XCTAssertEqual(url?.absoluteString, "https://app.example.com/s/abc")
        // Asked once per response, however often the renderer calls it.
        let again = await s.invite(timeout: 5)
        XCTAssertEqual(again, url)
        let invites = transport.requests.filter { $0.url?.path == "/v1/studies/invite" }
        XCTAssertEqual(invites.count, 1)
        let req = try XCTUnwrap(invites.first)
        XCTAssertEqual(req.url?.absoluteString, "https://in.example.com/v1/studies/invite")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-metrickle-key"), "k")
        XCTAssertEqual(req.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), client.onQueue { client.userAgent })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: String])
        XCTAssertEqual(body, [
            "writeKey": "k", "studyId": "std_1", "campaignId": "cmp_1", "response": s.response,
            "anonymousId": try XCTUnwrap(client.identity.anonymousId), "userId": "user-9",
        ])

        s.followUpOffered()
        s.followUpOffered()
        s.followUpAccepted()
        s.followUpAccepted()
        await client.flushNow()
        let fuEvents = transport.events.filter { $0.name == "$survey_follow_up" }.map(\.properties)
        XCTAssertEqual(fuEvents, [
            ["campaign": "cmp_1", "version": 1, "response": .string(s.response), "study": "std_1", "accepted": false],
            ["campaign": "cmp_1", "version": 1, "response": .string(s.response), "study": "std_1", "accepted": true],
        ])
        client.stopTimer()
    }

    func testNoInviteWhenNotQualifyingFullUnsafeOrMissing() async throws {
        let fu = FollowUpConfig(studyId: "std_1", kind: .unmoderated, prompt: "Try it?", when: FollowUpWhen(questionId: "nps", max: 6))

        // Not qualifying: no request at all.
        let ta = RecordingTransport()
        let (a, sa) = try await followUpSurvey(fu, transport: ta)
        sa.answer(sa.campaign.questions[0], Answer(score: 9))
        XCTAssertFalse(sa.qualifies())
        let ua = await sa.invite()
        XCTAssertNil(ua)
        XCTAssertFalse(ta.requests.contains { $0.url?.path == "/v1/studies/invite" })
        a.stopTimer()

        // 409 study_full.
        let tb = RecordingTransport()
        tb.invite = (409, Data(#"{"error":"study_full"}"#.utf8))
        let (b, sb) = try await followUpSurvey(fu, transport: tb)
        sb.answer(sb.campaign.questions[0], Answer(score: 2))
        let ub = await sb.invite()
        XCTAssertNil(ub)
        b.stopTimer()

        // 201 with an unsafe link, and 200 with a good one: neither is used.
        for (status, link) in [(201, "javascript:alert(1)"), (201, "http://app.example.com/s/abc"), (200, "https://app.example.com/s/abc")] {
            let t = RecordingTransport()
            t.invite = (status, Data(#"{"url":"\#(link)"}"#.utf8))
            let (c, sc) = try await followUpSurvey(fu, transport: t)
            sc.answer(sc.campaign.questions[0], Answer(score: 2))
            let u = await sc.invite()
            XCTAssertNil(u, "\(status) \(link)")
            c.stopTimer()
        }

        // Network error.
        let te = RecordingTransport()
        te.invite = (-1, Data())
        let (e, se) = try await followUpSurvey(fu, transport: te)
        se.answer(se.campaign.questions[0], Answer(score: 2))
        let ue = await se.invite()
        XCTAssertNil(ue)
        e.stopTimer()

        // http link is fine when the SDK itself talks to an http host (local testing).
        let tl = RecordingTransport()
        tl.invite = (201, Data(#"{"url":"http://localhost:8787/s/abc"}"#.utf8))
        let (l, sl) = try await followUpSurvey(fu, transport: tl, host: "http://localhost:8787")
        sl.answer(sl.campaign.questions[0], Answer(score: 2))
        let ul = await sl.invite()
        XCTAssertEqual(ul?.absoluteString, "http://localhost:8787/s/abc")
        l.stopTimer()

        // Opted out: no request.
        let to = RecordingTransport()
        to.invite = (201, Data(#"{"url":"https://app.example.com/s/abc"}"#.utf8))
        let (o, so) = try await followUpSurvey(fu, transport: to)
        so.answer(so.campaign.questions[0], Answer(score: 2))
        o.optOut()
        let uo = await so.invite()
        XCTAssertNil(uo)
        XCTAssertFalse(to.requests.contains { $0.url?.path == "/v1/studies/invite" })
        o.stopTimer()

        // No follow-up configured: nothing to offer, nothing recorded.
        let td = RecordingTransport()
        let (d, sd) = try await followUpSurvey(nil, transport: td)
        XCTAssertFalse(sd.qualifies())
        let ud = await sd.invite()
        XCTAssertNil(ud)
        sd.followUpOffered()
        sd.followUpAccepted()
        await d.flushNow()
        XCTAssertFalse(td.events.contains { $0.name == "$survey_follow_up" })
        d.stopTimer()
    }
}
