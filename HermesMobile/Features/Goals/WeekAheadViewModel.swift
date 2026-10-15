import Foundation
import Observation

/// One commitment on a Week ahead card (`commitments`, `last_week`), and the shape
/// `POST /api/goals/week` takes back. `was`, `reason` and `drop` are the proposal's notes
/// (last week's target, why it changed, or why to drop it) and never go to the server.
struct DeckWeekCommitment: Codable, Equatable, Hashable, Sendable {
    let id: String
    let action: String
    var target: Int
    let skips: Int
    /// "day" (checked per day) or "item" (counted by +1).
    let unit: String
    let source: String?
    let cue: String?
    let minimum: String?
    let days: [String]?
    let was: Int?
    let reason: String?
    /// The proposal drops this commitment; its row starts removed.
    let drop: Bool

    private enum CodingKeys: String, CodingKey {
        case id, action, target, skips, unit, source, cue, minimum, days, was, reason, drop
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        action = (try? c.decodeIfPresent(String.self, forKey: .action)) ?? ""
        target = (try? c.decodeIfPresent(Int.self, forKey: .target)) ?? 1
        skips = (try? c.decodeIfPresent(Int.self, forKey: .skips)) ?? 0
        unit = (try? c.decodeIfPresent(String.self, forKey: .unit)) ?? "day"
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        cue = try? c.decodeIfPresent(String.self, forKey: .cue)
        minimum = try? c.decodeIfPresent(String.self, forKey: .minimum)
        days = try? c.decodeIfPresent([String].self, forKey: .days)
        was = try? c.decodeIfPresent(Int.self, forKey: .was)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        drop = (try? c.decodeIfPresent(Bool.self, forKey: .drop)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(action, forKey: .action)
        try c.encode(target, forKey: .target)
        try c.encode(skips, forKey: .skips)
        try c.encode(unit, forKey: .unit)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(cue, forKey: .cue)
        try c.encodeIfPresent(minimum, forKey: .minimum)
        try c.encodeIfPresent(days, forKey: .days)
    }

    var isItem: Bool { unit == "item" }
}

/// One proposed commitment as Andrew edits it: its target, and whether he took it out.
struct WeekAheadRow: Identifiable, Equatable {
    let commitment: DeckWeekCommitment
    var target: Int
    var removed: Bool

    var id: String { commitment.id }

    /// Days a week for a day commitment, a count for an item one.
    var range: ClosedRange<Int> { commitment.isItem ? 1...50 : 1...7 }

    /// "5 → 6" when the target differs from last week's; nil otherwise.
    var change: String? {
        guard let was = commitment.was, was != target else { return nil }
        return "\(was) → \(target)"
    }
}

/// A Week ahead card on the Sunday review deck: next week's proposed commitments for one goal.
/// Keep sends them as edited, Ease off sends last week's plan one lighter, and the card turns
/// Confirmed once the server has the week (now, or from an earlier confirm).
@MainActor
@Observable
final class WeekAheadViewModel {
    enum Phase: Equatable {
        case editing, saving, confirmed
        case failed(String)
    }

    static let conflictCopy = "This week has started; the plan carried forward."
    static let failureCopy = "Couldn't save. Try again."

    var rows: [WeekAheadRow]
    private(set) var phase: Phase = .editing
    /// The server's answer to the confirm, for the deck's goal card to take.
    private(set) var result: GoalCheckInResult?

    let card: DeckCard
    @ObservationIgnored private let client: GoalsDataClient
    /// The server's today, sent as `as_of`; follows the goals home (`sync`) and a 409's reload.
    @ObservationIgnored private(set) var today: String

    init(card: DeckCard, client: GoalsDataClient, today: String) {
        self.card = card
        self.client = client
        self.today = today
        rows = card.weekCommitments.map { WeekAheadRow(commitment: $0, target: $0.target, removed: $0.drop) }
    }

    /// Rows can change, and Keep or Ease off can send: before saving, or after a failure worth retrying.
    var canEdit: Bool { phase == .editing || phase == .failed(Self.failureCopy) }

    /// The proposal as edited: the rows still in, at their targets.
    func keep() async {
        let kept = rows.filter { !$0.removed }.map { row -> DeckWeekCommitment in
            var commitment = row.commitment
            commitment.target = row.target
            return commitment
        }
        guard !kept.isEmpty else { return }
        await save(kept)
    }

    /// Last week's plan, each target one lighter (never below 1).
    func easeOff() async {
        let eased = card.lastWeek.map { last -> DeckWeekCommitment in
            var commitment = last
            commitment.target = max(1, last.target - 1)
            return commitment
        }
        guard !eased.isEmpty else { return }
        await save(eased)
    }

    /// Takes a fresh goals home: its today for the next save, and whether the week is confirmed.
    func sync(_ home: GoalsHome) {
        today = home.today
        markConfirmedIfKnown(home)
    }

    /// Shows the card as confirmed when the server already has its week (confirmed elsewhere,
    /// or before the deck was reopened).
    func markConfirmedIfKnown(_ home: GoalsHome) {
        guard let slug = card.goal, let start = card.start,
              home.goals.first(where: { $0.slug == slug })?.confirmedStarts.contains(start) == true else { return }
        phase = .confirmed
    }

    private func save(_ commitments: [DeckWeekCommitment]) async {
        guard canEdit, let slug = card.goal, let start = card.start else { return }
        phase = .saving
        let asOf = today
        do {
            result = try await client.confirmWeek(GoalWeekRequest(slug: slug, start: start, asOf: asOf,
                                                                  commitments: commitments))
            phase = .confirmed
        } catch {
            if case .http(409, _)? = error as? APIError {
                await recoverFromConflict(sent: asOf, slug: slug, start: start)
            } else {
                phase = .failed(Self.failureCopy)
            }
        }
    }

    /// A 409 means the server's day isn't the one sent, or the week can no longer be planned.
    /// Reloads once: when only the day moved (a deck opened Sunday night, kept on Monday) and the
    /// week is still plannable, editing resumes against the new today; otherwise the card locks.
    private func recoverFromConflict(sent asOf: String, slug: String, start: String) async {
        guard let home = try? await client.home() else {
            phase = .failed(Self.failureCopy)
            return
        }
        today = home.today
        if home.goals.first(where: { $0.slug == slug })?.confirmedStarts.contains(start) == true {
            phase = .confirmed
            return
        }
        let plannable = home.today < start || home.goals.first(where: { $0.slug == slug })?.weekPending != nil
        phase = home.today != asOf && plannable ? .editing : .failed(Self.conflictCopy)
    }

    /// The new chat's draft for Edit in chat: the proposal, then the command that saves it.
    static func chatDraft(card: DeckCard, goalTitle: String) -> String {
        let lines = card.weekCommitments.map { c -> String in
            let reason = c.reason.map { " (\($0))" } ?? ""
            if c.drop { return "- \(c.action): drop\(reason)" }
            let amount = c.isItem ? "\(c.target) this week" : "\(c.target) days"
            let was = c.was.map { ", was \($0)" } ?? ""
            return "- \(c.action) \(amount)\(was)\(reason)"
        }
        return (["Help me adjust next week's plan for \(goalTitle) (week of \(card.start ?? "next Monday")). Atlas proposed:"]
            + lines
            + ["The goal's slug is \(card.goal ?? card.id).",
               "Use `tools/.venv/bin/python tools/goals.py confirm-week`."])
            .joined(separator: "\n")
    }

    /// The goal's name: the server's when known, else the card title's after "Next week · ".
    static func goalTitle(card: DeckCard, home: GoalsHome?) -> String {
        if let title = home?.goals.first(where: { $0.slug == card.goal })?.title, !title.isEmpty { return title }
        if let title = card.title, let range = title.range(of: " · ") { return String(title[range.upperBound...]) }
        return card.title ?? card.goal ?? "this goal"
    }
}
