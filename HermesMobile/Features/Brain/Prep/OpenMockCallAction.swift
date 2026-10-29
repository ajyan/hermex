import CryptoKit
import SwiftUI

/// Opens a voice mock from Prep: a new chat in the mock's profile, already in a call, with the brief
/// as its opening turn. A reference, like `OpenDraftChatAction`: the shell keeps one instance and
/// refreshes `handler`, so readers never see a new value. The handler gets the mock's start (nil when
/// it failed) and calls it only once the profile is active (`PrepMockCallOpener`); it returns once the
/// chat is open, and throws, having started nothing, when the profile couldn't be made active.
final class OpenMockCallAction {
    typealias Start = @MainActor () async -> PrepMockStart?

    var handler: (@MainActor (@escaping Start) async throws -> Void)?

    /// True when a shell is listening; without one, Start call hides.
    var isAvailable: Bool { handler != nil }

    @MainActor
    func callAsFunction(_ start: @escaping Start) async throws { try await handler?(start) }
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
struct MockCallGrade: Hashable, Sendable {
    let mockID: String
    let sessionID: String
    let turnMS: [Int]

    /// The grade request for a call, asked for only with a session and at least one timed reply: a
    /// call the interviewer never answered has nothing to grade.
    static func of(mockID: String, sessionID: String?, turnMS: [Int]) -> MockCallGrade? {
        let sessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return sessionID.isEmpty || turnMS.isEmpty ? nil : MockCallGrade(mockID: mockID, sessionID: sessionID, turnMS: turnMS)
    }

    func post(to client: PrepDataClient) async throws {
        try await client.mockGrade(mockID: mockID, sessionID: sessionID, turnMS: turnMS)
    }
}

/// The end of a voice mock's call: which mock, and its grade request, or nil when there is nothing
/// to grade (no session, or the interviewer never answered).
struct MockCallEnd: Equatable, Sendable {
    let mockID: String
    let grade: MockCallGrade?
}

/// A chat opened for a voice mock: its first call opens with the brief, and when that call ends it
/// reports the end once. Later calls on the same chat are ordinary calls. A chat that isn't a mock
/// has neither and never reports.
struct MockCallState: Equatable {
    private(set) var mockID: String?
    /// The brief, until the mock's call has ended.
    private(set) var openingTurn: String?

    init(mockID: String?, openingTurn: String?) {
        self.mockID = mockID
        self.openingTurn = openingTurn
    }

    /// Ends the mock's call, once, with its grade request (`MockCallGrade.of`).
    mutating func callEnded(sessionID: String?, turnMS: [Int]) -> MockCallEnd? {
        defer {
            mockID = nil
            openingTurn = nil
        }
        guard let mockID else { return nil }
        return MockCallEnd(mockID: mockID, grade: MockCallGrade.of(mockID: mockID, sessionID: sessionID, turnMS: turnMS))
    }
}

/// UserDefaults keys for a voice mock's per-server state: the prefix and a SHA-256 of the server's
/// registry id (the id is the normalized URL, which stays out of `UserDefaults`).
private func prepMockKey(_ prefix: String, serverID: String) -> String {
    prefix + SHA256.hash(data: Data(serverID.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// The profile to switch back to after a voice mock, saved per configured server so a mock cut
/// short (the app killed mid-call, a failed switch back) still finds its way back on the next
/// launch or foreground. A profile name isn't a credential; the server is named by a hash.
struct PrepMockReturnStore {
    let serverID: String
    var defaults: UserDefaults = .standard

    private var key: String { prepMockKey("prep-mock.return-profile.", serverID: serverID) }

    var profile: String? { defaults.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 } }

    func save(_ profile: String) { defaults.set(profile, forKey: key) }

    func clear() { defaults.removeObject(forKey: key) }
}

/// A voice mock whose call is under way: its id, then its session and the interviewer's turn times as
/// the call goes. Kept per server until the grade is sent, so a mock cut short (the app killed
/// mid-call) is still graded on the next launch or foreground.
struct PrepMockInFlight: Codable, Equatable, Sendable {
    let mockID: String
    var sessionID: String?
    var turnMS: [Int]

    init(mockID: String, sessionID: String? = nil, turnMS: [Int] = []) {
        self.mockID = mockID
        self.sessionID = sessionID
        self.turnMS = turnMS
    }
}

/// The in-flight voice mock, saved per configured server next to `PrepMockReturnStore` and keyed the
/// same way. A mock id, session id and timings aren't credentials.
struct PrepMockInFlightStore {
    let serverID: String
    var defaults: UserDefaults = .standard

    private var key: String { prepMockKey("prep-mock.in-flight.", serverID: serverID) }

    var mock: PrepMockInFlight? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PrepMockInFlight.self, from: $0) }
    }

    func save(_ mock: PrepMockInFlight) {
        if let data = try? JSONEncoder().encode(mock) { defaults.set(data, forKey: key) }
    }

    /// Forgets the saved mock when it is `mockID` (or unreadable), never a newer one.
    func clear(mockID: String) {
        let saved = mock
        if saved == nil || saved?.mockID == mockID { defaults.removeObject(forKey: key) }
    }

    /// Recovery for a mock cut short (spec R31): posts the grade of the saved mock, then forgets it.
    /// A mock with nothing to grade (no session, or the interviewer never answered) or one the
    /// server refuses (4xx) is forgotten; a network failure or a server error keeps it for the next
    /// launch or foreground.
    @MainActor
    func recover(post: @MainActor (MockCallGrade) async throws -> Void) async {
        guard let mock else { return }
        guard let grade = MockCallGrade.of(mockID: mock.mockID, sessionID: mock.sessionID, turnMS: mock.turnMS) else {
            return clear(mockID: mock.mockID)
        }
        do {
            try await post(grade)
            clear(mockID: mock.mockID)
        } catch {
            if case .http(let status, _)? = error as? APIError, (400..<500).contains(status) { clear(mockID: mock.mockID) }
        }
    }
}

/// Why a voice mock couldn't make its profile active.
struct PrepMockProfileError: LocalizedError, Equatable {
    let detail: String
    /// True when the server has no such profile (the switch answered 404).
    var isMissing = false

    /// A server with no interviewer profile.
    static let missing = PrepMockProfileError(detail: "", isMissing: true)

    var errorDescription: String? {
        if isMissing { return PrepMockCopy.noInterviewer }
        return detail.isEmpty
            ? "Couldn't switch to the interviewer profile."
            : "Couldn't switch to the interviewer profile: \(detail)"
    }
}

/// The Hermes profile around a voice mock. The server scopes a session to the profile the client's
/// `hermes_profile` cookie names (`POST /api/profile/switch`), and `/api/chat/start` on an interviewer
/// session answers 409 `session_profile_mismatch` without it. So the interviewer profile goes active
/// before the mock's chat exists (its opening turn goes out as soon as the call connects, ahead of the
/// chat's own profile check), and the profile that was active before comes back when the call ends.
struct PrepMockProfile {
    let client: APIClient
    let store: PrepMockReturnStore

    /// Makes `profile` active, first saving the profile to switch back to: one already saved (a mock
    /// that never got back), else the server's active profile, else `fallback` (the drawer's profile)
    /// when the server can't say or is somehow already on `profile`. Throws when the switch fails or
    /// the server refuses it (`PrepMockProfileError.missing` when it has no such profile); nothing is
    /// then left saved that wasn't before.
    func enter(_ profile: String, fallback: String? = nil) async throws {
        let saved = store.profile
        let current = (try? await client.profiles().effectiveDefaultProfileName) ?? fallback
        if saved == nil, let previous = current == profile ? fallback : current, !previous.isEmpty, previous != profile {
            store.save(previous)
        }
        guard current != profile else { return }
        do {
            let response = try await client.switchProfile(name: profile)
            if let error = response.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                throw PrepMockProfileError(detail: error)
            }
        } catch {
            if saved == nil { store.clear() }
            if (error as? APIError)?.isNotFound == true { throw PrepMockProfileError.missing }
            throw error as? PrepMockProfileError ?? PrepMockProfileError(detail: error.localizedDescription)
        }
    }

    /// Switches back to the saved profile and forgets it, returning true when it switched. A network
    /// failure or a server error keeps it for the next try (launch or foreground); a refusal (4xx, or
    /// an error in the reply) forgets it, since trying again can't help.
    @discardableResult
    func leave() async -> Bool {
        guard let previous = store.profile else { return false }
        do {
            let response = try await client.switchProfile(name: previous)
            store.clear()
            return response.error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        } catch {
            if case .http(let status, _)? = error as? APIError, (400..<500).contains(status) { store.clear() }
            return false
        }
    }
}

/// What the shell does on Start call, in order: make the interviewer profile active, then start the
/// mock (`POST /api/tutor/mock/start`), so a failed switch leaves no started mock behind; switch back
/// when the mock can't start; remember the mock in flight; open its chat.
@MainActor
struct PrepMockCallOpener {
    var enter: @MainActor (String) async throws -> Void
    var leave: @MainActor () async -> Void
    var remember: @MainActor (PrepMockInFlight) -> Void
    var openChat: @MainActor (PrepMockStart) -> Void

    func open(_ start: OpenMockCallAction.Start) async throws {
        try await enter(PrepMockStart.interviewerProfile)
        guard let mock = await start() else { return await leave() }
        if mock.profile != PrepMockStart.interviewerProfile {
            do {
                try await enter(mock.profile)
            } catch {
                await leave()
                throw error
            }
        }
        remember(PrepMockInFlight(mockID: mock.mockID))
        openChat(mock)
    }
}

/// What the shell does when a voice mock's call ends, in order: switch back to the previous profile,
/// ask for the grade (retrying twice), then, if the mock's chat is still on screen, replace it with a
/// fresh chat and show Prep with the mock's result on top, so Back lands in Prep and no interviewer
/// chat stays behind. A grade that never got through rides on the result route, for its Send for
/// grading button. A call with nothing to grade shows Prep home alone. If the user already left the
/// mock's chat, nothing is swapped; only a grade that never got through is pushed, so it isn't lost.
@MainActor
struct PrepMockCallFinisher {
    var leave: @MainActor () async -> Void
    var postGrade: @MainActor (MockCallGrade) async throws -> Void
    /// False once the mock's chat is no longer the shell's root (the user went elsewhere).
    var isStillOnMockChat: @MainActor () -> Bool
    var replaceRoot: @MainActor () -> Void
    /// Replaces whatever is pushed with these screens.
    var show: @MainActor ([PrepRoute]) -> Void
    /// Pushes one screen over whatever is showing.
    var push: @MainActor (PrepRoute) -> Void
    /// Waits before retry `n` (1, 2).
    var pause: @MainActor (Int) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    /// Forgets the in-flight mock once its grade is sent, or when there is nothing to grade. A grade
    /// that never got through stays in flight for the next launch or foreground.
    var forget: @MainActor (String) -> Void = { _ in }

    static let gradeAttempts = 3

    func finish(_ end: MockCallEnd) async {
        await leave()
        var unsent: MockCallGrade?
        if let grade = end.grade, !(await post(grade)) { unsent = grade }
        if unsent == nil { forget(end.mockID) }
        guard isStillOnMockChat() else {
            if let unsent { push(.mockResult(end.mockID, unsent: unsent)) }
            return
        }
        replaceRoot()
        show(end.grade == nil ? [.home] : [.home, .mockResult(end.mockID, unsent: unsent)])
    }

    private func post(_ grade: MockCallGrade) async -> Bool {
        for attempt in 0..<Self.gradeAttempts {
            if attempt > 0 { await pause(attempt) }
            do {
                try await postGrade(grade)
                return true
            } catch {
                if error is CancellationError || Task.isCancelled { return false }
            }
        }
        return false
    }
}
