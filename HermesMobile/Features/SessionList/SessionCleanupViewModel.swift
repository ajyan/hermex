import Foundation
import Observation

/// Drives the "Clean up old conversations" sheet.
///
/// Two buckets, mirroring the webui rule:
/// 1. **Auto** — plain conversational threads idle for `idleDays`+ days are
///    archived directly (no per-row confirmation).
/// 2. **Project** — coding projects that look stale are presented with a
///    checkbox so Andrew can verify the work is done before each is archived.
///
/// The sheet holds a ``SessionCleanupViewModel`` in `@State` so its loaded
/// candidates survive across SwiftUI body re-evaluations.
@MainActor
@Observable
final class SessionCleanupViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case running
        case done(archived: Int, failed: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var autoCandidates: [SessionSummary] = []
    private(set) var projectCandidates: [SessionSummary] = []
    /// Project ids the user ticked for archiving (confirm-before-archive).
    var confirmedProjectIDs: Set<String> = []

    let idleDays: Int
    private let server: URL
    private let client: APIClient
    private let onAPIError: (Error) -> Void

    /// ids archived in the most recent run, for Undo.
    private(set) var lastArchivedIDs: [String] = []

    init(
        server: URL,
        idleDays: Int = 30,
        client: APIClient? = nil,
        onAPIError: @escaping (Error) -> Void
    ) {
        self.server = server
        self.idleDays = idleDays
        self.client = client ?? APIClient(baseURL: server)
        self.onAPIError = onAPIError
    }

    var totalToArchive: Int {
        autoCandidates.count + projectCandidates.filter { confirmedProjectIDs.contains($0.id) }.count
    }

    /// Fetch the visible session list and split it into the two buckets.
    func fetchAndClassify() async {
        phase = .loading
        do {
            let response = try await client.sessions()
            let now = Date()
            let stale = (response.sessions ?? []).filter { session in
                (session.archived ?? false) == false
                && SessionCleanupClassifier.isOldEnough(session, idleDays: idleDays, now: now)
            }
            autoCandidates = stale.filter { SessionCleanupClassifier.isCodingProjectSession($0) == .auto }
            projectCandidates = stale.filter { SessionCleanupClassifier.isCodingProjectSession($0) == .project }
            confirmedProjectIDs = []
            phase = .ready
        } catch {
            onAPIError(error)
            phase = .failed(error.localizedDescription)
        }
    }

    /// Archive every auto candidate plus every confirmed project candidate.
    func run() async {
        let targets = autoCandidates
            + projectCandidates.filter { confirmedProjectIDs.contains($0.id) }
        guard !targets.isEmpty else {
            phase = .done(archived: 0, failed: 0)
            return
        }
        phase = .running
        var archived = 0
        var failed = 0
        var okIDs: [String] = []
        for session in targets {
            do {
                _ = try await client.archiveSession(id: session.id, archived: true)
                archived += 1
                okIDs.append(session.id)
            } catch {
                failed += 1
                onAPIError(error)
            }
        }
        lastArchivedIDs = okIDs
        phase = .done(archived: archived, failed: failed)
    }

    /// Re-open everything archived in the most recent run.
    func undo() async {
        guard !lastArchivedIDs.isEmpty else { return }
        phase = .running
        for id in lastArchivedIDs {
            do {
                _ = try await client.archiveSession(id: id, archived: false)
            } catch {
                onAPIError(error)
            }
        }
        lastArchivedIDs = []
        phase = .idle
    }
}
