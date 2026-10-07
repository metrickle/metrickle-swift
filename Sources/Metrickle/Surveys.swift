import Foundation

/*
 Headless survey engine, a port of `surveys.ts`. It decides whether and when to show a campaign
 (trigger, targeting, sampling, frequency caps) and turns answers into `$survey_*` events.
 Rendering is either the built-in accessible sheet or your own UI via `surveys.onShow`.
 */

public struct Answer: Sendable, Equatable {
    public var score: Int?
    /// Choice answers.
    public var values: [String]?
    public var text: String?

    public init(score: Int? = nil, values: [String]? = nil, text: String? = nil) {
        self.score = score; self.values = values; self.text = text
    }
}

/// A survey that should be on screen now. Methods are safe to call from any thread.
public final class ActiveSurvey: @unchecked Sendable, Identifiable {
    public let campaign: CampaignConfig
    public var id: String { response }
    /// The campaign's follow-up: an invite into a study (a booked video call or a self-guided test), offered after the
    /// last answer when `qualifies()`. Nil when the campaign has none or the study isn't recruiting.
    public var followUp: FollowUpConfig? { campaign.followUp }
    let response: String
    let path: String?
    weak var engine: SurveyEngine?
    /// Answers given so far (engine queue only).
    var answered = 0

    private struct FollowUpState {
        /// This response's answers by question, for the follow-up condition.
        var answers: [String: Answer] = [:]
        var invite: Task<URL?, Never>?
        var offered = false
        var accepted = false
    }
    private let state = Locked(FollowUpState())

    init(campaign: CampaignConfig, response: String, path: String?, engine: SurveyEngine) {
        self.campaign = campaign; self.response = response; self.path = path; self.engine = engine
    }

    /// Call once the survey is actually on screen.
    public func shown() { engine?.perform { $0.shown(self) } }
    public func answer(_ question: Question, _ answer: Answer) {
        state.update { $0.answers[question.id] = answer }
        engine?.perform { $0.answer(self, question, answer) }
    }
    /// Call after the last answer.
    public func complete() { engine?.perform { $0.complete(self) } }
    /// The user closed it; `atIndex` is the question they were on.
    public func dismiss(atIndex: Int) { engine?.perform { $0.dismiss(self, at: atIndex) } }

    /// Whether this response qualifies for the follow-up (false when there is none). Call after the last answer.
    public func qualifies() -> Bool {
        guard let followUp else { return false }
        return followUpMatches(followUp.when, state.get().answers)
    }

    /// The respondent's personal study link, or nil (no follow-up, not qualifying, opted out, the study is full, or
    /// any error). Asks the server at most once per response, however often it's called. Show the invite only when
    /// this returns a link.
    public func invite() async -> URL? {
        guard let followUp, qualifies(), let client = engine?.client, !client.isOptedOut else { return nil }
        let task = state.update { s -> Task<URL?, Never> in
            if let t = s.invite { return t }
            let t = Task { await client.requestInvite(studyId: followUp.studyId, campaignId: self.campaign.id, response: self.response) }
            s.invite = t
            return t
        }
        return await task.value
    }

    /// `invite()`, or nil if it takes longer than `seconds` (the built-in sheet waits 5s).
    func invite(timeout seconds: Double) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            let done = Locked(false)
            let finish: @Sendable (URL?) -> Void = { url in
                if done.update({ d -> Bool in defer { d = true }; return !d }) { cont.resume(returning: url) }
            }
            Task { finish(await self.invite()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                finish(nil)
            }
        }
    }

    /// Call when the invite is on screen. Sends `$survey_follow_up` with `accepted: false`, once per response.
    public func followUpOffered() {
        guard followUp != nil, state.update({ s -> Bool in defer { s.offered = true }; return !s.offered }) else { return }
        engine?.perform { $0.followUp(self, accepted: false) }
    }

    /// Call when the respondent takes up the invite (before opening the link). Sends `$survey_follow_up` with
    /// `accepted: true`, once per response.
    public func followUpAccepted() {
        guard followUp != nil, state.update({ s -> Bool in defer { s.accepted = true }; return !s.accepted }) else { return }
        engine?.perform { $0.followUp(self, accepted: true) }
    }
}

public typealias SurveyRenderer = @MainActor @Sendable (ActiveSurvey) -> Void

/// Survey controls on a client: `Metrickle.shared?.surveys`.
public final class Surveys: @unchecked Sendable {
    weak var client: Metrickle?
    private let custom = Locked<(token: Int, render: SurveyRenderer)?>(nil)
    private let builtIn = Locked(true)
    private let tokens = Locked(0)

    /// Show campaigns in the built-in accessible sheet when no `onShow` renderer is set. Default true.
    public var useBuiltInSheet: Bool {
        get { builtIn.get() }
        set { builtIn.set(newValue); rendererChanged() }
    }

    /// Render surveys with your own UI. Called on the main thread when a campaign's trigger and targeting match; call
    /// `survey.shown()` once it's on screen, `answer(_:_:)` per question, then `complete()` or `dismiss(atIndex:)`.
    /// Returns a function that removes the renderer.
    @discardableResult
    public func onShow(_ render: @escaping SurveyRenderer) -> @Sendable () -> Void {
        let token = tokens.update { $0 += 1; return $0 }
        custom.set((token, render))
        rendererChanged()
        return { [weak self] in
            self?.custom.update { if $0?.token == token { $0 = nil } }
            self?.rendererChanged()
        }
    }

    /// Shows an active campaign now, ignoring targeting and caps (QA and previews).
    public func show(_ campaignId: String) {
        guard let client else { return }
        client.q.async { client.engine.show(campaignId) }
    }

    func renderer() -> SurveyRenderer? {
        if let custom = custom.get() { return custom.render }
        guard builtIn.get(), let client else { return nil }
        return BuiltInSurveySheet.renderer(for: client)
    }

    private func rendererChanged() {
        guard let client else { return }
        client.q.async { client.engine.check(.load) }
    }
}

// MARK: - Pure functions

struct CampaignState: Codable, Equatable {
    var shown: Int64?
    var answered: Int64?
    var dismissed: Int64?
}

struct SurveyState: Codable, Equatable {
    /// Last time any survey was shown (global cooldown).
    var last: Int64?
    var c: [String: CampaignState] = [:]

    init(last: Int64? = nil, c: [String: CampaignState] = [:]) { self.last = last; self.c = c }

    init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        last = try? k.decodeIfPresent(Int64.self, forKey: .last)
        c = (try? k.decodeIfPresent([String: CampaignState].self, forKey: .c)) ?? [:]
    }
}

struct EligibilityContext {
    var anonymousId: String?
    var userId: String?
    var platform: String
    var appVersion: String?
    var a11y: [String]
    var now: Int64
}

let dayMs: Int64 = 86_400_000
/// Never show two surveys within this window, whatever their own caps say.
let globalCooldownMs = dayMs
let maxSurveyText = 1000

/// Deterministic [0, 1) from a string (FNV-1a over UTF-16 code units), so sampling is stable per user.
func unitHash(_ s: String) -> Double {
    var h: UInt32 = 0x811c9dc5
    for unit in s.utf16 {
        h ^= UInt32(unit)
        h = h &* 0x01000193
    }
    return Double(h) / 4_294_967_296
}

/// Exact match, or prefix match when the pattern ends with `*`.
func matchPattern(_ pattern: String, _ value: String?) -> Bool {
    guard let value else { return false }
    return pattern.hasSuffix("*") ? value.hasPrefix(String(pattern.dropLast())) : value == pattern
}

/// Whether a campaign's targeting and caps allow showing it now.
func eligible(_ c: CampaignConfig, _ ctx: EligibilityContext, _ state: SurveyState) -> Bool {
    let t = c.targeting
    if t.identifiedOnly == true && ctx.userId == nil { return false }
    if let p = t.platforms, !p.isEmpty, !p.contains(ctx.platform) { return false }
    if let v = t.appVersions, !v.isEmpty, !v.contains(where: { matchPattern($0, ctx.appVersion) }) { return false }
    if let a = t.a11y, !a.isEmpty, !a.contains(where: ctx.a11y.contains) { return false }
    if unitHash("\(ctx.anonymousId ?? ctx.userId ?? ""):\(c.id)") >= t.sampleRate { return false }
    if let last = state.last, last != 0, ctx.now - last < globalCooldownMs { return false }
    guard let s = state.c[c.id], let shown = s.shown, shown != 0 else { return true }
    let days = Int64(t.frequency.days ?? (t.frequency.kind == .recurring ? 90 : 30)) * dayMs
    switch t.frequency.kind {
    case .once:
        return false
    case .untilAnswered:
        return (s.answered ?? 0) == 0 && ctx.now - max(shown, s.dismissed ?? 0) >= days
    case .recurring:
        return ctx.now - shown >= days
    }
}

/// Port of `followUpMatches` (`@metrickle/schema`): whether this response's answers meet the follow-up condition.
/// Choice conditions match any listed answer; score conditions are an inclusive band. No condition matches everyone.
func followUpMatches(_ when: FollowUpWhen?, _ answers: [String: Answer]) -> Bool {
    guard let when else { return true }
    guard let a = answers[when.questionId] else { return false }
    if let choices = when.choices, !choices.isEmpty { return a.values?.contains(where: choices.contains) ?? false }
    guard let score = a.score.map(Double.init) else { return false }
    return (when.min.map { score >= $0 } ?? true) && (when.max.map { score <= $0 } ?? true)
}

/// A study link is only opened when it's https (or http when the SDK itself talks to an http host, for local testing).
func safeInviteURL(_ raw: String?, host: String) -> URL? {
    guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased(), url.host != nil else { return nil }
    return scheme == "https" || (scheme == "http" && host.lowercased().hasPrefix("http:")) ? url : nil
}

// MARK: - Engine (runs on the client's queue)

final class SurveyEngine: @unchecked Sendable {
    enum TriggerEvent { case load, page(String?), event(String) }

    weak var client: Metrickle?
    private var campaigns: [CampaignConfig] = []
    private var state = SurveyState()
    private var active: String?
    private var pending = Set<String>()
    private var lastPath: String?

    func perform(_ fn: @escaping @Sendable (SurveyEngine) -> Void) {
        client?.q.async { fn(self) }
    }

    func load(from storage: MetrickleStorage) {
        if let raw = storage.get(Keys.surveys)?.data(using: .utf8),
           let s = try? JSONDecoder().decode(SurveyState.self, from: raw) {
            state = s
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        client?.storage?.set(Keys.surveys, String(decoding: data, as: UTF8.self))
    }

    func setCampaigns(_ campaigns: [CampaignConfig]) {
        self.campaigns = campaigns
        check(.load)
    }

    func show(_ id: String) {
        if let c = campaigns.first(where: { $0.id == id }) { present(c) }
    }

    func handle(_ e: Event) {
        if e.name.hasPrefix("$survey_") { return }
        if e.type == .page || e.type == .screen {
            lastPath = e.path
            check(.page(e.path))
            check(.load)
        } else {
            check(.event(e.name))
        }
    }

    func check(_ trigger: TriggerEvent) {
        // Surveys need memory for frequency caps, so cookieless and opted-out clients never see them.
        guard let client, client.storage != nil, !client.optedOut, active == nil, client.surveys.renderer() != nil else { return }
        for c in campaigns {
            let t = c.targeting.trigger
            guard !pending.contains(c.id) else { continue }
            switch (t.kind, trigger) {
            case (.load, .load): break
            case (.page, .page(let path)) where matchPattern(t.match ?? "", path): break
            case (.event, .event(let name)) where t.match == name: break
            default: continue
            }
            pending.insert(c.id)
            client.q.asyncAfter(deadline: .now() + .milliseconds(max(0, t.delayMs))) { [weak self] in
                guard let self else { return }
                self.pending.remove(c.id)
                if self.active != nil || !self.isEligible(c) { return }
                self.present(c)
            }
            return
        }
    }

    private func isEligible(_ c: CampaignConfig) -> Bool {
        guard let client else { return false }
        let ctx = EligibilityContext(
            anonymousId: client.anonymousId, userId: client.userId, platform: Metrickle.platform,
            appVersion: client.context.app?.version, a11y: client.context.a11y ?? [], now: client.clock()
        )
        return eligible(c, ctx, state)
    }

    private func present(_ c: CampaignConfig) {
        guard let render = client?.surveys.renderer() else { return }
        active = c.id
        let survey = ActiveSurvey(campaign: c, response: Metrickle.uuid(), path: lastPath, engine: self)
        DispatchQueue.main.async { render(survey) }
    }

    private func base(_ s: ActiveSurvey) -> Properties {
        ["campaign": .string(s.campaign.id), "version": .number(Double(s.campaign.version)), "response": .string(s.response)]
    }

    private func record(_ id: String, _ patch: (inout CampaignState) -> Void) {
        var cs = state.c[id] ?? CampaignState()
        patch(&cs)
        state.c[id] = cs
        save()
    }

    func shown(_ s: ActiveSurvey) {
        guard let client else { return }
        let now = client.clock()
        state.last = now
        record(s.campaign.id) { $0.shown = now }
        client.capture(.track, "$survey_shown", path: s.path, properties: base(s))
    }

    func answer(_ s: ActiveSurvey, _ q: Question, _ a: Answer) {
        guard let client else { return }
        s.answered += 1
        let last = q.id == s.campaign.questions.last?.id
        let text = a.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var props = base(s)
        props["question"] = .string(q.id)
        props["type"] = .string(q.type.rawValue)
        props["score"] = a.score.map { .number(Double($0)) } ?? .null
        props["value"] = a.values.flatMap { $0.isEmpty ? nil : PropertyValue.string(truncate($0.joined(separator: "|"), 1024)) } ?? .null
        props["text"] = text.isEmpty ? .null : .string(truncate(text, maxSurveyText))
        props["completed"] = last ? .bool(true) : .null
        client.capture(.track, "$survey_answered", path: s.path, properties: props)
        record(s.campaign.id) { $0.answered = client.clock() }
    }

    func complete(_ s: ActiveSurvey) {
        if active == s.campaign.id { active = nil }
    }

    func followUp(_ s: ActiveSurvey, accepted: Bool) {
        guard let client, let fu = s.followUp else { return }
        var props = base(s)
        props["study"] = .string(fu.studyId)
        props["accepted"] = .bool(accepted)
        client.capture(.track, "$survey_follow_up", path: s.path, properties: props)
    }

    func dismiss(_ s: ActiveSurvey, at index: Int) {
        guard let client else { return }
        if active == s.campaign.id { active = nil }
        record(s.campaign.id) { $0.dismissed = client.clock() }
        var props = base(s)
        props["at"] = .number(Double(index))
        props["answered"] = .number(Double(s.answered))
        client.capture(.track, "$survey_dismissed", path: s.path, properties: props)
    }
}
