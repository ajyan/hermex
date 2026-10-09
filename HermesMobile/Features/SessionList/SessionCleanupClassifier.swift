import Foundation

/// Which bucket a session falls into for the "Clean up old conversations" flow.
///
/// - ``auto``: a plain conversational thread idle for long enough — safe to
///   archive without asking.
/// - ``project``: a coding project. Mirrors the webui rule: these verify the
///   work is done before archiving, so we present them for explicit
///   confirmation instead of auto-archiving.
enum SessionCleanupKind {
    case auto
    case project
}

/// Pure, testable heuristics for the conversation-cleanup flow. Kept free of
/// any networking/UI so the classification logic can be unit-tested in
/// isolation (see `SessionCleanupClassifierTests`).
enum SessionCleanupClassifier {

    /// A session is "old enough" to be cleanup-eligible when its most recent
    /// meaningful activity is at least `idleDays` days before `now`.
    static func isOldEnough(
        _ session: SessionSummary,
        idleDays: Int,
        now: Date = Date()
    ) -> Bool {
        let threshold = Date(timeIntervalSinceNow: -Double(idleDays) * 86_400)
        let last = session.lastMessageAt ?? session.updatedAt ?? session.createdAt
        guard let last else { return false }
        return Date(timeIntervalSince1970: last) <= threshold
    }

    /// Heuristic for a coding project, mirroring the webui regex. Uses the
    /// workspace path, worktree path, and an explicit project id. Requires a
    /// real file/path signal — the bare word "code" is not enough.
    static func isCodingProjectSession(_ session: SessionSummary) -> SessionCleanupKind {
        if let projectId = session.projectId, !projectId.isEmpty {
            return .project
        }
        let paths = [session.workspace, session.worktreePath]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let pattern = #"\/code\/|\/src\/|\/repo|\.git|node_modules|\/projects?\/"#
        if paths.contains(where: { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }) {
            return .project
        }
        return .auto
    }
}
