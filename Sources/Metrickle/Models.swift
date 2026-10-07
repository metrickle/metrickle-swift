import Foundation

/// A property value: string (≤ 1024 chars), finite number, bool or null. Literals work: `["plan": "pro", "seats": 3]`.
public enum PropertyValue: Codable, Sendable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
}

extension PropertyValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
}

public typealias Properties = [String: PropertyValue]

public enum EventType: String, Codable, Sendable {
    case page, screen, track, identify
}

/// One event of the ingest protocol (`IngestEvent` in `@metrickle/schema`).
public struct Event: Codable, Sendable, Equatable {
    public var id: String
    public var type: EventType
    public var name: String
    /// Epoch milliseconds.
    public var ts: Int64
    public var anonymousId: String?
    public var userId: String?
    public var sessionId: String?
    public var url: String?
    public var path: String?
    public var title: String?
    public var referrer: String?
    public var properties: Properties?
    public var traits: Properties?
}

public struct EventContext: Codable, Sendable, Equatable {
    public struct Library: Codable, Sendable, Equatable { public var name: String; public var version: String }
    public struct App: Codable, Sendable, Equatable { public var version: String?; public var build: String? }
    public struct Device: Codable, Sendable, Equatable {
        public var type: String?
        public var model: String?
        public var os: String?
        public var osVersion: String?
    }
    public struct Screen: Codable, Sendable, Equatable { public var width: Int; public var height: Int }

    public var library: Library?
    public var platform: String
    public var app: App?
    public var device: Device?
    public var screen: Screen?
    public var locale: String?
    public var timezone: String?
    public var a11y: [String]?
}

struct IngestBatch: Codable, Sendable {
    var writeKey: String
    var sentAt: Int64
    var context: EventContext
    var events: [Event]
}

// MARK: - Research config (`GET /v1/config`)

public enum QuestionType: String, Codable, Sendable, CaseIterable {
    case nps, csat, ces, rating, choice, text

    /// Score range for scored types (`SCALES`).
    public var scale: ClosedRange<Int>? {
        switch self {
        case .nps: 0...10
        case .csat, .rating: 1...5
        case .ces: 1...7
        case .choice, .text: nil
        }
    }
}

public struct Question: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var type: QuestionType
    public var prompt: String
    public var required: Bool
    /// Choice questions: the options, in order.
    public var choices: [String]?
    /// Choice questions: allow several answers.
    public var multiple: Bool?
    /// Scale end labels, e.g. "Not likely" / "Very likely".
    public var lowLabel: String?
    public var highLabel: String?
    public var placeholder: String?

    public init(id: String, type: QuestionType, prompt: String, required: Bool = true, choices: [String]? = nil,
                multiple: Bool? = nil, lowLabel: String? = nil, highLabel: String? = nil, placeholder: String? = nil) {
        self.id = id; self.type = type; self.prompt = prompt; self.required = required; self.choices = choices
        self.multiple = multiple; self.lowLabel = lowLabel; self.highLabel = highLabel; self.placeholder = placeholder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(QuestionType.self, forKey: .type)
        prompt = try c.decode(String.self, forKey: .prompt)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
        choices = try c.decodeIfPresent([String].self, forKey: .choices)
        multiple = try c.decodeIfPresent(Bool.self, forKey: .multiple)
        lowLabel = try c.decodeIfPresent(String.self, forKey: .lowLabel)
        highLabel = try c.decodeIfPresent(String.self, forKey: .highLabel)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
    }
}

public struct Trigger: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case load, page, event }
    public var kind: Kind
    public var match: String?
    public var delayMs: Int

    public init(kind: Kind, match: String? = nil, delayMs: Int = 0) {
        self.kind = kind; self.match = match; self.delayMs = delayMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        match = try c.decodeIfPresent(String.self, forKey: .match)
        delayMs = try c.decodeIfPresent(Int.self, forKey: .delayMs) ?? 0
    }
}

public struct Frequency: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case once, untilAnswered = "until_answered", recurring }
    public var kind: Kind
    public var days: Int?

    public init(kind: Kind, days: Int? = nil) { self.kind = kind; self.days = days }
}

public struct Targeting: Codable, Sendable, Equatable {
    public var trigger: Trigger
    public var platforms: [String]?
    /// Exact versions or prefixes with a trailing `*`, e.g. "2.4*".
    public var appVersions: [String]?
    public var a11y: [String]?
    public var identifiedOnly: Bool?
    /// Share of eligible users who see it, 0–1. Deterministic per user.
    public var sampleRate: Double
    public var frequency: Frequency

    public init(trigger: Trigger = Trigger(kind: .load), platforms: [String]? = nil, appVersions: [String]? = nil,
                a11y: [String]? = nil, identifiedOnly: Bool? = nil, sampleRate: Double = 1,
                frequency: Frequency = Frequency(kind: .once)) {
        self.trigger = trigger; self.platforms = platforms; self.appVersions = appVersions; self.a11y = a11y
        self.identifiedOnly = identifiedOnly; self.sampleRate = sampleRate; self.frequency = frequency
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trigger = try c.decode(Trigger.self, forKey: .trigger)
        platforms = try c.decodeIfPresent([String].self, forKey: .platforms)
        appVersions = try c.decodeIfPresent([String].self, forKey: .appVersions)
        a11y = try c.decodeIfPresent([String].self, forKey: .a11y)
        identifiedOnly = try c.decodeIfPresent(Bool.self, forKey: .identifiedOnly)
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 1
        frequency = try c.decodeIfPresent(Frequency.self, forKey: .frequency) ?? Frequency(kind: .once)
    }
}

/// Which answers qualify for a follow-up (`FollowUpWhen`).
public struct FollowUpWhen: Codable, Sendable, Equatable {
    public var questionId: String
    /// Scores: an inclusive band, e.g. NPS detractors are 0–6.
    public var min: Double?
    public var max: Double?
    /// Choice questions: any of these answers.
    public var choices: [String]?

    public init(questionId: String, min: Double? = nil, max: Double? = nil, choices: [String]? = nil) {
        self.questionId = questionId; self.min = min; self.max = max; self.choices = choices
    }
}

/// After the last answer, invite the respondent into a study (`FollowUpConfig`). Only sent while the study is recruiting.
public struct FollowUpConfig: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// A booked video call.
        case moderated
        /// A self-guided test on the web.
        case unmoderated
    }

    public var studyId: String
    public var kind: Kind
    public var prompt: String
    /// Who qualifies; nil means everyone who finishes the survey.
    public var when: FollowUpWhen?
    public var incentive: String?
    /// Moderated: session length in minutes.
    public var durationMin: Int?

    public init(studyId: String, kind: Kind, prompt: String, when: FollowUpWhen? = nil, incentive: String? = nil,
                durationMin: Int? = nil) {
        self.studyId = studyId; self.kind = kind; self.prompt = prompt; self.when = when
        self.incentive = incentive; self.durationMin = durationMin
    }
}

/// What the SDK receives for a campaign: only what's needed to decide and render.
public struct CampaignConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var questions: [Question]
    public var targeting: Targeting
    public var thankYou: String?
    /// An invite into a study after the last answer, while the study is recruiting.
    public var followUp: FollowUpConfig?
    /// Bumps when the campaign is edited.
    public var version: Int

    public init(id: String, questions: [Question], targeting: Targeting, thankYou: String? = nil,
                followUp: FollowUpConfig? = nil, version: Int = 1) {
        self.id = id; self.questions = questions; self.targeting = targeting; self.thankYou = thankYou
        self.followUp = followUp; self.version = version
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        questions = try c.decode([Question].self, forKey: .questions)
        targeting = try c.decode(Targeting.self, forKey: .targeting)
        thankYou = try c.decodeIfPresent(String.self, forKey: .thankYou)
        // A follow-up this SDK can't read (e.g. a newer study kind) is dropped; the survey itself still runs.
        followUp = (try? c.decodeIfPresent(FollowUpConfig.self, forKey: .followUp)) ?? nil
        version = try c.decode(Int.self, forKey: .version)
    }
}

public struct Branding: Codable, Sendable, Equatable {
    public var poweredBy: Bool?
    /// Brand colour as #rrggbb, or nil for the default.
    public var accent: String?
}

public struct FeedbackSettings: Codable, Sendable, Equatable {
    /// Platforms the app takes feedback from; nil (configs from before the setting) means all of them.
    public var platforms: [String]?
    public var enabled: Bool?
    public var label: String?
    public var screenshots: Bool?
    public var branding: Branding?
}

/// `GET /v1/config` response. Campaigns that fail to decode (e.g. a newer question type) are skipped.
public struct SdkConfig: Decodable, Sendable, Equatable {
    public var v: Int
    public var campaigns: [CampaignConfig]
    public var feedback: FeedbackSettings?

    public init(v: Int = 1, campaigns: [CampaignConfig], feedback: FeedbackSettings? = nil) {
        self.v = v; self.campaigns = campaigns; self.feedback = feedback
    }

    private enum CodingKeys: String, CodingKey { case v, campaigns, feedback }
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        campaigns = ((try? c.decode([Lossy<CampaignConfig>].self, forKey: .campaigns)) ?? []).compactMap(\.value)
        feedback = try? c.decodeIfPresent(FeedbackSettings.self, forKey: .feedback)
    }
}

// MARK: - Feedback

public enum FeedbackCategory: String, Codable, Sendable, CaseIterable {
    case bug, confusing, idea, accessibility, other
}

struct FeedbackSubmission: Codable, Sendable {
    struct Device: Codable, Sendable { var type: String?; var os: String?; var model: String? }
    var writeKey: String
    var anonymousId: String?
    var userId: String?
    var sessionId: String?
    var category: FeedbackCategory
    var message: String
    var rating: Int?
    var url: String?
    var path: String?
    var platform: String
    var appVersion: String?
    var device: Device?
    var screen: EventContext.Screen?
    var locale: String?
    var a11y: [String]?
    var screenshot: String?
}
