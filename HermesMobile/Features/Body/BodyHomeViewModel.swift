import Foundation
import Observation

private func bodyIsCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
}

/// Body home: the next workout, the week, last night's sleep, the lifts, recent sessions, and
/// Baki's pending proposals.
@MainActor
@Observable
final class BodyHomeViewModel {
    private(set) var state: BrainLoadState<BodyHome> = .loading
    /// Why the last Accept or Skip didn't take; cleared by the next decision or a load.
    private(set) var decideError: String?
    /// Proposal ids with a decision in flight; further taps on them are ignored.
    private(set) var deciding: Set<String> = []

    @ObservationIgnored private let client: BodyDataClient
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private var generation = 0

    init(client: BodyDataClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.onAPIError = onAPIError
    }

    /// Loads home. A refresh that fails (other than a 404) keeps what's on screen.
    func load() async {
        generation += 1
        let token = generation
        do {
            let home = try await client.home()
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(home)
        } catch {
            guard token == generation, !bodyIsCancellation(error) else { return }
            onAPIError(error)
            let notFound = (error as? APIError)?.isNotFound ?? false
            if case .loaded = state, !notFound { return }
            state = notFound ? .unavailable : .failed(error.localizedDescription)
        }
    }

    /// Accepts or skips a proposal. It leaves the list at once and comes back where it was if the
    /// server doesn't take the decision; one the server already decided (404, 409) stays gone. An
    /// accepted proposal can change a lift's weight, so a successful accept reloads home.
    func decide(_ proposal: BodyProposal, accept: Bool) async {
        guard case .loaded(let before) = state, !deciding.contains(proposal.id),
              let index = before.proposals.firstIndex(where: { $0.id == proposal.id }) else { return }
        deciding.insert(proposal.id)
        decideError = nil
        replaceProposals(before.proposals.filter { $0.id != proposal.id })
        defer { deciding.remove(proposal.id) }
        do {
            _ = try await client.decide(proposalID: proposal.id, accept: accept)
        } catch {
            if BodyProposal.isAlreadyDecided(error) { return }
            // Roll back even when cancelled, so a dismissed screen never loses the proposal.
            if !bodyIsCancellation(error) {
                onAPIError(error)
                decideError = "Couldn't save that. Try again."
            }
            restore(proposal, at: index)
            return
        }
        if accept { await load() }
    }

    private func replaceProposals(_ proposals: [BodyProposal]) {
        guard case .loaded(let home) = state else { return }
        state = .loaded(home.with(proposals: proposals))
    }

    private func restore(_ proposal: BodyProposal, at index: Int) {
        guard case .loaded(let home) = state, !home.proposals.contains(where: { $0.id == proposal.id }) else { return }
        var proposals = home.proposals
        proposals.insert(proposal, at: min(index, proposals.count))
        state = .loaded(home.with(proposals: proposals))
    }
}

extension BodyHome {
    init(phase: String, phaseLabel: String, starts: String?, next: BodyNext?, week: BodyWeek, sleep: BodyHomeSleep?,
         lifts: [BodyHomeLift], sessions: [BodySessionSummary], proposals: [BodyProposal], gaps: [String]) {
        self.phase = phase
        self.phaseLabel = phaseLabel
        self.starts = starts
        self.next = next
        self.week = week
        self.sleep = sleep
        self.lifts = lifts
        self.sessions = sessions
        self.proposals = proposals
        self.gaps = gaps
    }

    /// This home with `proposals` swapped in.
    func with(proposals: [BodyProposal]) -> BodyHome {
        BodyHome(phase: phase, phaseLabel: phaseLabel, starts: starts, next: next, week: week, sleep: sleep,
                 lifts: lifts, sessions: sessions, proposals: proposals, gaps: gaps)
    }
}

/// The words and numbers Body home composes from the server's values.
enum BodyHomeCopy {
    /// "Last night · 7h 12m"; just "Last night" when Garmin sent no hours.
    static func sleepTitle(hours: Double?) -> String {
        guard let hours else { return "Last night" }
        let minutes = Int((hours * 60).rounded())
        return "Last night · \(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }

    /// "Rated 4 · 10:48 → 6:05", leaving out whatever Garmin didn't send; nil when it sent none of it.
    static func sleepDetail(_ sleep: BodyHomeSleep) -> String? {
        var parts: [String] = []
        if let quality = sleep.quality { parts.append("Rated \(quality)") }
        if let bed = clock(sleep.bed), let wake = clock(sleep.wake) { parts.append("\(bed) → \(wake)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "2026-11-29T23:10" reads "11:10", the 12-hour clock without am/pm.
    static func clock(_ iso: String?) -> String? {
        guard let iso, let time = iso.split(separator: "T").last, iso.contains("T") else { return nil }
        let parts = time.split(separator: ":")
        guard parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return "\(hour % 12 == 0 ? 12 : hour % 12):\(String(format: "%02d", minute))"
    }

    /// "2026-11-27" reads "Fri, Nov 27"; the input unchanged when it isn't a date.
    static func sessionDate(_ iso: String) -> String {
        guard let date = parser.date(from: iso) else { return iso }
        return display.string(from: date)
    }

    /// "Fri, Nov 27 · 52 min · one set dropped".
    static func sessionSubtitle(_ session: BodySessionSummary) -> String {
        var parts = [sessionDate(session.date)]
        if let minutes = session.minutes { parts.append("\(minutes) min") }
        if session.trimmed { parts.append("one set dropped") }
        return parts.joined(separator: " · ")
    }

    /// The weekday names for the done days of a Monday-first week row: "Monday and Wednesday",
    /// or "none yet this week". What VoiceOver reads in place of the dots.
    static func doneDays(_ states: [BodyDayState]) -> String {
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        let done = states.prefix(7).enumerated().filter { $0.element == .done }.map { names[$0.offset] }
        return done.isEmpty ? "none yet this week" : ListFormatter.localizedString(byJoining: done)
    }

    /// The labels of the workouts finished this week, in day order: "Push, Legs"; nil when none.
    static func liftedLabels(week: BodyWeek, sessions: [BodySessionSummary]) -> String? {
        let labels = week.days.compactMap { day in sessions.first { $0.date == day }?.label }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    /// What a lift row says for VoiceOver, since its dots are drawn: "Incline bench, 150 lb, up from
    /// 145 lb. Last time 4 of 4 sets hit the top of the range."
    static func liftSummary(_ lift: BodyHomeLift) -> String {
        var parts = [lift.name, lift.weightLabel]
        if lift.up { parts.append(lift.upFromLabel.map { "up from \($0)" } ?? "going up") }
        var text = parts.joined(separator: ", ")
        if !lift.dots.isEmpty {
            let hit = lift.dots.filter { $0 }.count
            text += lift.goalReps == nil
                ? ". Last time \(hit) of \(lift.dots.count) sets hit the top of the range"
                : ". Last time \(hit) of \(lift.dots.count) sets at goal"
        }
        return text
    }

    /// "Goal 8·7·6·6" for a lift measured against a rep goal.
    static func goalLabel(_ reps: [Int]) -> String {
        "Goal " + reps.map(String.init).joined(separator: "·")
    }

    /// The other days of the Push/Legs/Pull rotation for the Other day menu, leaving out any already
    /// finished `today` ("2026-11-30"): the server would answer a second one with 409.
    static func otherDays(than day: String, sessions: [BodySessionSummary] = [], today: String = "") -> [String] {
        let finishedToday = Set(sessions.filter { $0.date == today }.map(\.day))
        return ["push", "legs", "pull"].filter { $0 != day && !finishedToday.contains($0) }
    }

    /// The phone's calendar day as the server writes dates, "2026-11-30".
    static func localDay(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// What VoiceOver reads for a week row's dots: the done days, then the row's subtitle
    /// ("Monday and Wednesday. Push, Legs").
    static func weekValue(_ states: [BodyDayState], subtitle: String?) -> String {
        [doneDays(states), subtitle].compactMap { $0 }.joined(separator: ". ")
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f
    }()
}
