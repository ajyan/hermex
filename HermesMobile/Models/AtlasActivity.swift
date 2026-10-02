import Foundation

/// The activity filters the Atlas sidecar understands. `.all` omits the
/// `filter` query item entirely so the sidecar returns every event type.
enum AtlasActivityFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case attention
    case cron
    case spending

    var id: String { rawValue }
}

/// The outcome of one logged activity. The sidecar may report outcomes the app
/// does not know about (sidecars run ahead of the app), so unknown strings
/// decode to `.unknown` instead of failing the whole page.
enum AtlasOutcome: String, Decodable, Sendable {
    case ok
    case error
    case blocked
    case denied
    case approved
    case unknown

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = AtlasOutcome(rawValue: rawValue) ?? .unknown
    }
}

/// One row of the activity log, as reported by the Atlas sidecar.
struct AtlasActivityEvent: Decodable, Identifiable, Equatable, Sendable {
    let id: Int
    let ts: Date
    let sessionID: String?
    let source: String
    let toolName: String
    let summary: String
    let ruleID: String?
    let outcome: AtlasOutcome
    let durationMs: Int?

    // The decoder's `.convertFromSnakeCase` yields `sessionId` / `ruleId`, so
    // the acronym properties need their converted spelling as the key.
    private enum CodingKeys: String, CodingKey {
        case id, ts, source, summary, outcome
        case sessionID = "sessionId"
        case toolName
        case ruleID = "ruleId"
        case durationMs
    }
}

/// One page of activity events, plus the cursor for the next (older) page.
struct AtlasActivityPage: Decodable, Equatable, Sendable {
    let events: [AtlasActivityEvent]
    let nextBefore: Int?
}

/// One entry in the sidecar's ruleset.
struct AtlasRule: Decodable, Equatable, Sendable {
    let id: String
    let action: String
    let description: String
}

/// The sidecar's current ruleset, or a reason it could not be read
/// (`rules_error` on the sidecar's own `/health`).
struct AtlasRulesSnapshot: Decodable, Equatable, Sendable {
    let rules: [AtlasRule]
    let error: String?
}

/// The decoder the Atlas sidecar JSON is decoded with.
///
/// The shared `APIClient` decoder is snake_case-only, but the sidecar reports
/// `ts` as an ISO-8601 UTC string with a `Z` suffix, which the client's
/// decoder cannot parse (its Date fields elsewhere are unix epoch doubles).
/// This decoder adds that one strategy so the models also decode in unit tests
/// without a running server.
enum AtlasActivityTimestampFormatter {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)

            // The sidecar reports e.g. "2026-10-02T17:08:14Z".
            if let date = Self.iso8601Formatter.date(from: rawValue) {
                return date
            }

            // Tolerate epoch doubles from an older/newer sidecar.
            if let epoch = Double(rawValue) {
                return Date(timeIntervalSince1970: epoch)
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized timestamp: \(rawValue)"
            )
        }
        return decoder
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
