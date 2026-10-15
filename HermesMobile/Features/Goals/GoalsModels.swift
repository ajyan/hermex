import Foundation

// Models for the Goals API on this user's `hermes-webui` fork (`api/vault_goals.py`, over the
// vault's `tools/goals.py`): `GET /api/goals`, `GET /api/goals/detail?slug=` and
// `POST /api/goals/checkin`. Every field decodes tolerantly, and keys are literal snake_case,
// so decode with `PrepDecoding`.

/// Decodes an element or yields nil, so one bad element never fails its array.
private struct GoalsLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    func string(_ key: Key) -> String {
        (try? decodeIfPresent(String.self, forKey: key)) ?? ""
    }

    func int(_ key: Key) -> Int {
        (try? decodeIfPresent(Int.self, forKey: key)) ?? 0
    }

    func bool(_ key: Key) -> Bool {
        (try? decodeIfPresent(Bool.self, forKey: key)) ?? false
    }

    func optional<Value: Decodable>(_ type: Value.Type, _ key: Key) -> Value? {
        try? decodeIfPresent(Value.self, forKey: key)
    }

    func lossy<Value: Decodable>(_ type: Value.Type, _ key: Key) -> [Value] {
        ((try? decodeIfPresent([GoalsLossy<Value>].self, forKey: key)) ?? []).compactMap(\.value)
    }
}

/// One day's check-in for a commitment. `none` appears only in the heatmap; `clear` is only
/// sent, to undo the day's check-in.
enum GoalStatus: String, Hashable, Sendable, Decodable {
    case done, min, skip, miss, none, clear, unknown

    init(from decoder: Decoder) throws {
        self = GoalStatus(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .unknown
    }

    /// Whether this status counts as showing up.
    var isShown: Bool { self == .done || self == .min }
}

struct GoalStreak: Decodable, Hashable, Sendable {
    var days: Int
    var atRisk: Bool

    private enum CodingKeys: String, CodingKey { case days, atRisk = "at_risk" }

    init(days: Int = 0, atRisk: Bool = false) {
        self.days = days
        self.atRisk = atRisk
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = c.int(.days)
        atRisk = c.bool(.atRisk)
    }
}

struct GoalMilestone: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let due: String?
    let done: String?

    private enum CodingKeys: String, CodingKey { case id, title, due, done }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        title = c.string(.title)
        due = c.optional(String.self, .due)
        done = c.optional(String.self, .done)
    }
}

/// One counted item on an item commitment, such as one outreach message.
struct GoalItem: Decodable, Hashable, Sendable {
    let date: String
    let note: String?

    private enum CodingKeys: String, CodingKey { case date, note }

    init(date: String, note: String?) {
        self.date = date
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.string(.date)
        note = c.optional(String.self, .note)
    }
}

struct GoalCommitmentProgress: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let action: String
    let target: Int
    let skips: Int
    let cue: String
    let minimum: String
    let days: [String]?
    var done: Int
    var min: Int
    var skipped: Int
    var missed: Int
    var hit: Bool
    var remaining: Int
    let dueToday: Bool
    let dueYesterday: Bool
    var today: GoalStatus?
    var yesterday: GoalStatus?
    /// `"day"` (checked per day) or `"item"` (counted by +1 check-ins); anything else reads as day.
    let unit: String
    /// What counts days automatically, such as `"prep.days"`; nil for hand-checked rows.
    let source: String?
    /// Days the source counted as done; an explicit check-in on one overrides it.
    var sourceDays: [String]
    /// The counted items of an item row, oldest first.
    var items: [GoalItem]

    var isItem: Bool { unit == "item" }

    private enum CodingKeys: String, CodingKey {
        case id, action, target, skips, cue, minimum, days, done, min, skipped, missed, hit, remaining, today, yesterday
        case unit, source, items
        case dueToday = "due_today", dueYesterday = "due_yesterday", sourceDays = "source_days"
    }

    /// The status that counts for `date`: the explicit one the row shows for today or yesterday,
    /// else done when the source counted the day.
    func effectiveStatus(_ date: String, today todayDate: String, yesterday yesterdayDate: String) -> GoalStatus? {
        let explicit: GoalStatus? = date == todayDate ? today : date == yesterdayDate ? yesterday : nil
        if let explicit { return explicit }
        return sourceDays.contains(date) ? .done : nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        action = c.string(.action)
        target = c.int(.target)
        skips = c.int(.skips)
        cue = c.string(.cue)
        minimum = c.string(.minimum)
        days = c.optional([String].self, .days)
        done = c.int(.done)
        min = c.int(.min)
        skipped = c.int(.skipped)
        missed = c.int(.missed)
        hit = c.bool(.hit)
        remaining = c.int(.remaining)
        dueToday = c.bool(.dueToday)
        dueYesterday = c.bool(.dueYesterday)
        today = c.optional(GoalStatus.self, .today)
        yesterday = c.optional(GoalStatus.self, .yesterday)
        let unit = c.string(.unit)
        self.unit = unit.isEmpty ? "day" : unit
        source = c.optional(String.self, .source)
        sourceDays = c.optional([String].self, .sourceDays) ?? []
        items = c.lossy(GoalItem.self, .items)
    }
}

struct GoalWeek: Decodable, Hashable, Sendable {
    var start: String = ""
    var end: String = ""
    var commitments: [GoalCommitmentProgress] = []
    /// Monday to Sunday: each day's best check-in across commitments.
    var days: [GoalHeatDay] = []

    private enum CodingKeys: String, CodingKey { case start, end, commitments, days }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = c.string(.start)
        end = c.string(.end)
        commitments = c.lossy(GoalCommitmentProgress.self, .commitments)
        days = c.lossy(GoalHeatDay.self, .days)
    }
}

struct GoalDailyCheck: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let question: String
    let options: [String]
    var today: String?
    var yesterday: String?

    private enum CodingKeys: String, CodingKey { case id, question, options, today, yesterday }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        question = c.string(.question)
        options = c.optional([String].self, .options) ?? []
        today = c.optional(String.self, .today)
        yesterday = c.optional(String.self, .yesterday)
    }
}

struct GoalEscalation: Decodable, Hashable, Sendable {
    let check: String
    let say: String

    private enum CodingKeys: String, CodingKey { case check, say }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        check = c.string(.check)
        say = c.string(.say)
    }
}

struct GoalUnlock: Decodable, Hashable, Sendable {
    let after: String
    let id: String
    let action: String

    private enum CodingKeys: String, CodingKey { case after, id, action }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        after = c.string(.after)
        id = c.string(.id)
        action = c.string(.action)
    }
}

struct GoalFlags: Decodable, Hashable, Sendable {
    var missTwice: [String] = []
    var escalations: [GoalEscalation] = []
    var unlockReady: [GoalUnlock] = []

    private enum CodingKeys: String, CodingKey {
        case missTwice = "miss_twice", escalations, unlockReady = "unlock_ready"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        missTwice = c.optional([String].self, .missTwice) ?? []
        escalations = c.lossy(GoalEscalation.self, .escalations)
        unlockReady = c.lossy(GoalUnlock.self, .unlockReady)
    }
}

/// A personal goal as the Goals home and a check-in response show it.
struct GoalSummary: Decodable, Hashable, Sendable, Identifiable {
    let slug: String
    let title: String
    let status: String
    let deadline: String?
    let daysLeft: Int?
    let identity: String
    /// A Daily Brief paper name ("wiki", "quote", …); empty lets `GoalPaper` pick one.
    let color: String
    /// An SF Symbol name; empty shows a flag.
    let icon: String
    let nextMilestone: GoalMilestone?
    var week: GoalWeek
    var dailyChecks: [GoalDailyCheck]
    var flags: GoalFlags
    /// The date of the weekly deck (`briefs/<date>.weekly.json`) holding this week's plan while it
    /// waits to be confirmed or changed; nil when none.
    var weekPending: String?
    var confirmedStarts: [String]
    /// Why a source such as Prep could not be read, shown instead of a silent zero.
    var sourceErrors: [String]

    var id: String { slug }

    private enum CodingKeys: String, CodingKey {
        case slug, title, status, deadline, identity, week, flags, color, icon
        case weekPending = "week_pending", confirmedStarts = "confirmed_starts", sourceErrors = "source_errors"
        case daysLeft = "days_left", nextMilestone = "next_milestone", dailyChecks = "daily_checks"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = c.string(.slug)
        title = c.string(.title)
        status = c.string(.status)
        deadline = c.optional(String.self, .deadline)
        daysLeft = c.optional(Int.self, .daysLeft)
        identity = c.string(.identity)
        color = c.string(.color)
        icon = c.string(.icon)
        nextMilestone = c.optional(GoalMilestone.self, .nextMilestone)
        week = c.optional(GoalWeek.self, .week) ?? GoalWeek()
        dailyChecks = c.lossy(GoalDailyCheck.self, .dailyChecks)
        flags = c.optional(GoalFlags.self, .flags) ?? GoalFlags()
        weekPending = c.optional(String.self, .weekPending)
        confirmedStarts = c.optional([String].self, .confirmedStarts) ?? []
        sourceErrors = c.optional([String].self, .sourceErrors) ?? []
    }
}

struct AgentGoalSummary: Decodable, Hashable, Sendable, Identifiable {
    let slug: String
    let title: String
    let status: String
    let nextCheck: String?

    var id: String { slug }

    private enum CodingKeys: String, CodingKey { case slug, title, status, nextCheck = "next_check" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = c.string(.slug)
        title = c.string(.title)
        status = c.string(.status)
        nextCheck = c.optional(String.self, .nextCheck)
    }
}

struct GoalLoadError: Decodable, Hashable, Sendable, Identifiable {
    let slug: String
    let error: String

    var id: String { slug }

    private enum CodingKeys: String, CodingKey { case slug, error }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = c.string(.slug)
        error = c.string(.error)
    }
}

struct GoalsHome: Decodable, Hashable, Sendable {
    let today: String
    let yesterday: String
    var streak: GoalStreak
    var goals: [GoalSummary]
    let agentGoals: [AgentGoalSummary]
    let errors: [GoalLoadError]

    private enum CodingKeys: String, CodingKey {
        case today, yesterday, streak, goals, errors, agentGoals = "agent_goals"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        today = c.string(.today)
        yesterday = c.string(.yesterday)
        streak = c.optional(GoalStreak.self, .streak) ?? GoalStreak()
        goals = c.lossy(GoalSummary.self, .goals)
        agentGoals = c.lossy(AgentGoalSummary.self, .agentGoals)
        errors = c.lossy(GoalLoadError.self, .errors)
    }
}

// MARK: - Detail

struct GoalConsistency: Decodable, Hashable, Sendable {
    var weeks = 0
    var weeksHit = 0
    var last4: Double?
    var lifetime: Double?

    private enum CodingKeys: String, CodingKey { case weeks, last4, lifetime, weeksHit = "weeks_hit" }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weeks = c.int(.weeks)
        weeksHit = c.int(.weeksHit)
        last4 = c.optional(Double.self, .last4)
        lifetime = c.optional(Double.self, .lifetime)
    }
}

struct GoalHeatDay: Decodable, Hashable, Sendable {
    let date: String
    let status: GoalStatus

    private enum CodingKeys: String, CodingKey { case date, status }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.string(.date)
        status = c.optional(GoalStatus.self, .status) ?? GoalStatus.none
    }
}

struct GoalCheckValue: Decodable, Hashable, Sendable {
    /// The value that undoes a daily check's answer for the day.
    static let clear = "clear"

    let date: String
    let value: String

    private enum CodingKeys: String, CodingKey { case date, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.string(.date)
        value = c.string(.value)
    }
}

struct GoalDoneWhen: Decodable, Hashable, Sendable {
    let text: String
    let checked: Bool

    private enum CodingKeys: String, CodingKey { case text, checked }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.string(.text)
        checked = c.bool(.checked)
    }
}

/// The full goal: its summary fields plus plan, milestones, consistency and history.
struct GoalDetail: Decodable, Hashable, Sendable {
    var summary: GoalSummary
    let why: String
    let notTheGoal: String
    let obstacle: String
    let objective: String
    let doneWhen: [GoalDoneWhen]
    let milestones: [GoalMilestone]
    let consistency: GoalConsistency
    let heatmap: [GoalHeatDay]
    let checkHistory: [String: [GoalCheckValue]]
    let today: String
    let yesterday: String
    var streak: GoalStreak

    private enum CodingKeys: String, CodingKey {
        case why, obstacle, objective, milestones, consistency, heatmap, today, yesterday, streak
        case notTheGoal = "not_the_goal", doneWhen = "done_when", checkHistory = "check_history"
    }

    init(from decoder: Decoder) throws {
        summary = try GoalSummary(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        why = c.string(.why)
        notTheGoal = c.string(.notTheGoal)
        obstacle = c.string(.obstacle)
        objective = c.string(.objective)
        doneWhen = c.lossy(GoalDoneWhen.self, .doneWhen)
        milestones = c.lossy(GoalMilestone.self, .milestones)
        consistency = c.optional(GoalConsistency.self, .consistency) ?? GoalConsistency()
        heatmap = c.lossy(GoalHeatDay.self, .heatmap)
        checkHistory = c.optional([String: [GoalCheckValue]].self, .checkHistory) ?? [:]
        today = c.string(.today)
        yesterday = c.string(.yesterday)
        streak = c.optional(GoalStreak.self, .streak) ?? GoalStreak()
    }
}

// MARK: - Check-in

enum GoalCheckInRequest: Encodable, Equatable, Sendable {
    /// `asOf` is the server's today from the screen's last load; the server answers 409
    /// when its day has moved on, so a stale screen never writes to the wrong day.
    case commitment(slug: String, date: String, asOf: String, id: String, status: GoalStatus)
    case check(slug: String, date: String, asOf: String, id: String, value: String)
    /// One +1 or -1 on an item commitment; a nil `note` is left out of the body.
    case item(slug: String, date: String, asOf: String, id: String, n: Int, note: String?)

    private enum CodingKeys: String, CodingKey {
        case slug, date, commitment, status, check, value, n, note, asOf = "as_of"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .commitment(slug, date, asOf, id, status):
            try c.encode(slug, forKey: .slug)
            try c.encode(date, forKey: .date)
            try c.encode(asOf, forKey: .asOf)
            try c.encode(id, forKey: .commitment)
            try c.encode(status.rawValue, forKey: .status)
        case let .check(slug, date, asOf, id, value):
            try c.encode(slug, forKey: .slug)
            try c.encode(date, forKey: .date)
            try c.encode(asOf, forKey: .asOf)
            try c.encode(id, forKey: .check)
            try c.encode(value, forKey: .value)
        case let .item(slug, date, asOf, id, n, note):
            try c.encode(slug, forKey: .slug)
            try c.encode(date, forKey: .date)
            try c.encode(asOf, forKey: .asOf)
            try c.encode(id, forKey: .commitment)
            try c.encode("item", forKey: .status)
            try c.encode(n, forKey: .n)
            try c.encodeIfPresent(note, forKey: .note)
        }
    }
}

/// `POST /api/goals/week`: the commitments for the week starting `start` (a Monday). `asOf` is
/// the server's today, as for a check-in; the server answers 409 once that week can't be planned.
struct GoalWeekRequest: Encodable, Equatable, Sendable {
    let slug: String
    let start: String
    let asOf: String
    let commitments: [DeckWeekCommitment]

    private enum CodingKeys: String, CodingKey { case slug, start, commitments, asOf = "as_of" }
}

struct GoalCheckInResult: Decodable, Hashable, Sendable {
    let goal: GoalSummary
    let streak: GoalStreak
    let today: String
    let yesterday: String

    private enum CodingKeys: String, CodingKey { case goal, streak, today, yesterday }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goal = try c.decode(GoalSummary.self, forKey: .goal)
        streak = c.optional(GoalStreak.self, .streak) ?? GoalStreak()
        today = c.string(.today)
        yesterday = c.string(.yesterday)
    }
}
