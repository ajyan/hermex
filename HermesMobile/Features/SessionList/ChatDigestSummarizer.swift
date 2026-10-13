import Foundation

/// Why a digest run did not complete; the chat is then left unarchived.
enum ChatDigestError: LocalizedError, Equatable {
    case notStarted(serverMessage: String?)
    case runFailed
    case timedOut

    var errorDescription: String? {
        if case .notStarted(let serverMessage?) = self, !serverMessage.isEmpty {
            return serverMessage
        }
        return String(localized: "The summary did not finish, so the chat was not archived.")
    }
}

/// Sends the digest prompt into a chat and waits for that run to end, without
/// a chat screen open. It starts the turn through `/api/chat/start` (as the
/// Daily Deck does) and then polls `/api/chat/stream/status` until the stream
/// is no longer active, reading the run journal's `terminal_state` through the
/// same mapping the Live Activity reconciler uses. A run that is still going
/// at `timeout` is cancelled so it never lingers behind an unarchived chat.
struct ChatDigestSummarizer {
    /// The digest request for a chat archived on `date` (the user's day). The date and the
    /// vault path are spelled out because the turn may run in another workspace, and working
    /// out "today" costs the agent a tool call.
    static func prompt(on date: Date, calendar: Calendar = .current) -> String {
        let day = DailyDeckPaths.day(date, calendar: calendar)
        return """
        Before this chat is archived, write a short digest of it to \
        ~/Code/second-brain/notes/chat-digests/\(day)-<short-slug>.md (today is \(day)), using these sections \
        with a few brief bullets each, or "None":

        ## About
        ## Decisions
        ## Follow-ups
        ## People

        Then, only for people named in this chat who already have a file in \
        ~/Code/second-brain/crm/contacts, add a dated one-line note to that file. Reply with just the digest's path.
        """
    }

    /// Chats shorter than this are archived without a digest.
    static let minimumMessagesForDigest = 2

    static func needsDigest(_ session: SessionSummary) -> Bool {
        (session.messageCount ?? 0) >= minimumMessagesForDigest
    }

    let client: APIClient
    var pollInterval: Duration = .seconds(3)
    var timeout: Duration = .seconds(300)
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var now: @Sendable () -> Date = { Date() }

    func summarize(_ session: SessionSummary) async throws {
        guard let sessionID = session.sessionId, !sessionID.isEmpty else {
            throw ChatDigestError.notStarted(serverMessage: nil)
        }
        let response = try await client.startChat(
            sessionID: sessionID,
            message: Self.prompt(on: now()),
            workspace: session.workspace,
            model: nil,
            profile: session.profile
        )
        guard let streamID = response.streamId, !streamID.isEmpty else {
            throw ChatDigestError.notStarted(serverMessage: response.error)
        }
        try await waitForRun(streamID: streamID)
    }

    private func waitForRun(streamID: String) async throws {
        let polls = max(1, Int(timeout / pollInterval))
        for _ in 0..<polls {
            try await sleep(pollInterval)
            try Task.checkCancellation()
            // A failed probe (tunnel hiccup, backgrounding) just waits for the next one.
            guard let status = try? await client.chatStreamStatus(streamID: streamID),
                  status.active == false
            else { continue }
            let outcome = LiveActivityReconciler.reconciledOutcome(forTerminalState: status.journal?.terminalState)
            guard outcome.status == .complete else { throw ChatDigestError.runFailed }
            return
        }
        _ = try? await client.cancelChat(streamID: streamID)
        throw ChatDigestError.timedOut
    }
}
