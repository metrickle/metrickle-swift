import Foundation

/// The Metrickle client. Configure once at launch, then use `Metrickle.shared` (or keep the returned instance).
/// Every method is safe to call from any thread; work happens on a private serial queue and never blocks the caller on I/O.
public final class Metrickle: @unchecked Sendable {
    public static let sdkVersion = "0.2.0"
    static let libraryName = "metrickle-ios"
    static let platform = "ios"

    public struct Options: Sendable {
        /// Ingest origin. Defaults to https://in.metrickle.com.
        public var host: String
        /// No ids are persisted; the server derives a daily-rotating visitor hash. Surveys stay off.
        public var cookieless: Bool
        /// Seconds between automatic flushes.
        public var flushInterval: TimeInterval
        /// Seconds of inactivity after which a new session starts.
        public var sessionTimeout: TimeInterval
        /// Sends `$screen` from `UIViewController.viewDidAppear`. Use `.metrickleScreen(_:)` in SwiftUI.
        public var automaticScreenTracking: Bool
        /// Sends `$rage_click` for 3 taps within 1s in a 30pt radius.
        public var rageTaps: Bool
        /// Logs every queued event and each send result.
        public var debug: Bool
        /// Called before each event is queued; return nil to drop it (e.g. PII scrubbing). Runs on the SDK queue.
        public var beforeSend: (@Sendable (Event) -> Event?)?
        /// Overrides `CFBundleShortVersionString`.
        public var appVersion: String?
        /// Overrides `CFBundleVersion`.
        public var appBuild: String?

        public init(host: String = "https://in.metrickle.com", cookieless: Bool = false, flushInterval: TimeInterval = 5,
                    sessionTimeout: TimeInterval = 30 * 60, automaticScreenTracking: Bool = true, rageTaps: Bool = true,
                    debug: Bool = false, beforeSend: (@Sendable (Event) -> Event?)? = nil, appVersion: String? = nil,
                    appBuild: String? = nil) {
            self.host = host; self.cookieless = cookieless; self.flushInterval = flushInterval
            self.sessionTimeout = sessionTimeout; self.automaticScreenTracking = automaticScreenTracking
            self.rageTaps = rageTaps; self.debug = debug; self.beforeSend = beforeSend
            self.appVersion = appVersion; self.appBuild = appBuild
        }
    }

    public struct Identity: Sendable, Equatable {
        public var anonymousId: String?
        public var userId: String?
        public var sessionId: String?
    }

    private static let sharedClient = Locked<Metrickle?>(nil)

    /// The client created by `configure`, or nil before that.
    public static var shared: Metrickle? { sharedClient.get() }

    /// Creates the shared client and starts automatic tracking. Call once, early (e.g. in `application(_:didFinishLaunchingWithOptions:)`
    /// or your `App` initialiser). Later calls return the existing client.
    @discardableResult
    public static func configure(writeKey: String, options: Options = Options()) -> Metrickle {
        let (client, created) = sharedClient.update { current -> (Metrickle, Bool) in
            if let current { return (current, false) }
            let client = Metrickle(
                writeKey: writeKey, options: options,
                storage: options.cookieless ? nil : UserDefaultsStorage(),
                transport: URLSessionTransport(),
                context: PlatformInfo.baseContext(options)
            )
            current = client
            return (client, true)
        }
        if created { client.startPlatform() } else { client.log("configure called twice; keeping the first client") }
        return client
    }

    // MARK: Configuration (immutable)

    public let writeKey: String
    public let options: Options
    /// Ingest origin, without a trailing slash.
    public let host: String
    let storage: MetrickleStorage?
    let transport: HTTPTransport
    let clock: @Sendable () -> Int64

    public let surveys: Surveys
    public let feedback: Feedback
    let engine = SurveyEngine()
    /// Latest `SdkConfig.feedback.branding.accent`, read by the built-in sheet on the main thread.
    let accent = Locked<String?>(nil)
    /// Whether feedback is switched on for iOS in the dashboard. True until the config says otherwise.
    let feedbackEnabled = Locked(true)

    static let maxQueue = 1000
    static let maxBatchSize = 20
    static let maxRequestEvents = 100
    static let maxAgeMs: Int64 = 7 * 86_400_000
    static let passive: Set<String> = ["$web_vital", "$app_background"]

    let q = DispatchQueue(label: "com.metrickle.client", qos: .utility)
    private static let queueKey = DispatchSpecificKey<Bool>()

    // MARK: State (only touched on `q`)

    var queue: [Event] = []
    private var inflight: [UUID: [Event]] = [:]
    private(set) var anonymousId: String?
    private(set) var userId: String?
    private var session: SessionState?
    private(set) var optedOut = false
    private var consents = Set<String>()
    private var superProps: Properties = [:]
    private(set) var context: EventContext
    private(set) var currentScreen: String?
    private var uTurn = UTurnDetector()
    private var recentFormErrors: [String: Int64] = [:]
    private var flushing = false
    private var retryDelayMs: Int64 = 0
    private var retryAt: Int64 = 0
    private var saveScheduled = false
    private var lastConfigFetch: Int64 = 0
    private var timer: DispatchSourceTimer?

    struct SessionState: Codable, Equatable {
        var id: String
        var last: Int64
    }

    init(writeKey: String, options: Options, storage: MetrickleStorage?, transport: HTTPTransport, context: EventContext,
         clock: @escaping @Sendable () -> Int64 = Metrickle.epochMs, fetchConfig: Bool = true) {
        self.writeKey = writeKey
        self.options = options
        let host = options.host.hasSuffix("/") ? String(options.host.dropLast()) : options.host
        self.host = URL(string: "\(host)/v1/batch")?.scheme != nil ? host : "https://in.metrickle.com"
        self.storage = storage
        self.transport = transport
        self.clock = clock
        self.context = context
        surveys = Surveys()
        feedback = Feedback()
        q.setSpecific(key: Self.queueKey, value: true)
        engine.client = self
        surveys.client = self
        feedback.client = self
        q.async {
            self.restore()
            if fetchConfig { self.fetchConfigLocked() }
        }
        startTimer()
    }

    deinit { timer?.cancel() }

    // MARK: Public API

    /// Records a screen view. `path` and `title` are the name; `referrer` is the previous screen.
    public func screen(_ name: String, properties: Properties? = nil) {
        let now = clock()
        q.async { self.screenLocked(name, properties: properties, at: now) }
    }

    /// Records a custom event. Names starting with `$` are reserved and dropped.
    public func track(_ name: String, properties: Properties? = nil) {
        guard !name.hasPrefix("$") else {
            print("[metrickle] event names starting with $ are reserved; dropped \(name)")
            return
        }
        let now = clock()
        q.async { self.capture(.track, name, properties: properties, at: now) }
    }

    /// Persists the user id and sends `$identify` with `traits`.
    public func identify(_ userId: String, traits: Properties? = nil) {
        let now = clock()
        q.async {
            self.userId = userId
            self.storage?.set(Keys.user, userId)
            self.capture(.identify, "$identify", traits: traits, at: now)
        }
    }

    /// Call on logout: forgets the user and session and starts a new anonymous identity (none while opted out).
    public func reset() {
        q.async {
            self.userId = nil
            self.session = nil
            self.anonymousId = self.storage != nil && !self.optedOut ? Self.uuid() : nil
            if let s = self.storage {
                s.remove(Keys.user)
                s.remove(Keys.session)
                if let id = self.anonymousId { s.set(Keys.anon, id) } else { s.remove(Keys.anon) }
            }
        }
    }

    /// Properties merged into every subsequent event (under the event's own properties).
    public func register(_ properties: Properties) {
        q.async { self.superProps.merge(properties) { $1 } }
    }

    /// Stops all collection and network calls, clears the queue, removes the anonymous id and session from the device,
    /// and remembers the choice. Your own user id (from `identify`) and consent are kept.
    public func optOut() {
        q.async {
            self.optedOut = true
            self.queue = []
            self.anonymousId = nil
            self.session = nil
            if let s = self.storage {
                s.set(Keys.optOut, "1")
                s.remove(Keys.queue)
                s.remove(Keys.anon)
                s.remove(Keys.session)
            }
        }
    }

    /// Resumes collection with a new anonymous id and fetches surveys and settings again.
    public func optIn() {
        q.async {
            self.optedOut = false
            if let s = self.storage {
                s.remove(Keys.optOut)
                if self.anonymousId == nil {
                    let id = Self.uuid()
                    self.anonymousId = id
                    s.set(Keys.anon, id)
                }
            }
            self.fetchConfigLocked()
        }
    }

    public var isOptedOut: Bool { onQueue { optedOut } }

    /// Records the user's consent for research features that need it (session replay; kept for parity with the web SDK).
    public func consent(replay: Bool) {
        q.async {
            if replay { self.consents.insert("replay") } else { self.consents.remove("replay") }
            self.storage?.set(Keys.consent, self.consents.sorted().joined(separator: ","))
        }
    }

    public var hasReplayConsent: Bool { onQueue { consents.contains("replay") } }

    /// Current ids. Reading them does not extend the session.
    public var identity: Identity { onQueue { Identity(anonymousId: anonymousId, userId: userId, sessionId: session?.id) } }

    /// Sends queued events now. `completion` gets whether everything sent was accepted.
    public func flush(completion: (@Sendable (Bool) -> Void)? = nil) {
        q.async { self.flushLocked(force: false, completion: completion) }
    }

    /// Reports a validation error. Duplicates of the same form, field and reason within 1.5s are collapsed.
    /// Pass field identifiers, never what the user typed.
    public func formError(form: String?, field: String, reason: String) {
        let now = clock()
        q.async {
            let key = "\(form ?? "")|\(field)|\(reason)"
            if let last = self.recentFormErrors[key], now - last < 1_500 { return }
            self.recentFormErrors = self.recentFormErrors.filter { now - $0.value < 1_500 }
            self.recentFormErrors[key] = now
            self.capture(.track, "$form_error", properties: [
                "form": form.map { .string($0) } ?? .null, "field": .string(field), "reason": .string(reason),
            ], at: now)
        }
    }

    /// Re-fetches campaigns and settings (done automatically at launch and on foreground after 5 minutes).
    public func refreshConfig() {
        q.async { self.fetchConfigLocked() }
    }

    // MARK: Internal API for platform hooks

    func captureAsync(_ type: EventType, _ name: String, properties: Properties? = nil) {
        let now = clock()
        q.async { self.capture(type, name, properties: properties, at: now) }
    }

    /// Accessibility flags changed; later batches (and queued events) carry the new context.
    func setA11y(_ flags: [String]) {
        q.async { self.context.a11y = flags.isEmpty ? nil : flags }
    }

    func updateContext(_ patch: @escaping @Sendable (inout EventContext) -> Void) {
        q.async { patch(&self.context) }
    }

    func appDidEnterForeground() {
        let now = clock()
        q.async {
            self.capture(.track, "$app_open", at: now)
            if now - self.lastConfigFetch > 5 * 60_000 { self.fetchConfigLocked() }
        }
    }

    /// Captures `$app_background` and sends everything, bypassing backoff. `completion` runs when all requests finish.
    func appDidEnterBackground(completion: @escaping @Sendable () -> Void) {
        let now = clock()
        q.async {
            self.capture(.track, "$app_background", at: now)
            self.saveQueue()
            self.flushLocked(force: true) { _ in completion() }
        }
    }

    /// Waits until everything queued so far on the SDK queue has run (tests).
    func sync() { q.sync {} }

    func stopTimer() { q.sync { timer?.cancel(); timer = nil } }

    // MARK: Queue-confined implementation

    func onQueue<T>(_ fn: () -> T) -> T {
        DispatchQueue.getSpecific(key: Self.queueKey) == true ? fn() : q.sync(execute: fn)
    }

    func log(_ items: Any...) {
        guard options.debug else { return }
        print("[metrickle]", items.map { "\($0)" }.joined(separator: " "))
    }

    private func restore() {
        guard let s = storage else { return }
        optedOut = s.get(Keys.optOut) == "1"
        consents = Set((s.get(Keys.consent) ?? "").split(separator: ",").map(String.init).filter { $0 == "replay" })
        if optedOut {
            // An opted-out user gets no id on the device; optIn() creates one.
            anonymousId = nil
        } else if let id = s.get(Keys.anon), !id.isEmpty {
            anonymousId = id
        } else {
            let id = Self.uuid()
            anonymousId = id
            s.set(Keys.anon, id)
        }
        userId = s.get(Keys.user)
        if let raw = s.get(Keys.session)?.data(using: .utf8) {
            session = try? JSONDecoder().decode(SessionState.self, from: raw)
        }
        if !optedOut, let raw = s.get(Keys.queue)?.data(using: .utf8),
           let saved = try? JSONDecoder().decode([Event].self, from: raw) {
            let cutoff = clock() - Self.maxAgeMs
            queue = Array(saved.filter { $0.ts >= cutoff }.suffix(Self.maxQueue)) + queue
        }
        engine.load(from: s)
    }

    /// Session id with inactivity timeout. Nil in cookieless mode (the server derives one).
    private func touchSession(_ now: Int64, passive: Bool) -> String? {
        guard let storage else { return nil }
        if passive, let session { return session.id }
        let timeout = Int64(options.sessionTimeout * 1000)
        if let s = session, now - s.last <= timeout {
            session?.last = now
        } else {
            session = SessionState(id: Self.uuid(), last: now)
        }
        if let data = try? JSONEncoder().encode(session), let json = String(data: data, encoding: .utf8) {
            storage.set(Keys.session, json)
        }
        return session?.id
    }

    func screenLocked(_ name: String, properties: Properties?, at now: Int64) {
        if let turn = uTurn.visit(name, at: now) {
            capture(.track, "$u_turn", path: turn.from,
                    properties: ["back_to": .string(turn.to), "dwell_ms": .number(Double(turn.dwellMs))], at: now)
        }
        capture(.screen, "$screen", path: name, title: name, referrer: currentScreen, properties: properties, at: now)
        currentScreen = name
    }

    func capture(_ type: EventType, _ name: String, path: String? = nil, title: String? = nil, referrer: String? = nil,
                 properties: Properties? = nil, traits: Properties? = nil, at ts: Int64? = nil) {
        guard !optedOut else { return }
        let now = ts ?? clock()
        var event: Event? = Event(
            id: Self.uuid(), type: type, name: name, ts: now,
            anonymousId: anonymousId, userId: userId,
            sessionId: touchSession(now, passive: Self.passive.contains(name)),
            url: nil, path: path ?? currentScreen, title: title, referrer: referrer,
            properties: Self.sanitize(superProps.merging(properties ?? [:]) { $1 }),
            traits: traits.flatMap(Self.sanitize)
        )
        if let beforeSend = options.beforeSend, let e = event { event = beforeSend(e) }
        guard let event else { return }
        if queue.count >= Self.maxQueue { queue.removeFirst() }
        queue.append(event)
        if options.debug, let json = try? JSONEncoder().encode(event) { log("queued", String(decoding: json, as: UTF8.self)) }
        engine.handle(event)
        scheduleSave()
        if queue.count >= Self.maxBatchSize { flushLocked(force: false, completion: nil) }
    }

    /// Property values are string (≤ 1024), finite number, bool or null; at most 64 keys of ≤ 128 chars. Empty becomes nil.
    static func sanitize(_ props: Properties) -> Properties? {
        var out = Properties()
        for key in props.keys.sorted() where key.utf16.count <= 128 {
            guard out.count < 64 else { break }
            switch props[key]! {
            case .string(let s): out[key] = .string(truncate(s, 1024))
            case .number(let n): out[key] = n.isFinite ? .number(n) : .null
            case let v: out[key] = v
            }
        }
        return out.isEmpty ? nil : out
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: q)
        let interval = max(options.flushInterval, 1)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.flushLocked(force: false, completion: nil) }
        t.resume()
        timer = t
    }

    /// Debounced write of the queue (plus requests in flight) so it survives the app being killed.
    private func scheduleSave() {
        guard storage != nil, !saveScheduled else { return }
        saveScheduled = true
        q.asyncAfter(deadline: .now() + 1) { [weak self] in self?.saveQueue() }
    }

    func saveQueue() {
        saveScheduled = false
        guard let storage else { return }
        let pending = inflight.values.flatMap { $0 }.sorted { $0.ts < $1.ts } + queue
        if pending.isEmpty || optedOut {
            storage.remove(Keys.queue)
        } else if let data = try? JSONEncoder().encode(Array(pending.suffix(Self.maxQueue))) {
            storage.set(Keys.queue, String(decoding: data, as: UTF8.self))
        }
    }

    func batch(_ events: [Event], sentAt: Int64) -> IngestBatch {
        IngestBatch(writeKey: writeKey, sentAt: sentAt, context: context, events: events)
    }

    /// Regular flushes send one request at a time and respect backoff; `force` (backgrounding) sends everything now.
    func flushLocked(force: Bool, completion: (@Sendable (Bool) -> Void)?) {
        let now = clock()
        queue.removeAll { now - $0.ts > Self.maxAgeMs }
        guard !optedOut, !queue.isEmpty else { completion?(true); return }
        if !force && (flushing || now < retryAt) { completion?(false); return }

        var chunks: [[Event]] = []
        repeat {
            let n = min(Self.maxRequestEvents, queue.count)
            chunks.append(Array(queue.prefix(n)))
            queue.removeFirst(n)
        } while force && !queue.isEmpty
        if !force { flushing = true }

        let token = UUID()
        let sent = chunks
        let total = chunks.reduce(0) { $0 + $1.count }
        inflight[token] = chunks.flatMap { $0 }
        let encoder = JSONEncoder()
        let bodies = chunks.map { try? encoder.encode(batch($0, sentAt: now)) }
        let request = batchRequest()

        Task { [transport] in
            var failed: [Event] = []
            for (i, body) in bodies.enumerated() {
                var ok = false
                if let body {
                    var req = request
                    req.httpBody = body
                    do { ok = HTTP.isDone(try await transport.send(req).status) } catch { ok = false }
                } else {
                    ok = true // unencodable: never going to succeed
                }
                if !ok { failed = sent[i...].flatMap { $0 }; break }
            }
            let unsent = failed
            self.q.async {
                self.inflight[token] = nil
                if !force { self.flushing = false }
                let ok = unsent.isEmpty
                if ok {
                    self.retryDelayMs = 0
                    self.retryAt = 0
                } else {
                    if !self.optedOut {
                        self.queue.insert(contentsOf: unsent, at: 0)
                        if self.queue.count > Self.maxQueue { self.queue.removeFirst(self.queue.count - Self.maxQueue) }
                    }
                    self.retryDelayMs = self.retryDelayMs == 0 ? 1_000 : min(60_000, self.retryDelayMs * 2)
                    self.retryAt = self.clock() + self.retryDelayMs
                }
                self.log(ok ? "sent" : "send failed, retrying in \(self.retryDelayMs)ms", total, "events")
                self.saveQueue()
                completion?(ok)
            }
        }
    }

    private func batchRequest() -> URLRequest {
        var req = URLRequest(url: URL(string: "\(host)/v1/batch") ?? URL(string: "https://in.metrickle.com/v1/batch")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(writeKey, forHTTPHeaderField: "x-metrickle-key")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    /// `metrickle-ios/0.2.0 (iOS 17.2; iPhone15,2)`.
    var userAgent: String {
        let d = context.device
        return "\(Self.libraryName)/\(Self.sdkVersion) (\(d?.os ?? "iOS") \(d?.osVersion ?? ""); \(d?.model ?? "unknown"))"
    }

    func fetchConfigLocked() {
        guard !optedOut else { return }
        lastConfigFetch = clock()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let key = writeKey.addingPercentEncoding(withAllowedCharacters: allowed) ?? writeKey
        guard let url = URL(string: "\(host)/v1/config?key=\(key)") else { return }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        Task { [transport] in
            guard let (status, data) = try? await transport.send(req), (200..<300).contains(status),
                  let cfg = try? JSONDecoder().decode(SdkConfig.self, from: data), cfg.v == 1 else {
                self.log("config unavailable")
                return
            }
            self.q.async { self.apply(cfg) }
        }
    }

    /// `POST /v1/studies/invite`: the respondent's personal study link, or nil for anything but a safe URL in a 201.
    func requestInvite(studyId: String, campaignId: String, response: String) async -> URL? {
        struct Body: Encodable {
            var writeKey, studyId, campaignId, response: String
            var anonymousId, userId: String?
        }
        struct Reply: Decodable { var url: String? }
        let request: URLRequest? = await withCheckedContinuation { cont in
            q.async {
                guard !self.optedOut, let url = URL(string: "\(self.host)/v1/studies/invite"),
                      let body = try? JSONEncoder().encode(Body(
                        writeKey: self.writeKey, studyId: studyId, campaignId: campaignId, response: response,
                        anonymousId: self.anonymousId, userId: self.userId)) else { return cont.resume(returning: nil) }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.setValue(self.writeKey, forHTTPHeaderField: "x-metrickle-key")
                req.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
                req.httpBody = body
                cont.resume(returning: req)
            }
        }
        guard let request, let (status, data) = try? await transport.send(request), status == 201,
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            log("study invite unavailable")
            return nil
        }
        return safeInviteURL(reply.url, host: host)
    }

    func apply(_ config: SdkConfig) {
        accent.set(config.feedback?.branding?.accent)
        feedbackEnabled.set(config.feedback?.platforms.map { $0.contains(Metrickle.platform) } ?? true)
        engine.setCampaigns(config.campaigns)
    }

    // MARK: Helpers

    static func epochMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
    static func uuid() -> String { UUID().uuidString.lowercased() }
}

/// Truncates to at most `max` UTF-16 code units (the unit JS and the server count in) without splitting a character.
func truncate(_ s: String, _ max: Int) -> String {
    guard s.utf16.count > max else { return s }
    var count = 0
    var end = s.startIndex
    for i in s.indices {
        let n = s[i].utf16.count
        if count + n > max { break }
        count += n
        end = s.index(after: i)
    }
    return String(s[..<end])
}
