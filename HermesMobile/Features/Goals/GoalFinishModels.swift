import Foundation

// Models for finishing a goal on this user's `hermes-webui` fork (`api/vault_goals.py`, over the
// vault's `tools/goals.py`): `POST /api/goals/finish`, `GET /api/goals/record?slug=`,
// `POST /api/goals/reflection`, and the `finished` list on `GET /api/goals`. The record is
// computed once when the goal closes. Every field decodes tolerantly; decode with `PrepDecoding`.

private struct FinishLossy<Value: Decodable>: Decodable {
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

    func double(_ key: Key) -> Double {
        (try? decodeIfPresent(Double.self, forKey: key)) ?? 0
    }

    func optional<Value: Decodable>(_ type: Value.Type, _ key: Key) -> Value? {
        try? decodeIfPresent(Value.self, forKey: key)
    }

    func lossy<Value: Decodable>(_ type: Value.Type, _ key: Key) -> [Value] {
        ((try? decodeIfPresent([FinishLossy<Value>].self, forKey: key)) ?? []).compactMap(\.value)
    }
}

/// The one number a finished goal is remembered by: "61.4" "miles run in 2026".
struct GoalHeadline: Decodable, Hashable, Sendable {
    let value: String
    let label: String

    private enum CodingKeys: String, CodingKey { case value, label }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = c.string(.value)
        label = c.string(.label)
    }
}

/// An achieved goal in the Finished log.
struct GoalFinishedSummary: Decodable, Hashable, Sendable, Identifiable {
    let slug: String
    let title: String
    let identity: String
    let color: String
    let icon: String
    let started: String
    let finished: String
    let days: Int
    let shown: Int
    let headline: GoalHeadline?
    let milestones: Int
    let milestonesOnTime: Int

    var id: String { slug }

    private enum CodingKeys: String, CodingKey {
        case slug, title, identity, color, icon, started, finished, days, shown, headline, milestones
        case milestonesOnTime = "milestones_on_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = c.string(.slug)
        title = c.string(.title)
        identity = c.string(.identity)
        color = c.string(.color)
        icon = c.string(.icon)
        started = c.string(.started)
        finished = c.string(.finished)
        days = c.int(.days)
        shown = c.int(.shown)
        headline = c.optional(GoalHeadline.self, .headline)
        milestones = c.int(.milestones)
        milestonesOnTime = c.int(.milestonesOnTime)
    }
}

struct GoalRecordStreak: Decodable, Hashable, Sendable {
    let days: Int
    let start: String
    let end: String

    private enum CodingKeys: String, CodingKey { case days, start, end }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = c.int(.days)
        start = c.string(.start)
        end = c.string(.end)
    }
}

struct GoalRecordMilestone: Decodable, Hashable, Sendable {
    let id: String
    let title: String
    let due: String?
    let done: String?
    let onTime: Bool

    private enum CodingKeys: String, CodingKey { case id, title, due, done, onTime = "on_time" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        title = c.string(.title)
        due = c.optional(String.self, .due)
        done = c.optional(String.self, .done)
        onTime = c.optional(Bool.self, .onTime) ?? false
    }
}

/// A commitment's total over the whole goal: days shown up, or items counted.
struct GoalCommitmentTotal: Decodable, Hashable, Sendable {
    let id: String
    let action: String
    let unit: String
    let done: Int
    let min: Int
    let total: Int

    private enum CodingKeys: String, CodingKey { case id, action, unit, done, min, total }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        action = c.string(.action)
        unit = c.string(.unit)
        done = c.int(.done)
        min = c.int(.min)
        total = c.int(.total)
    }
}

/// A daily check's answers over the goal, in the question's order.
struct GoalCheckTally: Decodable, Hashable, Sendable {
    struct Count: Decodable, Hashable, Sendable {
        let value: String
        let count: Int

        private enum CodingKeys: String, CodingKey { case value, count }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = c.string(.value)
            count = c.int(.count)
        }
    }

    let id: String
    let question: String
    let counts: [Count]

    private enum CodingKeys: String, CodingKey { case id, question, counts }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        question = c.string(.question)
        counts = c.lossy(Count.self, .counts)
    }
}

struct GoalRun: Decodable, Hashable, Sendable {
    let date: String
    let miles: Double
    let seconds: Int
    let avgHR: Int?

    private enum CodingKeys: String, CodingKey { case date, miles, seconds, avgHR = "avg_hr" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.string(.date)
        miles = c.double(.miles)
        seconds = c.int(.seconds)
        avgHR = c.optional(Int.self, .avgHR)
    }
}

/// The race: the longest Garmin run on the finish day, with its mile splits (seconds a mile).
struct GoalRace: Decodable, Hashable, Sendable {
    let date: String
    let miles: Double
    let seconds: Int
    let paceSeconds: Int
    let avgHR: Int?
    let splits: [Int]
    let fastestMileSeconds: Int?
    /// Second half minus first half; negative is a negative split.
    let halvesSeconds: Int?

    private enum CodingKeys: String, CodingKey {
        case date, miles, seconds, splits
        case paceSeconds = "pace_s", avgHR = "avg_hr", fastestMileSeconds = "fastest_mile_s", halvesSeconds = "halves_s"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.string(.date)
        miles = c.double(.miles)
        seconds = c.int(.seconds)
        paceSeconds = c.int(.paceSeconds)
        avgHR = c.optional(Int.self, .avgHR)
        splits = c.optional([Int].self, .splits) ?? []
        fastestMileSeconds = c.optional(Int.self, .fastestMileSeconds)
        halvesSeconds = c.optional(Int.self, .halvesSeconds)
    }
}

/// Every Garmin run from Jan 1 of the finish year through the finish.
struct GoalRuns: Decodable, Hashable, Sendable {
    struct Month: Decodable, Hashable, Sendable {
        let month: String
        let miles: Double

        private enum CodingKeys: String, CodingKey { case month, miles }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            month = c.string(.month)
            miles = c.double(.miles)
        }
    }

    let year: Int
    let count: Int
    let miles: Double
    let seconds: Int
    let first: String
    let longest: GoalRun?
    let prs: [String]
    let months: [Month]
    let race: GoalRace?

    private enum CodingKeys: String, CodingKey { case year, count, miles, seconds, first, longest, prs, months, race }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        year = c.int(.year)
        count = c.int(.count)
        miles = c.double(.miles)
        seconds = c.int(.seconds)
        first = c.string(.first)
        longest = c.optional(GoalRun.self, .longest)
        prs = c.optional([String].self, .prs) ?? []
        months = c.lossy(Month.self, .months)
        race = c.optional(GoalRace.self, .race)
    }
}

/// One line of the record's story, oldest first; the last one is the finish.
struct GoalStoryMoment: Decodable, Hashable, Sendable {
    let date: String
    let title: String
    let detail: String
    let major: Bool

    private enum CodingKeys: String, CodingKey { case date, title, detail, major }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.string(.date)
        title = c.string(.title)
        detail = c.string(.detail)
        major = c.optional(Bool.self, .major) ?? false
    }
}

/// A finished goal's record: everything he did, computed once when it closed.
struct GoalRecord: Decodable, Hashable, Sendable {
    let slug: String
    let title: String
    let identity: String
    let why: String
    let color: String
    let icon: String
    let outcome: String
    var reflection: String
    let started: String
    let finished: String
    let days: Int
    let shown: Int
    let minDays: Int
    let skipDays: Int
    let missDays: Int
    let missedTwice: Int
    let streak: GoalRecordStreak?
    let weeks: GoalConsistency
    let skipsUsed: Int
    let skipsBudget: Int
    let milestones: [GoalRecordMilestone]
    let commitments: [GoalCommitmentTotal]
    let checks: [GoalCheckTally]
    let runs: GoalRuns?
    let heatmap: [GoalHeatDay]
    let headline: GoalHeadline?
    let story: [GoalStoryMoment]

    private enum CodingKeys: String, CodingKey {
        case slug, title, identity, why, color, icon, outcome, reflection, started, finished, days, shown
        case streak, weeks, skips, milestones, commitments, checks, runs, heatmap, headline, story
        case minDays = "min_days", skipDays = "skip_days", missDays = "miss_days", missedTwice = "missed_twice"
    }

    private struct Skips: Decodable {
        let used: Int?
        let budget: Int?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = c.string(.slug)
        title = c.string(.title)
        identity = c.string(.identity)
        why = c.string(.why)
        color = c.string(.color)
        icon = c.string(.icon)
        outcome = c.string(.outcome)
        reflection = c.string(.reflection)
        started = c.string(.started)
        finished = c.string(.finished)
        days = c.int(.days)
        shown = c.int(.shown)
        minDays = c.int(.minDays)
        skipDays = c.int(.skipDays)
        missDays = c.int(.missDays)
        missedTwice = c.int(.missedTwice)
        streak = c.optional(GoalRecordStreak.self, .streak)
        weeks = c.optional(GoalConsistency.self, .weeks) ?? GoalConsistency()
        let skips = c.optional(Skips.self, .skips)
        skipsUsed = skips?.used ?? 0
        skipsBudget = skips?.budget ?? 0
        milestones = c.lossy(GoalRecordMilestone.self, .milestones)
        commitments = c.lossy(GoalCommitmentTotal.self, .commitments)
        checks = c.lossy(GoalCheckTally.self, .checks)
        runs = c.optional(GoalRuns.self, .runs)
        heatmap = c.lossy(GoalHeatDay.self, .heatmap)
        headline = c.optional(GoalHeadline.self, .headline)
        story = c.lossy(GoalStoryMoment.self, .story)
    }
}

/// `POST /api/goals/finish`: close the goal as achieved. `asOf` is the server's today from the
/// screen's last load; the server answers 409 when its day has moved on.
struct GoalFinishRequest: Encodable, Equatable, Sendable {
    let slug: String
    let asOf: String

    private enum CodingKeys: String, CodingKey { case slug, asOf = "as_of" }
}

/// `POST /api/goals/reflection`: his words on a finished goal; empty clears them.
struct GoalReflectionRequest: Encodable, Equatable, Sendable {
    let slug: String
    let text: String
}
