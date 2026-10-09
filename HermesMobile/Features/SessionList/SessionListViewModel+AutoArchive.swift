import Foundation
import SwiftData

/// Auto-archive and the review flow. One pass runs per server per foreground,
/// after a live list load: throwaway idle chats are archived, chats the keep
/// model scores as worth keeping become `archiveReviewCandidates`. Every user
/// decision trains that server's model.
extension SessionListViewModel {
    func noteAppForegrounded() {
        isAutoArchiveDue = true
    }

    /// Runs the pass if one is due and the list holds live rows. Returns the
    /// chats it archived, for the "Archived N idle chats" toast. A failed load
    /// leaves the pass due, so the next successful load runs it. `now` is the
    /// drawer's "Clean up old chats": it runs regardless, even with auto-archive off.
    func runAutoArchivePassIfDue(
        excludingSessionID excludedSessionID: String?,
        modelContext: ModelContext? = nil,
        now runsNow: Bool = false
    ) async -> [SessionSummary] {
        guard isAutoArchiveDue || runsNow, !isViewingCachedData, !isLoading, sessionLoadError == nil else { return [] }
        isAutoArchiveDue = false

        var settings = autoArchiveStore.settings(for: server)
        if runsNow { settings.isEnabled = true }
        let now = now()
        autoArchiveStore.pruneKept(
            present: Set(sessions.compactMap(\.sessionId)),
            now: now,
            idleInterval: settings.idleInterval,
            for: server
        )
        let plan = AutoArchivePolicy.plan(
            sessions: sessions,
            now: now,
            settings: settings,
            keptAt: autoArchiveStore.keptAt(for: server),
            excludedSessionIDs: excludedSessionID.map { [$0] } ?? [],
            scorer: autoArchiveStore.model(for: server).scorer()
        )
        archiveReviewCandidates = plan.review

        var archived: [SessionSummary] = []
        for session in plan.archive {
            guard !Task.isCancelled else { break }
            guard let sessionID = session.sessionId, beginSessionMutation(sessionID) else { continue }
            do {
                try await sessionMutator.archive(sessionID: sessionID)
                archived.append(session)
                endSessionMutation(sessionID)
            } catch {
                endSessionMutation(sessionID)
                if isCancellationError(error) { break }
                if case APIError.unauthorized = error {
                    lastError = error
                    break
                }
                // One refused chat must not stop the rest; it stays for the next pass.
            }
        }
        if !archived.isEmpty {
            await load(modelContext: modelContext)
        }
        return archived
    }

    /// Restores an auto-archived batch. Each restore teaches the model that
    /// chat was worth keeping and holds it out of the next passes for a full
    /// threshold. Returns false if any restore failed.
    func undoAutoArchive(_ archived: [SessionSummary], modelContext: ModelContext? = nil) async -> Bool {
        var restored: [SessionSummary] = []
        var failure: Error?
        for session in archived {
            guard let sessionID = session.sessionId, beginSessionMutation(sessionID) else { continue }
            do {
                try await sessionMutator.unarchive(sessionID: sessionID)
                restored.append(session)
            } catch {
                if !isCancellationError(error) { failure = error }
            }
            endSessionMutation(sessionID)
        }
        recordDecisions(restored, kept: true, marksKept: true)
        if let failure {
            lastError = failure
            actionErrorMessage = failure.localizedDescription
        }
        if !restored.isEmpty {
            await load(modelContext: modelContext)
        }
        return failure == nil
    }

    func isSummarizing(_ session: SessionSummary) -> Bool {
        guard let sessionID = session.sessionId else { return false }
        return summarizingSessionIDs.contains(sessionID)
    }

    /// Writes a digest of the chat to the second brain, then archives it. The
    /// archive happens only after the run completes; on any failure the chat
    /// stays where it is and the error is returned (not raised as an alert),
    /// so the caller can show it where the user is looking.
    func summarizeAndArchive(_ session: SessionSummary, modelContext: ModelContext? = nil) async -> String? {
        guard let sessionID = session.sessionId, !sessionID.isEmpty else {
            return String(localized: "The server did not provide a session ID.")
        }
        guard beginSessionMutation(sessionID) else { return nil }
        summarizingSessionIDs.insert(sessionID)
        defer {
            summarizingSessionIDs.remove(sessionID)
            endSessionMutation(sessionID)
        }

        do {
            if ChatDigestSummarizer.needsDigest(session) {
                try await digestSummarizer.summarize(session)
            }
            try await sessionMutator.archive(sessionID: sessionID)
        } catch {
            if isCancellationError(error) { return nil }
            if case APIError.unauthorized = error { lastError = error }
            return error.localizedDescription
        }
        recordDecisions([session], kept: true, marksKept: false)
        await load(modelContext: modelContext)
        return nil
    }

    /// Plain archive from the review sheet: a "throw away" decision.
    func archiveFromReview(_ session: SessionSummary, modelContext: ModelContext? = nil) async -> String? {
        guard let sessionID = session.sessionId, beginSessionMutation(sessionID) else { return nil }
        do {
            try await sessionMutator.archive(sessionID: sessionID)
        } catch {
            endSessionMutation(sessionID)
            if isCancellationError(error) { return nil }
            if case APIError.unauthorized = error { lastError = error }
            return error.localizedDescription
        }
        endSessionMutation(sessionID)
        recordDecisions([session], kept: false, marksKept: false)
        await load(modelContext: modelContext)
        return nil
    }

    /// Leaves the chat as it is and stops asking about it until it has been
    /// idle for another full threshold.
    func keepFromReview(_ session: SessionSummary) {
        recordDecisions([session], kept: true, marksKept: true)
    }

    /// A plain Archive from a row's menu or swipe also teaches the model.
    func recordManualArchive(_ session: SessionSummary) {
        recordDecisions([session], kept: false, marksKept: false)
    }

    /// Undo right after a manual archive was a correction, not a judgment.
    func forgetManualArchive(_ session: SessionSummary) {
        guard let sessionID = session.sessionId else { return }
        var model = autoArchiveStore.model(for: server)
        model.forget(sessionID: sessionID)
        autoArchiveStore.setModel(model, for: server)
    }

    func pruneArchiveReviewCandidates(present sessions: [SessionSummary]) {
        guard !archiveReviewCandidates.isEmpty else { return }
        let presentIDs = Set(sessions.compactMap(\.sessionId))
        let pruned = archiveReviewCandidates.filter { presentIDs.contains($0.sessionId ?? "") }
        if pruned.count != archiveReviewCandidates.count {
            archiveReviewCandidates = pruned
        }
    }

    private func recordDecisions(_ decided: [SessionSummary], kept: Bool, marksKept: Bool) {
        guard !decided.isEmpty else { return }
        var model = autoArchiveStore.model(for: server)
        let decidedAt = now()
        for session in decided {
            model.train(session, kept: kept)
            if marksKept, let sessionID = session.sessionId {
                autoArchiveStore.markKept(sessionID, at: decidedAt, for: server)
            }
        }
        autoArchiveStore.setModel(model, for: server)
        let decidedIDs = Set(decided.compactMap(\.sessionId))
        archiveReviewCandidates.removeAll { decidedIDs.contains($0.sessionId ?? "") }
    }
}
