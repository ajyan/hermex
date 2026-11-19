import Foundation

// Baki's coaching on the Body API (`tools/gym.py`): the body check before a workout, his
// adjustments to today's session, the cue and focus on each lift, a lift's Form page, and what he
// is watching on home. Everything here is optional on the wire and decodes tolerantly; a server
// without it sends none of it and the app shows nothing new. The parts of the workout document
// (`BodyDayCheck`, `BodyAdjustment`, `BodyCoach`) also encode, since the app saves the session whole.

private extension KeyedDecodingContainer {
    func string(_ key: Key) -> String {
        (try? decodeIfPresent(String.self, forKey: key)) ?? ""
    }

    func bool(_ key: Key) -> Bool {
        (try? decodeIfPresent(Bool.self, forKey: key)) ?? false
    }

    func optional<Value: Decodable>(_ type: Value.Type, _ key: Key) -> Value? {
        try? decodeIfPresent(Value.self, forKey: key)
    }

    func strings(_ key: Key) -> [String] {
        (try? decodeIfPresent([String].self, forKey: key)) ?? []
    }

    /// Each element that decodes; one bad element never fails the array.
    func lossy<Value: Decodable>(_ type: Value.Type, _ key: Key) -> [Value] {
        ((try? decodeIfPresent([BodyCoachLossy<Value>].self, forKey: key)) ?? []).compactMap(\.value)
    }
}

private struct BodyCoachLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - The body check

/// A part of his body the check before a workout asks about, and that a lift can load
/// (`loads` on an exercise).
enum BodyArea: String, Hashable, Sendable, CaseIterable {
    case lowerBack = "lower_back"
    case shoulders
    case shoulderBlades = "shoulder_blades"

    /// "Lower back", as a chip and at the start of a sentence.
    var title: String {
        switch self {
        case .lowerBack: "Lower back"
        case .shoulders: "Shoulders"
        case .shoulderBlades: "Shoulder blades"
        }
    }

    /// "lower back", inside a sentence.
    var phrase: String { title.lowercased() }
}

/// His answer to "How's your body today?" on the workout document (`body_check`). `area` nil with
/// score 0 means all good; `removed` lists the lifts the app took out of today's session.
struct BodyDayCheck: Codable, Hashable, Sendable {
    /// `lower_back`, `shoulders` or `shoulder_blades`, as sent.
    var area: String?
    var score: Int
    var removed: [String]

    private enum CodingKeys: String, CodingKey { case area, score, removed }

    init(area: BodyArea? = nil, score: Int = 0, removed: [String] = []) {
        self.area = area?.rawValue
        self.score = score
        self.removed = removed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        area = c.optional(String.self, .area)
        score = c.optional(Int.self, .score) ?? 0
        removed = c.strings(.removed)
    }

    /// "All good" is written as `area: null`, as the contract has it.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let area { try c.encode(area, forKey: .area) } else { try c.encodeNil(forKey: .area) }
        try c.encode(score, forKey: .score)
        try c.encode(removed, forKey: .removed)
    }

    /// The area as the app knows it; nil for all good and for a value this build doesn't know.
    var bodyArea: BodyArea? { area.flatMap(BodyArea.init(rawValue:)) }
}

/// The 0 to 10 pain score the finish check and the body check step through.
enum BodyPainScore {
    /// The score after one tap: 5 from nothing, then a step either way inside 0 to 10.
    static func stepped(_ score: Int?, by delta: Int) -> Int {
        guard let score else { return 5 }
        return min(max(score + delta, 0), 10)
    }
}

// MARK: - Adjustments

/// One change Baki offers on a fresh prescription. `kind` is `move_up` (do `lift` right after
/// `after`) or `cap_first` (stop the first work set at `reps`); the words are the server's. The
/// app applies it and records `use` or `keep` in the session's `adjustment_answers`.
struct BodyAdjustment: Codable, Hashable, Sendable, Identifiable {
    static let moveUp = "move_up"
    static let capFirst = "cap_first"
    /// The answers `adjustment_answers` holds.
    static let used = "use"
    static let kept = "keep"

    let id: String
    var kind: String
    var lift: String
    var after: String?
    var reps: Int?
    var title: String
    var question: String
    var use: String
    var keep: String
    var done: String

    private enum CodingKeys: String, CodingKey { case id, kind, lift, after, reps, title, question, use, keep, done }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        kind = c.string(.kind)
        lift = c.string(.lift)
        after = c.optional(String.self, .after)
        reps = c.optional(Int.self, .reps)
        title = c.string(.title)
        question = c.string(.question)
        use = c.string(.use)
        keep = c.string(.keep)
        done = c.string(.done)
    }
}

// MARK: - The cue on a lift

/// His answer to a lift's focus question, saved on the exercise as `focus_check`.
enum BodyFocusAnswer: String, Hashable, Sendable, CaseIterable {
    case yes, mostly, no

    /// The button's words.
    var label: String {
        switch self {
        case .yes: "Yes"
        case .mostly: "Mostly"
        case .no: "Not yet"
        }
    }

    /// The pip an earlier answer draws: filled, a glow ring, or an empty ring.
    var pip: LiftPip {
        switch self {
        case .yes: .hit
        case .mostly: .short
        case .no: .notDone
        }
    }
}

/// Baki's cue for one lift on a fresh prescription (`coach`), saved back with the exercise so
/// history knows which focus an answer was for. `focus` is `pace` (with a `plan` line) or `cue`;
/// `checks` are his answers from earlier sessions with this focus, oldest first, at most three;
/// `retired` leaves only the Form link; `leave` is how many reps to leave in the tank.
struct BodyCoach: Codable, Hashable, Sendable {
    var cue: String
    var focus: String
    var title: String
    var plan: String?
    var ask: String
    var checks: [String]
    var retired: Bool
    var film: Bool
    var leave: Int?

    private enum CodingKeys: String, CodingKey { case cue, focus, title, plan, ask, checks, retired, film, leave }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cue = c.string(.cue)
        focus = c.optional(String.self, .focus) ?? "cue"
        title = c.string(.title)
        plan = c.optional(String.self, .plan)
        ask = c.string(.ask)
        checks = c.strings(.checks)
        retired = c.bool(.retired)
        film = c.bool(.film)
        leave = c.optional(Int.self, .leave)
    }

    var isPace: Bool { focus == "pace" }
}

// MARK: - Watching

/// One pattern Baki is watching, on Body home: `pips` are `yes`, `no` or `none`, oldest first, up
/// to four, and `next` says what happens if it goes on.
struct BodyWatching: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let pips: [String]
    let next: String

    private enum CodingKeys: String, CodingKey { case id, name, pips, next }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        name = c.string(.name)
        pips = c.strings(.pips)
        next = c.string(.next)
    }
}

// MARK: - The Form page

struct BodyFormFault: Decodable, Hashable, Sendable {
    let fault: String
    let fix: String

    private enum CodingKeys: String, CodingKey { case fault, fix }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fault = c.string(.fault)
        fix = c.string(.fix)
    }
}

struct BodyFormSource: Decodable, Hashable, Sendable {
    let title: String
    let url: String

    private enum CodingKeys: String, CodingKey { case title, url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.string(.title)
        url = c.string(.url)
    }
}

/// What Baki has him working on for this lift: a title, a line on why, and his earlier answers.
struct BodyFormFocus: Decodable, Hashable, Sendable {
    let title: String
    let body: String
    let checks: [String]
    let retired: Bool

    private enum CodingKeys: String, CodingKey { case title, body, checks, retired }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.string(.title)
        body = c.string(.body)
        checks = c.strings(.checks)
        retired = c.bool(.retired)
    }
}

/// A lift's cue card (`form` on the lift's detail, and the answer to picking a cue): how to set
/// up, the cues with the one he picked, what goes wrong and its fix, where to feel it, a safety
/// line, and where it came from.
struct BodyForm: Decodable, Hashable, Sendable {
    /// The cue card's key, which picking a cue posts as `lift`: the lift's id, or this week's
    /// alternate (`reverse-lunge` for the split squat). Nil from a server that doesn't send it.
    var lift: String?
    var setup: String
    var cues: [String]
    var picked: Int
    var faults: [BodyFormFault]
    var feel: [String]
    var safety: String?
    var sources: [BodyFormSource]
    var focus: BodyFormFocus?
    /// The areas the lift loads, when the server sends them with the form.
    var loads: [String]

    private enum CodingKeys: String, CodingKey {
        case lift, setup, cues, picked, faults, feel, safety, sources, focus, loads
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lift = c.optional(String.self, .lift)
        setup = c.string(.setup)
        cues = c.strings(.cues)
        picked = c.optional(Int.self, .picked) ?? 0
        faults = c.lossy(BodyFormFault.self, .faults)
        feel = c.strings(.feel)
        safety = c.optional(String.self, .safety)
        sources = c.lossy(BodyFormSource.self, .sources)
        focus = c.optional(BodyFormFocus.self, .focus)
        loads = c.strings(.loads)
    }
}

/// The answer to `POST /api/body/cue`: the lift's new form, bare or under a `form` key.
struct BodyCuePickResult: Decodable {
    let form: BodyForm

    private enum CodingKeys: String, CodingKey { case form }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self), c.contains(.form) {
            form = try c.decode(BodyForm.self, forKey: .form)
        } else {
            form = try BodyForm(from: decoder)
        }
    }
}
