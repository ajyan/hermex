import Foundation

/// Today's job-search Ask from this user's `hermes-webui` fork (`api/vault_jobs.py` over the vault's
/// `tools/daily_ask.py`): `GET /api/jobs/ask` and `POST /api/jobs/ask`. Each weekday it offers three
/// roles to apply to or reach out about, and `locked` keeps Brain › Prep closed until one is acted on
/// or the day is skipped with a reason. Stock servers answer 404, which means no card and no lock.
struct DailyAsk: Decodable, Equatable, Sendable {
    let today: String
    let weekday: Bool?
    let roles: [DailyAskRole]?
    /// "apply" until this week's applications target is met, then "reach".
    let lead: String?
    /// Today's Applied, Sent or Skip, once there is one.
    let outcome: DailyAskOutcome?
    /// The last weekday's result: "done", "skipped", "missed", or nil.
    let previous: String?
    let locked: Bool?
    let week: DailyAskWeek?
    /// The standing note that lifts matching titles on the next Ask, if one is set.
    let steer: String?
    /// Applications made outside the Ask and logged today.
    let elsewhere: [DailyAskElsewhere]?

    var isReachFirst: Bool { lead == "reach" }
    var needsNeverMissTwice: Bool { previous == "skipped" || previous == "missed" }

    private enum CodingKeys: String, CodingKey {
        case today, weekday, roles, lead, outcome, previous, locked, week, steer, elsewhere
    }

    /// `roles` drops a role that fails to decode, so one bad role never fails the Ask (which
    /// would leave Prep open).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        today = try c.decode(String.self, forKey: .today)
        weekday = try c.decodeIfPresent(Bool.self, forKey: .weekday)
        roles = try c.decodeIfPresent([PrepLossy<DailyAskRole>].self, forKey: .roles)?.compactMap(\.value)
        lead = try c.decodeIfPresent(String.self, forKey: .lead)
        outcome = try c.decodeIfPresent(DailyAskOutcome.self, forKey: .outcome)
        previous = try c.decodeIfPresent(String.self, forKey: .previous)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked)
        week = try c.decodeIfPresent(DailyAskWeek.self, forKey: .week)
        let note = try? c.decodeIfPresent(String.self, forKey: .steer)
        steer = note?.isEmpty == false ? note : nil
        elsewhere = (try? c.decodeIfPresent([PrepLossy<DailyAskElsewhere>].self, forKey: .elsewhere))?.compactMap(\.value)
    }
}

struct DailyAskRole: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let company: String
    let title: String
    let location: String?
    let url: String?
    let bandLabel: String?
    /// What the role is and does, in plain words.
    let note: String?
    /// The honest catch: why this role might not fit him. Absent when there is none.
    let `catch`: String?
    /// A LinkedIn people search for the company's Applied AI team.
    let searchUrl: String?
    /// The reach-out opener, with `<name>` and the specific hook left for him to fill.
    let opener: String?

    private enum CodingKeys: String, CodingKey {
        case id, company, title, location, url, note, opener, `catch`
        case bandLabel = "band_label"
        case searchUrl = "search_url"
    }
}

struct DailyAskOutcome: Decodable, Equatable, Sendable {
    /// "applied", "sent" or "skip".
    let event: String
    let role: String?
    let company: String?
    let title: String?
    let reason: String?
    let name: String?
}

/// An application logged with "Applied elsewhere": a recruiter, LinkedIn or a startup outside the Ask.
struct DailyAskElsewhere: Decodable, Equatable, Sendable {
    let company: String
    let via: String?
}

struct DailyAskWeek: Decodable, Equatable, Sendable {
    let applications: DailyAskCount?
    let outreach: DailyAskCount?
}

struct DailyAskCount: Decodable, Equatable, Sendable {
    let done: Int?
    let target: Int?
}

/// The POST body. `asOf` is the server's today from the last load; the server answers 409 when its
/// day has moved on. Nil fields are left out (APIClient encodes keys in snake_case).
struct DailyAskRequest: Encodable, Equatable, Sendable {
    let asOf: String
    let action: String
    let role: String?
    let reason: String?
    let name: String?
    let rule: String?
    var note: String?
    var company: String?
    var via: String?
}

enum DailyAskAction: Equatable, Sendable {
    case applied(role: String)
    case sent(role: String, name: String?)
    /// `rule`: company, title, level, location, comp or other. Company and Title become filter rules.
    case pass(role: String, reason: String, rule: String)
    case skip(reason: String)
    /// Counts toward this week's applications without being today's Ask.
    case elsewhere(company: String, via: String?)
    /// "" clears the steer.
    case steer(note: String)

    func request(asOf: String) -> DailyAskRequest {
        switch self {
        case .applied(let role):
            return DailyAskRequest(asOf: asOf, action: "applied", role: role, reason: nil, name: nil, rule: nil)
        case .sent(let role, let name):
            return DailyAskRequest(asOf: asOf, action: "sent", role: role, reason: nil, name: name, rule: nil)
        case .pass(let role, let reason, let rule):
            return DailyAskRequest(asOf: asOf, action: "pass", role: role, reason: reason, name: nil, rule: rule)
        case .skip(let reason):
            return DailyAskRequest(asOf: asOf, action: "skip", role: nil, reason: reason, name: nil, rule: nil)
        case .elsewhere(let company, let via):
            return DailyAskRequest(asOf: asOf, action: "elsewhere", role: nil, reason: nil, name: nil, rule: nil,
                                   company: company, via: via)
        case .steer(let note):
            return DailyAskRequest(asOf: asOf, action: "steer", role: nil, reason: nil, name: nil, rule: nil, note: note)
        }
    }
}

protocol DailyAskDataClient: Sendable {
    func ask() async throws -> DailyAsk
    func act(_ r: DailyAskRequest) async throws -> DailyAsk
}

/// Wraps the `APIClient` actor in a `Sendable` value for the protocol, decoding with `PrepDecoding`.
struct APIClientDailyAskAdapter: DailyAskDataClient {
    let apiClient: APIClient

    func ask() async throws -> DailyAsk {
        // Short: the Prep gate waits on this, and a slow server must not hold Prep shut.
        try decode(try await apiClient.sendData(endpoint: .jobsAsk, method: "GET", encodedBody: nil, timeout: 8))
    }

    func act(_ r: DailyAskRequest) async throws -> DailyAsk {
        try decode(try await apiClient.sendData(endpoint: .jobsAsk, method: "POST", body: r))
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try PrepDecoding.decode(Value.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }
}
