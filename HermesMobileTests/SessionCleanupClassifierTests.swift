import XCTest
@testable import HermesMobile

/// Unit tests for `SessionCleanupClassifier.isCodingProjectSession` — the
/// heuristic that decides whether a session is a *coding project* (needs
/// confirmation before archiving) or a plain conversation thread (safe to
/// auto-archive once idle). Mirrors the webui logic, tightened to require a
/// file/path signal (not just the word "code").
final class SessionCleanupClassifierTests: XCTestCase {
    private let old: Double = Date(timeIntervalSinceNow: -40 * 86_400).timeIntervalSince1970
    private let now = Date()

    private func session(_ title: String, workspace: String? = nil, projectId: String? = nil) -> SessionSummary {
        SessionSummary(
            sessionId: "s-\(abs(title.hashValue))",
            title: title,
            workspace: workspace,
            updatedAt: old,
            lastMessageAt: old,
            projectId: projectId
        )
    }

    // MARK: - Auto-archive (plain threads)

    func testPlainConversationIsAuto() {
        XCTAssertEqual(
            SessionCleanupClassifier.isCodingProjectSession(session("help me fix my essay")),
            .auto
        )
    }

    func testWordCodeAloneDoesNotMatchProject() {
        // "code" as a word with no path/file signal must NOT be a project.
        XCTAssertEqual(
            SessionCleanupClassifier.isCodingProjectSession(session("how do i code in swift")),
            .auto
        )
    }

    func testNoWorkspaceNoProjectIdIsAuto() {
        XCTAssertEqual(
            SessionCleanupClassifier.isCodingProjectSession(session("random chatter")),
            .auto
        )
    }

    // MARK: - Project (needs confirmation)

    func testWorkspaceUnderCodeDirIsProject() {
        XCTAssertEqual(
            SessionCleanupClassifier.isCodingProjectSession(session("work", workspace: "~/Code/hermex")),
            .project
        )
    }

    func testWorkspaceUnderSrcDirIsProject() {
        XCTAssertEqual(
            SessionCleanupClassifier.isCodingProjectSession(session("work", workspace: "~/repo/src/main.swift")),
            .project
        )
    }

    func testWorkspaceUnderProjectsDirIsProject() {
        XCTAssertEqual(
            SessionCleanupClassifier.isCodingProjectSession(session("work", workspace: "/Users/andrewjyan/projects/thing")),
            .project
        )
    }

    func testWorktreePathSignalIsProject() {
        XCTAssertEqual(
            SessionCleanupClassifier.isCodingProjectSession(session("work", workspace: nil, projectId: "p-1")),
            .project
        )
    }

    func testNodeModulesSignalIsProject() {
        XCTAssertEqual(
            SessionCleanupClassifier.isCodingProjectSession(session("work", workspace: "/app/node_modules/webpack")),
            .project
        )
    }

    // MARK: - isOldEnough

    func testOldEnoughTrueForStaleSession() {
        let stale = SessionSummary(sessionId: "stale", updatedAt: old, lastMessageAt: old)
        XCTAssertTrue(SessionCleanupClassifier.isOldEnough(stale, idleDays: 30, now: now))
    }

    func testOldEnoughFalseForRecentSession() {
        let recent = SessionSummary(sessionId: "recent", lastMessageAt: Date().timeIntervalSince1970)
        XCTAssertFalse(SessionCleanupClassifier.isOldEnough(recent, idleDays: 30, now: now))
    }

    func testOldEnoughFallsBackToUpdatedAt() {
        // lastMessageAt absent → updatedAt decides.
        let byUpdate = SessionSummary(sessionId: "u", updatedAt: old)
        XCTAssertTrue(SessionCleanupClassifier.isOldEnough(byUpdate, idleDays: 30, now: now))
    }

    func testOldEnoughFalseWhenNoTimestamps() {
        let none = SessionSummary(sessionId: "none")
        XCTAssertFalse(SessionCleanupClassifier.isOldEnough(none, idleDays: 30, now: now))
    }
}
