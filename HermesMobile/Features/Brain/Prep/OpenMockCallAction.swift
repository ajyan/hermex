import SwiftUI

/// Opens a voice mock from Prep: a new chat in the mock's profile, already in a call, with the brief
/// as its opening turn. A reference, like `OpenDraftChatAction`: the shell keeps one instance and
/// refreshes `handler`, so readers never see a new value. The handler returns once the chat is open.
final class OpenMockCallAction {
    var handler: (@MainActor (PrepMockStart) async -> Void)?

    /// True when a shell is listening; without one, Start call hides.
    var isAvailable: Bool { handler != nil }

    @MainActor
    func callAsFunction(_ start: PrepMockStart) async { await handler?(start) }
}

struct OpenMockCallKey: EnvironmentKey {
    static let defaultValue = OpenMockCallAction()
}

extension EnvironmentValues {
    var openMockCall: OpenMockCallAction {
        get { self[OpenMockCallKey.self] }
        set { self[OpenMockCallKey.self] = newValue }
    }
}

/// A finished mock call, ready for `POST /api/tutor/mock/grade`.
struct MockCallGrade: Equatable, Sendable {
    let mockID: String
    let sessionID: String
    let turnMS: [Int]

    func post(to client: PrepDataClient) async throws {
        try await client.mockGrade(mockID: mockID, sessionID: sessionID, turnMS: turnMS)
    }
}

/// A chat opened for a voice mock: its first call opens with the brief, and when that call ends the
/// grade is asked for once. Later calls on the same chat are ordinary calls. A chat that isn't a mock
/// has neither and never asks.
struct MockCallState: Equatable {
    private(set) var mockID: String?
    /// The brief, until the mock's call has ended.
    private(set) var openingTurn: String?

    init(mockID: String?, openingTurn: String?) {
        self.mockID = mockID
        self.openingTurn = openingTurn
    }

    /// Ends the mock's call: the grade to ask for, only with a mock id and a session, and only once.
    mutating func callEnded(sessionID: String?, turnMS: [Int]) -> MockCallGrade? {
        defer {
            mockID = nil
            openingTurn = nil
        }
        let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let mockID, !sessionID.isEmpty else { return nil }
        return MockCallGrade(mockID: mockID, sessionID: sessionID, turnMS: turnMS)
    }
}

/// The Hermes profile around a voice mock. The server scopes a session to the profile the client's
/// `hermes_profile` cookie names (`POST /api/profile/switch`), and `/api/chat/start` on an interviewer
/// session answers 409 `session_profile_mismatch` without it. So the interviewer profile goes active
/// before the mock's chat exists (its opening turn goes out as soon as the call connects, ahead of the
/// chat's own profile check), and the profile that was active before comes back when the call ends.
enum PrepMockProfile {
    /// Makes `profile` active and returns the profile to switch back to afterwards, or nil when there
    /// is none. That is the server's active profile, or `fallback` (the app's own idea of it, the
    /// drawer's profile) when the server can't say or is somehow already on `profile`. A failed switch
    /// still returns it: the chat's own check may switch later, and switching back is harmless.
    static func enter(_ profile: String, fallback: String? = nil, client: APIClient) async -> String? {
        let current = (try? await client.profiles().effectiveDefaultProfileName) ?? fallback
        if current != profile {
            _ = try? await client.switchProfile(name: profile)
        }
        let previous = current == profile ? fallback : current
        guard let previous, !previous.isEmpty, previous != profile else { return nil }
        return previous
    }

    /// Switches back to `previous`; quiet on failure (the next chat opened in it switches too).
    static func leave(to previous: String?, client: APIClient) async {
        guard let previous, !previous.isEmpty else { return }
        _ = try? await client.switchProfile(name: previous)
    }
}
