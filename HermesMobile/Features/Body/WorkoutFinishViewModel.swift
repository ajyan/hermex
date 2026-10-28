import Foundation
import Observation

/// The finish screen (board 7): the how-was-it check, then Baki's note and any new proposals.
/// It saves through `WorkoutViewModel.finish`, which sends the last sets first, and re-reads the
/// session until the coach note has been written.
@MainActor
@Observable
final class WorkoutFinishViewModel {
    /// Asking the check questions, finishing on the server, or finished and waiting for Baki.
    enum Phase: Equatable { case asking, saving, saved }

    var effort: BodyEffort = .solid
    var back: BodyCondition = .fine
    var shoulders: BodyCondition = .fine
    /// The 0 to 10 pain score and the lift it hurt on; only sent while Lower back or Shoulder
    /// blades reads Pain.
    var painScore: Int?
    var painLift: String?
    var note = ""

    private(set) var phase: Phase = .asking
    private(set) var saveError: String?
    /// Baki's note, once the server has written it.
    private(set) var coachNote: BodyCoachNote?
    /// New proposals the rules raised when the workout finished, until decided.
    private(set) var proposals: [BodyProposal] = []
    private(set) var decideError: String?
    private(set) var deciding: Set<String> = []
    /// The workout as the server closed it, with its start and finish stamps; the summary's
    /// minutes come from it. The live session never carries `started`.
    private(set) var finishedSession: BodySession?

    @ObservationIgnored private let workout: WorkoutViewModel
    @ObservationIgnored private let client: BodyDataClient
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private var finishedID: String?

    init(workout: WorkoutViewModel, client: BodyDataClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.workout = workout
        self.client = client
        self.onAPIError = onAPIError
    }

    var day: String { workout.session?.day ?? workout.day ?? "" }

    /// The lifts the pain can be pinned on: this session's work lifts, not the warm-up.
    var painLifts: [BodyExercise] {
        (workout.session?.exercises ?? []).filter { $0.section != .warmup }
    }

    var asksPain: Bool { back == .pain || shoulders == .pain }

    /// Pain needs a score and a lift before the workout can be saved.
    var canSave: Bool {
        phase == .asking && (!asksPain || (painScore != nil && painLift != nil))
    }

    var check: BodyCheck {
        BodyCheck(
            effort: effort, back: back, shoulders: shoulders,
            pain: asksPain ? painScore.flatMap { score in painLift.map { BodyPain(score: score, lift: $0) } } : nil,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "52 min · 11 lifts · 2 went up", from the finished session once saved and from now before.
    var summary: String? {
        guard let session = finishedSession ?? workout.session else { return nil }
        return WorkoutFinishCopy.summary(session, now: Date())
    }

    /// Moves the pain score one step. The first tap from no score starts at 5.
    func stepPain(_ delta: Int) {
        guard let score = painScore else {
            painScore = 5
            return
        }
        painScore = min(max(score + delta, 0), 10)
    }

    /// Finishes the workout. A failure returns to the form with the reason and everything he entered.
    func save() async {
        guard canSave else { return }
        phase = .saving
        saveError = nil
        guard let result = await workout.finish(check: check) else {
            if workout.saveStatus == .finished {
                // Already finished elsewhere: nothing to save, so go on to Baki's note.
                finishedID = workout.session?.id
                saveError = nil
                phase = .saved
                await refreshNote()
                return
            }
            phase = .asking
            saveError = workout.finishError ?? "Couldn't save the workout. Try again."
            return
        }
        finishedID = result.session.id
        finishedSession = result.session
        coachNote = result.session.coachNote
        proposals = result.proposals.filter(\.isPending)
        phase = .saved
    }

    /// Reads the finished session again for Baki's note, which the server writes a little after the
    /// save. A failed read changes nothing; the next appear or pull to refresh tries again.
    func refreshNote() async {
        guard phase == .saved, let id = finishedID else { return }
        guard let session = try? await client.session(id: id), !Task.isCancelled else { return }
        // A workout finished elsewhere (409) has no finish stamp until it is read back.
        if session.finished != nil { finishedSession = session }
        if let note = session.coachNote { coachNote = note }
    }

    /// Accepts or skips a proposal. It leaves the list at once and returns if the server says no.
    func decide(_ proposal: BodyProposal, accept: Bool) async {
        guard let index = proposals.firstIndex(where: { $0.id == proposal.id }),
              !deciding.contains(proposal.id) else { return }
        deciding.insert(proposal.id)
        decideError = nil
        proposals.remove(at: index)
        defer { deciding.remove(proposal.id) }
        do {
            _ = try await client.decide(proposalID: proposal.id, accept: accept)
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                onAPIError(error)
                decideError = "Couldn't save that. Try again."
            }
            if !proposals.contains(where: { $0.id == proposal.id }) {
                proposals.insert(proposal, at: min(index, proposals.count))
            }
        }
    }
}

/// The words the finish screen composes.
enum WorkoutFinishCopy {
    static func title(day: String) -> String { "\(day.capitalized) done" }

    /// "Baki · after Push".
    static func kicker(day: String) -> String { "Baki · after \(day.capitalized)" }

    /// "52 min · 11 lifts · 2 went up". Minutes run from the start to `finished`, or to `now` while
    /// he is still on the check; they're left out when the session has no readable start.
    static func summary(_ session: BodySession, finished: String? = nil, now: Date) -> String {
        let done = session.exercises.filter { $0.section != .warmup && $0.sets.contains(where: \.done) }
        var parts: [String] = []
        if let start = session.started.flatMap(date) {
            let end = (finished ?? session.finished).flatMap(date) ?? now
            let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
            if minutes >= 0 { parts.append("\(minutes) min") }
        }
        parts.append(done.count == 1 ? "1 lift" : "\(done.count) lifts")
        parts.append("\(done.filter(\.up).count) went up")
        return parts.joined(separator: " · ")
    }

    /// The server's naive local timestamp, "2026-11-23T07:52:00".
    private static func date(_ stamp: String) -> Date? {
        stampFormatter.date(from: String(stamp.prefix(19)))
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()
}
