import Foundation

// Models for the Body API on this user's `hermes-webui` fork (`api/vault_body.py`, over the
// vault's `tools/gym.py`). Every field decodes tolerantly and keys are literal snake_case, so
// decode with `PrepDecoding`. The workout document (`BodySession`, `BodyExercise`, `BodySet`,
// `BodyCheck`) also encodes: the app saves it whole, and `sendData(body:)` leaves snake_case keys alone.

/// Decodes an element or yields nil, so one bad element never fails its array.
private struct BodyLossy<Value: Decodable>: Decodable {
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
        ((try? decodeIfPresent([BodyLossy<Value>].self, forKey: key)) ?? []).compactMap(\.value)
    }

    func strings(_ key: Key) -> [String] {
        (try? decodeIfPresent([String].self, forKey: key)) ?? []
    }
}

// MARK: - Formatting

enum BodyFormat {
    /// How a lift's load reads on the phone, mirroring `gym.weight_label`: "150 lb", "42.5s"
    /// (each hand), "BW", "Band", "Light cable", and "—" when a weighted lift has no weight yet.
    static func weightLabel(unit: String, weight: Double?) -> String {
        switch unit {
        case "bw": return "BW"
        case "band": return "Band"
        case "cable": return "Light cable"
        default: break
        }
        guard let weight else { return "—" }
        return unit == "lb_each" ? "\(number(weight))s" : "\(number(weight)) lb"
    }

    /// A weight without a trailing ".0": 150 reads "150", 42.5 reads "42.5".
    static func number(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

// MARK: - Small enums

/// One day in a week row. `off` is a rest day with nothing due, never "missed".
enum BodyDayState: String, Hashable, Sendable, Decodable {
    case done, off, today, ahead, unknown

    init(from decoder: Decoder) throws {
        self = BodyDayState(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .unknown
    }
}

/// Where a lift sits in a day. An unknown section reads as `main`.
enum BodySection: String, Hashable, Sendable, Codable {
    case main, superset, optional, finisher

    init(from decoder: Decoder) throws {
        self = BodySection(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .main
    }
}

/// How hard the session was, from the finish check.
enum BodyEffort: String, Hashable, Sendable, Codable, CaseIterable {
    case easy, solid, grinder

    init(from decoder: Decoder) throws {
        self = BodyEffort(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .solid
    }
}

/// How a body part felt, from the finish check.
enum BodyCondition: String, Hashable, Sendable, Codable, CaseIterable {
    case fine, tight, pain

    init(from decoder: Decoder) throws {
        self = BodyCondition(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .fine
    }
}

// MARK: - The workout document

/// One set of one lift. A weight is nil for bodyweight, band and cable lifts, and for a lift
/// (Lat pulldown) that has no weight yet: the workout lets him type one in.
struct BodySet: Codable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, Codable {
        case warm, work

        init(from decoder: Decoder) throws {
            self = Kind(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .work
        }
    }

    var kind: Kind
    var weight: Double?
    var reps: Int?
    var holdS: Int?
    var distanceYd: Int?
    var done: Bool

    private enum CodingKeys: String, CodingKey {
        case kind, weight, reps, holdS = "hold_s", distanceYd = "distance_yd", done
    }

    init(kind: Kind = .work, weight: Double? = nil, reps: Int? = nil, holdS: Int? = nil,
         distanceYd: Int? = nil, done: Bool = false) {
        self.kind = kind
        self.weight = weight
        self.reps = reps
        self.holdS = holdS
        self.distanceYd = distanceYd
        self.done = done
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.optional(Kind.self, .kind) ?? .work
        weight = c.optional(Double.self, .weight)
        reps = c.optional(Int.self, .reps)
        holdS = c.optional(Int.self, .holdS)
        distanceYd = c.optional(Int.self, .distanceYd)
        done = c.bool(.done)
    }
}

/// What a lift asks for: a rep range `[lo, hi]`, a hold in seconds, or a distance in yards.
struct BodyTarget: Codable, Hashable, Sendable {
    var reps: [Int]?
    var holdS: Int?
    var distanceYd: Int?

    private enum CodingKeys: String, CodingKey { case reps, holdS = "hold_s", distanceYd = "distance_yd" }

    init(reps: [Int]? = nil, holdS: Int? = nil, distanceYd: Int? = nil) {
        self.reps = reps
        self.holdS = holdS
        self.distanceYd = distanceYd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reps = c.optional([Int].self, .reps)
        holdS = c.optional(Int.self, .holdS)
        distanceYd = c.optional(Int.self, .distanceYd)
    }
}

/// One logged set from the lift's last session.
struct BodyLastSet: Codable, Hashable, Sendable {
    var weight: Double?
    var reps: Int?
    var holdS: Int?
    var distanceYd: Int?

    private enum CodingKeys: String, CodingKey { case weight, reps, holdS = "hold_s", distanceYd = "distance_yd" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weight = c.optional(Double.self, .weight)
        reps = c.optional(Int.self, .reps)
        holdS = c.optional(Int.self, .holdS)
        distanceYd = c.optional(Int.self, .distanceYd)
    }
}

/// One lift in a workout. `weightLabel` and `up` come from the server's prescription (a bump
/// is already applied); `last` is what he did last time; `repsLeft` is his answer to "how many
/// more could you have done?" on a big lift.
struct BodyExercise: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var name: String
    var section: BodySection
    var big: Bool
    var unit: String
    var perSide: Bool
    var target: BodyTarget
    var weightLabel: String
    var up: Bool
    var upFrom: Double?
    var goalReps: [Int]?
    var last: [BodyLastSet]
    var sets: [BodySet]
    var repsLeft: Int?
    var note: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, section, big, unit, perSide = "per_side", target, weightLabel = "weight_label",
             up, upFrom = "up_from", goalReps = "goal_reps", last, sets, repsLeft = "reps_left", note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        name = c.string(.name)
        section = c.optional(BodySection.self, .section) ?? .main
        big = c.bool(.big)
        unit = c.optional(String.self, .unit) ?? "lb"
        perSide = c.bool(.perSide)
        target = c.optional(BodyTarget.self, .target) ?? BodyTarget()
        weightLabel = c.optional(String.self, .weightLabel) ?? ""
        up = c.bool(.up)
        upFrom = c.optional(Double.self, .upFrom)
        goalReps = c.optional([Int].self, .goalReps)
        last = c.lossy(BodyLastSet.self, .last)
        sets = c.lossy(BodySet.self, .sets)
        repsLeft = c.optional(Int.self, .repsLeft)
        note = c.optional(String.self, .note)
    }

    /// The sets that count toward progression; warm-up sets are left out.
    var workSets: [BodySet] { sets.filter { $0.kind == .work } }
}

/// A pain report in the finish check: 0 to 10 on one lift.
struct BodyPain: Codable, Hashable, Sendable {
    var score: Int
    var lift: String

    init(score: Int, lift: String) {
        self.score = score
        self.lift = lift
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        score = c.int(.score)
        lift = c.string(.lift)
    }

    private enum CodingKeys: String, CodingKey { case score, lift }
}

/// The "how was it" check he fills in when a workout ends.
struct BodyCheck: Codable, Hashable, Sendable {
    var effort: BodyEffort
    var back: BodyCondition
    var shoulders: BodyCondition
    var pain: BodyPain?
    var note: String

    private enum CodingKeys: String, CodingKey { case effort, back, shoulders, pain, note }

    init(effort: BodyEffort = .solid, back: BodyCondition = .fine, shoulders: BodyCondition = .fine,
         pain: BodyPain? = nil, note: String = "") {
        self.effort = effort
        self.back = back
        self.shoulders = shoulders
        self.pain = pain
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        effort = c.optional(BodyEffort.self, .effort) ?? .solid
        back = c.optional(BodyCondition.self, .back) ?? .fine
        shoulders = c.optional(BodyCondition.self, .shoulders) ?? .fine
        pain = c.optional(BodyPain.self, .pain)
        note = c.string(.note)
    }
}

/// Baki's note after a finished workout, written by the model a little after the save.
struct BodyCoachNote: Codable, Hashable, Sendable {
    var headline: String
    var body: [String]
    var writtenAt: String?

    private enum CodingKeys: String, CodingKey { case headline, body, writtenAt = "written_at" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headline = c.string(.headline)
        body = c.strings(.body)
        writtenAt = c.optional(String.self, .writtenAt)
    }
}

/// A workout the app saves and reads back whole: `id` is `YYYY-MM-DD-<day>`. The server stamps
/// `phase` and `started`, and `finished` stays nil until the finish call.
struct BodySession: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var day: String
    var phase: String?
    var started: String?
    var finished: String?
    var deload: Bool
    var exercises: [BodyExercise]
    /// A rough night dropped a set from each lift.
    var trimmed: Bool
    /// The hinge lifts moved to the end of the main work.
    var movedHinge: Bool
    var check: BodyCheck?
    var coachNote: BodyCoachNote?
    var note: String?

    private enum CodingKeys: String, CodingKey {
        case id, day, phase, started, finished, deload, exercises, trimmed,
             movedHinge = "moved_hinge", check, coachNote = "coach_note", note
    }

    init(id: String, day: String, phase: String? = nil, started: String? = nil, finished: String? = nil,
         deload: Bool = false, exercises: [BodyExercise] = [], trimmed: Bool = false,
         movedHinge: Bool = false, check: BodyCheck? = nil, coachNote: BodyCoachNote? = nil,
         note: String? = nil) {
        self.id = id
        self.day = day
        self.phase = phase
        self.started = started
        self.finished = finished
        self.deload = deload
        self.exercises = exercises
        self.trimmed = trimmed
        self.movedHinge = movedHinge
        self.check = check
        self.coachNote = coachNote
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        let rawDay = c.string(.day)
        // The id ends in the day (`2026-11-23-push`) when an older document omits `day`.
        day = rawDay.isEmpty ? String(id.dropFirst(11)) : rawDay
        phase = c.optional(String.self, .phase)
        started = c.optional(String.self, .started)
        finished = c.optional(String.self, .finished)
        deload = c.bool(.deload)
        exercises = c.lossy(BodyExercise.self, .exercises)
        trimmed = c.bool(.trimmed)
        movedHinge = c.bool(.movedHinge)
        check = c.optional(BodyCheck.self, .check)
        coachNote = c.optional(BodyCoachNote.self, .coachNote)
        note = c.optional(String.self, .note)
    }

    var isFinished: Bool { finished != nil }
}

// MARK: - Prescription

/// A rough night: Garmin's hours (nil when unreadable) and his rating, 1 to 5.
struct BodySleepOffer: Decodable, Hashable, Sendable {
    let hours: Double?
    let quality: Int?

    private enum CodingKeys: String, CodingKey { case hours, quality }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hours = c.optional(Double.self, .hours)
        quality = c.optional(Int.self, .quality)
    }
}

/// What the app may ask about before starting. Both are absent without a Garmin file for today.
struct BodyOffers: Decodable, Hashable, Sendable {
    let sleep: BodySleepOffer?
    /// He woke under an hour ago and the day has a hinge lift.
    let hinge: Bool

    private enum CodingKeys: String, CodingKey { case sleep, hinge }

    init(sleep: BodySleepOffer? = nil, hinge: Bool = false) {
        self.sleep = sleep
        self.hinge = hinge
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sleep = c.optional(BodySleepOffer.self, .sleep)
        hinge = c.bool(.hinge)
    }
}

/// What to lift today (`GET /api/body/prescription`). `exercises` is empty in `before` and
/// `recover`. When today's saved, unfinished session exists, the server returns it with
/// `resumed` true, which is why `trimmed` and `movedHinge` are here too.
struct BodyPrescription: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let day: String
    let phase: String
    let deload: Bool
    let resumed: Bool
    let offers: BodyOffers
    let exercises: [BodyExercise]
    let trimmed: Bool
    let movedHinge: Bool

    private enum CodingKeys: String, CodingKey {
        case id, day, phase, deload, resumed, offers, exercises, trimmed, movedHinge = "moved_hinge"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        day = c.string(.day)
        phase = c.string(.phase)
        deload = c.bool(.deload)
        resumed = c.bool(.resumed)
        offers = c.optional(BodyOffers.self, .offers) ?? BodyOffers()
        exercises = c.lossy(BodyExercise.self, .exercises)
        trimmed = c.bool(.trimmed)
        movedHinge = c.bool(.movedHinge)
    }
}

// MARK: - Proposals

/// What accepting a proposal changes: a weight (reset, pain), a lift to swap to, or the Monday
/// of a deload week.
struct BodyProposalChange: Decodable, Hashable, Sendable {
    let weight: Double?
    let swapTo: String?
    let week: String?

    private enum CodingKeys: String, CodingKey { case weight, swapTo = "swap_to", week }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weight = c.optional(Double.self, .weight)
        swapTo = c.optional(String.self, .swapTo)
        week = c.optional(String.self, .week)
    }
}

/// One of Baki's suggestions. `kind` is `reset`, `swap`, `deload` or `pain`; `status` is
/// `pending`, `accepted` or `skipped`. `why` is a list of short bullets.
struct BodyProposal: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let created: String?
    let kind: String
    let lift: String?
    let change: BodyProposalChange?
    let title: String
    let why: [String]
    let rule: String
    let status: String
    let decidedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id, created, kind, lift, change, title, why, rule, status, decidedAt = "decided_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        created = c.optional(String.self, .created)
        kind = c.string(.kind)
        lift = c.optional(String.self, .lift)
        change = c.optional(BodyProposalChange.self, .change)
        title = c.string(.title)
        why = c.strings(.why)
        rule = c.string(.rule)
        status = c.optional(String.self, .status) ?? "pending"
        decidedAt = c.optional(String.self, .decidedAt)
    }

    var isPending: Bool { status == "pending" }
}

/// The answer to finishing a workout: the closed session and any proposals the rules raised.
struct BodyFinishResult: Decodable, Hashable, Sendable {
    let session: BodySession
    let proposals: [BodyProposal]

    private enum CodingKeys: String, CodingKey { case session, proposals }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decode(BodySession.self, forKey: .session)
        proposals = c.lossy(BodyProposal.self, .proposals)
    }
}

// MARK: - Home

/// A finished workout in a list: "Push · Nov 23 · 52 min".
struct BodySessionSummary: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let day: String
    let label: String
    let date: String
    let minutes: Int?
    let trimmed: Bool
    /// "Incline bench up to 150 lb" when a lift went up from its previous session.
    let highlight: String?
    let note: String?

    private enum CodingKeys: String, CodingKey { case id, day, label, date, minutes, trimmed, highlight, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        day = c.string(.day)
        label = c.string(.label)
        date = c.string(.date)
        minutes = c.optional(Int.self, .minutes)
        trimmed = c.bool(.trimmed)
        highlight = c.optional(String.self, .highlight)
        note = c.optional(String.self, .note)
    }
}

/// One lift in the next workout's preview.
struct BodyPreviewRow: Decodable, Hashable, Sendable {
    let name: String
    let weightLabel: String
    let up: Bool

    private enum CodingKeys: String, CodingKey { case name, weightLabel = "weight_label", up }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.string(.name)
        weightLabel = c.string(.weightLabel)
        up = c.bool(.up)
    }
}

/// The next workout. Nil on `BodyHome` before Re-entry starts.
struct BodyNext: Decodable, Hashable, Sendable {
    let day: String
    let label: String
    let preview: [BodyPreviewRow]

    private enum CodingKeys: String, CodingKey { case day, label, preview }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = c.string(.day)
        label = c.string(.label)
        preview = c.lossy(BodyPreviewRow.self, .preview)
    }
}

/// The week, Monday to Sunday: seven ISO dates and a state per day for lifting and for running.
struct BodyWeek: Decodable, Hashable, Sendable {
    let days: [String]
    let lifted: [BodyDayState]
    let ran: [BodyDayState]

    private enum CodingKeys: String, CodingKey { case days, lifted, ran }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = c.strings(.days)
        lifted = (try? c.decodeIfPresent([BodyDayState].self, forKey: .lifted)) ?? []
        ran = (try? c.decodeIfPresent([BodyDayState].self, forKey: .ran)) ?? []
    }
}

/// Last night, from Garmin. Absent on `BodyHome` until Garmin has synced.
struct BodyHomeSleep: Decodable, Hashable, Sendable {
    let hours: Double?
    let quality: Int?
    let bed: String?
    let wake: String?

    private enum CodingKeys: String, CodingKey { case hours, quality, bed, wake }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hours = c.optional(Double.self, .hours)
        quality = c.optional(Int.self, .quality)
        bed = c.optional(String.self, .bed)
        wake = c.optional(String.self, .wake)
    }
}

/// One lift on Body home: its next weight and a dot per work set of its last session (a dot is
/// true when that set was done at the top of its range or its goal).
struct BodyHomeLift: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let day: String
    let weightLabel: String
    let up: Bool
    let dots: [Bool]
    let goalReps: [Int]?

    private enum CodingKeys: String, CodingKey { case id, name, day, weightLabel = "weight_label", up, dots, goalReps = "goal_reps" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        name = c.string(.name)
        day = c.string(.day)
        weightLabel = c.string(.weightLabel)
        up = c.bool(.up)
        dots = (try? c.decodeIfPresent([Bool].self, forKey: .dots)) ?? []
        goalReps = c.optional([Int].self, .goalReps)
    }
}

/// Everything Body home shows (`GET /api/body/home`). `phase` is `before`, `recover`, `reentry`,
/// `build` or `newborn`; `phaseLabel` is the server's subtitle text ("Build · 6 weeks to January")
/// and `starts` ("Nov 9") is set only in `before`.
struct BodyHome: Decodable, Hashable, Sendable {
    let phase: String
    let phaseLabel: String
    let starts: String?
    let next: BodyNext?
    let week: BodyWeek
    let sleep: BodyHomeSleep?
    let lifts: [BodyHomeLift]
    let sessions: [BodySessionSummary]
    let proposals: [BodyProposal]
    /// Rotation days with no finished session in 10 or more days.
    let gaps: [String]

    private enum CodingKeys: String, CodingKey {
        case phase, phaseLabel = "phase_label", starts, next, week, sleep, lifts, sessions, proposals, gaps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = c.string(.phase)
        phaseLabel = c.string(.phaseLabel)
        starts = c.optional(String.self, .starts)
        next = c.optional(BodyNext.self, .next)
        week = c.optional(BodyWeek.self, .week) ?? BodyWeek.empty
        sleep = c.optional(BodyHomeSleep.self, .sleep)
        lifts = c.lossy(BodyHomeLift.self, .lifts)
        sessions = c.lossy(BodySessionSummary.self, .sessions)
        proposals = c.lossy(BodyProposal.self, .proposals)
        gaps = c.strings(.gaps)
    }
}

extension BodyWeek {
    static let empty = BodyWeek(days: [], lifted: [], ran: [])

    private init(days: [String], lifted: [BodyDayState], ran: [BodyDayState]) {
        self.days = days
        self.lifted = lifted
        self.ran = ran
    }
}

// MARK: - A lift's history

struct BodyLiftPoint: Decodable, Hashable, Sendable {
    let date: String
    let weight: Double?

    private enum CodingKeys: String, CodingKey { case date, weight }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.string(.date)
        weight = c.optional(Double.self, .weight)
    }
}

struct BodyLiftSession: Decodable, Hashable, Sendable {
    let date: String
    let weightLabel: String
    let reps: [Int]
    let note: String?

    private enum CodingKeys: String, CodingKey { case date, weightLabel = "weight_label", reps, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = c.string(.date)
        weightLabel = c.string(.weightLabel)
        reps = (try? c.decodeIfPresent([Int].self, forKey: .reps)) ?? []
        note = c.optional(String.self, .note)
    }
}

/// One lift's detail (`GET /api/body/lift?id=`): `series` is weight over time, oldest first, and
/// `sessions` is each session's reps, newest first. `weightLabel` and `up` are the next prescription.
struct BodyLift: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let unit: String
    let weightLabel: String
    let up: Bool
    let series: [BodyLiftPoint]
    let sessions: [BodyLiftSession]

    private enum CodingKeys: String, CodingKey { case id, name, unit, weightLabel = "weight_label", up, series, sessions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        name = c.string(.name)
        unit = c.optional(String.self, .unit) ?? "lb"
        weightLabel = c.string(.weightLabel)
        up = c.bool(.up)
        series = c.lossy(BodyLiftPoint.self, .series)
        sessions = c.lossy(BodyLiftSession.self, .sessions)
    }
}

// MARK: - The plan

/// A phase's inclusive dates as ISO strings.
struct BodyPhaseSpec: Codable, Hashable, Sendable {
    var start: String
    var end: String?

    private enum CodingKeys: String, CodingKey { case start, end }

    init(start: String, end: String? = nil) {
        self.start = start
        self.end = end
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = c.string(.start)
        end = c.optional(String.self, .end)
    }
}

/// A lift's load: its unit, the build and re-entry weights, and the step a bump adds. Nil
/// weights are written back as null, like plan.yaml has them.
struct BodyPlanLoad: Codable, Hashable, Sendable {
    var unit: String
    var build: Double?
    var reentry: Double?
    var increment: Double?

    private enum CodingKeys: String, CodingKey { case unit, build, reentry, increment }

    init(unit: String, build: Double? = nil, reentry: Double? = nil, increment: Double? = nil) {
        self.unit = unit
        self.build = build
        self.reentry = reentry
        self.increment = increment
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = c.optional(String.self, .unit) ?? "lb"
        build = c.optional(Double.self, .build)
        reentry = c.optional(Double.self, .reentry)
        increment = c.optional(Double.self, .increment)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(unit, forKey: .unit)
        for (value, key) in [(build, CodingKeys.build), (reentry, .reentry), (increment, .increment)] {
            if let value { try c.encode(value, forKey: key) } else { try c.encodeNil(forKey: key) }
        }
    }
}

/// One exercise in `plan.yaml`. Exactly one of `reps`, `holdS` and `distanceYd` is set.
struct BodyPlanExercise: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var name: String
    var section: BodySection
    var sets: Int
    var reps: [Int]?
    var holdS: Int?
    var distanceYd: Int?
    var big: Bool
    var newborn: Bool
    var hinge: Bool
    var perSide: Bool
    var rampSets: Int?
    var goalReps: [Int]?
    var alternates: [String]?
    var alternateWeekly: String?
    var load: BodyPlanLoad

    private enum CodingKeys: String, CodingKey {
        case id, name, section, sets, reps, holdS = "hold_s", distanceYd = "distance_yd", big, newborn, hinge,
             perSide = "per_side", rampSets = "ramp_sets", goalReps = "goal_reps", alternates,
             alternateWeekly = "alternate_weekly", load
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        name = c.string(.name)
        section = c.optional(BodySection.self, .section) ?? .main
        sets = c.int(.sets)
        reps = c.optional([Int].self, .reps)
        holdS = c.optional(Int.self, .holdS)
        distanceYd = c.optional(Int.self, .distanceYd)
        big = c.bool(.big)
        newborn = c.bool(.newborn)
        hinge = c.bool(.hinge)
        perSide = c.bool(.perSide)
        rampSets = c.optional(Int.self, .rampSets)
        goalReps = c.optional([Int].self, .goalReps)
        alternates = c.optional([String].self, .alternates)
        alternateWeekly = c.optional(String.self, .alternateWeekly)
        load = c.optional(BodyPlanLoad.self, .load) ?? BodyPlanLoad(unit: "bw")
    }

    /// Writes only what the plan file has: flags appear when true, optional keys when set.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(section, forKey: .section)
        try c.encode(sets, forKey: .sets)
        try c.encodeIfPresent(reps, forKey: .reps)
        try c.encodeIfPresent(holdS, forKey: .holdS)
        try c.encodeIfPresent(distanceYd, forKey: .distanceYd)
        if big { try c.encode(true, forKey: .big) }
        if newborn { try c.encode(true, forKey: .newborn) }
        if hinge { try c.encode(true, forKey: .hinge) }
        if perSide { try c.encode(true, forKey: .perSide) }
        try c.encodeIfPresent(rampSets, forKey: .rampSets)
        try c.encodeIfPresent(goalReps, forKey: .goalReps)
        try c.encodeIfPresent(alternates, forKey: .alternates)
        try c.encodeIfPresent(alternateWeekly, forKey: .alternateWeekly)
        try c.encode(load, forKey: .load)
    }
}

/// A structured mirror of `gym/plan.yaml` (`GET` and `POST /api/body/plan`). `rotation` names
/// the days in order; `days` also holds `warmup`.
struct BodyPlan: Codable, Hashable, Sendable {
    var phases: [String: BodyPhaseSpec]
    var rotation: [String]
    var days: [String: [BodyPlanExercise]]

    private enum CodingKeys: String, CodingKey { case phases, rotation, days }

    init(phases: [String: BodyPhaseSpec] = [:], rotation: [String] = [], days: [String: [BodyPlanExercise]] = [:]) {
        self.phases = phases
        self.rotation = rotation
        self.days = days
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phases = (try? c.decodeIfPresent([String: BodyPhaseSpec].self, forKey: .phases)) ?? [:]
        rotation = c.strings(.rotation)
        let raw = (try? c.decodeIfPresent([String: [BodyLossy<BodyPlanExercise>]].self, forKey: .days)) ?? [:]
        days = raw.mapValues { $0.compactMap(\.value) }
    }
}
