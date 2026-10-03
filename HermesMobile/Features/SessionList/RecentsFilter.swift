import Foundation

/// The drawer's recents filter. Every session has exactly one kind; `all`
/// shows every kind. Search ignores the filter (see `SessionListViewModel`).
enum RecentsFilter: String, CaseIterable, Hashable {
    case all
    case hermes
    case claudeCode
    case cli
    case messaging
    case scheduled

    /// The session's kind, never `.all`. Earlier checks win: a cron row that
    /// also carries an import marker is Scheduled.
    static func kind(of session: SessionSummary) -> RecentsFilter {
        if session.isCronSession { return .scheduled }
        if session.isClaudeCodeSession { return .claudeCode }
        if session.isMessagingSession { return .messaging }
        if session.requiresExternalImport { return .cli }
        return .hermes
    }

    func includes(_ session: SessionSummary) -> Bool {
        self == .all || Self.kind(of: session) == self
    }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .hermes: String(localized: "Hermes")
        case .claudeCode: String(localized: "Claude Code")
        case .cli: String(localized: "CLI")
        case .messaging: String(localized: "Messaging")
        case .scheduled: String(localized: "Scheduled")
        }
    }

    /// All and Hermes always, then the import kinds present in `sessions`.
    static func available(in sessions: [SessionSummary]) -> [RecentsFilter] {
        let present = Set(sessions.map(kind(of:)))
        return [.all, .hermes] + allCases.filter { $0 != .all && $0 != .hermes && present.contains($0) }
    }

    /// Keeps `selected` while it is offered, otherwise falls back to Hermes.
    static func resolved(_ selected: RecentsFilter, available: [RecentsFilter]) -> RecentsFilter {
        available.contains(selected) ? selected : .hermes
    }
}
