import Foundation
import Observation

/// Drawer › Feedback: every entry on the active server, grouped for review. Live only,
/// no cache. Decisions wait for the server and swap in the entry it returns.
@MainActor
@Observable
final class FeedbackInboxViewModel {
    struct InboxSection: Equatable {
        let group: FeedbackGroup
        let entries: [FeedbackEntry]
    }

    /// Section order on screen.
    static let groupOrder: [FeedbackGroup] = [.needsReview, .inProgress, .done]

    private(set) var state: BrainLoadState<[FeedbackGroup: [FeedbackEntry]]> = .loading
    /// The last decision's failure, shown until `clearError()`.
    private(set) var error: String?
    /// The entry whose decision is in flight. One decision at a time.
    private(set) var pendingID: String?

    @ObservationIgnored private let client: any FeedbackDataClient
    @ObservationIgnored private var generation = 0

    init(client: any FeedbackDataClient) {
        self.client = client
    }

    /// The non-empty groups in screen order.
    var sections: [InboxSection] {
        guard case .loaded(let groups) = state else { return [] }
        return Self.groupOrder.compactMap { group in
            guard let entries = groups[group], !entries.isEmpty else { return nil }
            return InboxSection(group: group, entries: entries)
        }
    }

    func entry(id: String) -> FeedbackEntry? {
        guard case .loaded(let groups) = state else { return nil }
        return groups.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    /// The row's secondary text. An entry merged into another entry's plan names that entry
    /// instead of "Rejected", e.g. "Daily Deck · Merged into Fix the question".
    func metaLine(for entry: FeedbackEntry) -> String {
        guard entry.isMerged, let mainID = entry.mergedInto else { return entry.metaLine }
        return entry.metaLine(status: "Merged into " + (self.entry(id: mainID)?.headline ?? "another note"))
    }

    /// The entry a tap opens: for a merged entry, the entry whose plan covers it when that is
    /// loaded; otherwise the entry itself.
    func openedID(for entry: FeedbackEntry) -> String {
        guard entry.isMerged, let mainID = entry.mergedInto, self.entry(id: mainID) != nil else { return entry.id }
        return mainID
    }

    /// The loaded entries merged into `id`'s plan, oldest first. Each can be unmerged.
    func mergedNotes(into id: String) -> [FeedbackEntry] {
        guard case .loaded(let groups) = state else { return [] }
        return (groups[.done] ?? [])
            .filter { $0.isMerged && $0.mergedInto == id }
            .sorted { ($0.ts ?? "") < ($1.ts ?? "") }
    }

    func load() async {
        generation += 1
        let token = generation
        do {
            let entries = try await client.list()
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(Self.grouped(entries))
        } catch {
            guard token == generation, !Self.isCancellation(error) else { return }
            state = Self.isNotFound(error) ? .unavailable : .failed(error.localizedDescription)
        }
    }

    /// Posts a decision. On success the server's folded entry replaces the row; a 409
    /// means the entry moved on, so the inbox reloads. A reply needs a note.
    func decide(_ entry: FeedbackEntry, _ decision: FeedbackDecision) async {
        guard pendingID == nil else { return }
        var decision = decision
        if case .reply(let note) = decision {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                error = "Write a reply first."
                return
            }
            decision = .reply(trimmed)
        }
        pendingID = entry.id
        error = nil
        defer { pendingID = nil }
        do {
            let updated = try await client.decide(id: entry.id, decision)
            replace(entry.id, with: updated)
        } catch let APIError.http(statusCode, _) where statusCode == 409 {
            error = "This changed on the server. Showing the latest."
            await load()
        } catch {
            guard !Self.isCancellation(error) else { return }
            self.error = "Couldn't save that. Try again."
        }
    }

    func clearError() {
        error = nil
    }

    /// The entry's plan. A 404 means no plan has been written yet.
    func plan(for entry: FeedbackEntry) async -> BrainLoadState<FeedbackPlan> {
        do {
            return .loaded(try await client.plan(id: entry.id))
        } catch {
            return Self.isNotFound(error) ? .unavailable : .failed(error.localizedDescription)
        }
    }

    private func replace(_ id: String, with updated: FeedbackEntry) {
        guard case .loaded(let groups) = state else { return }
        var entries = groups.values.flatMap { $0 }.filter { $0.id != id }
        entries.append(updated)
        state = .loaded(Self.grouped(entries))
    }

    /// Groups by status, newest first within each group.
    static func grouped(_ entries: [FeedbackEntry]) -> [FeedbackGroup: [FeedbackEntry]] {
        // `ts` is ISO-8601 with the server's local offset, so string order is time order except
        // across a DST change, where it can be off by up to an hour. Good enough for an inbox.
        let newestFirst = entries.sorted { ($0.ts ?? "") > ($1.ts ?? "") }
        return Dictionary(grouping: newestFirst, by: \.status.group)
    }

    private static func isNotFound(_ error: Error) -> Bool {
        if case APIError.http(let statusCode, _) = error { return statusCode == 404 }
        return false
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

extension FeedbackGroup {
    /// The inbox section header.
    var title: String {
        switch self {
        case .needsReview: "Needs you"
        case .inProgress: "In progress"
        case .done: "Done"
        }
    }
}

extension FeedbackStatus {
    /// Whether the user has a decision to make: planned (approve, reply, reject),
    /// ready (mark merged, reject) or failed (retry, reject).
    var hasDecisions: Bool {
        self == .planned || self == .ready || self == .failed
    }

    /// Whether Reject is one of those decisions; it is for every status that has any.
    var canReject: Bool { hasDecisions }

    /// What the detail's Plan block says when there is no plan to show.
    var noPlanText: String {
        self == .failed ? "No plan. Retry to try again, or reject it." : "No plan yet. One comes back tonight."
    }
}

extension FeedbackEntry {
    /// The row's first line: the plan's title, else the first line of what was sent.
    var headline: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        let firstLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return firstLine ?? "Untitled"
    }

    /// What a Needs you card asks of the user, as its chip: questions to answer, a plan to
    /// approve, a branch to merge, or a failure to retry.
    var needsYouChip: (symbol: String, label: String) {
        switch status {
        case .ready: ("arrow.triangle.branch", "Branch ready")
        case .failed: ("exclamationmark.triangle", "Failed")
        default:
            questionCount > 0
                ? ("questionmark.circle", questionCount == 1 ? "1 question" : "\(questionCount) questions")
                : ("checkmark", "Ready to approve")
        }
    }

    /// An In progress row's status in one word.
    var progressWord: String {
        switch status {
        case .new: "Tonight"
        case .planning: "Planning"
        case .approved: "Approved"
        case .building: "Building"
        default: status.label
        }
    }

    /// The detail's line under the title, e.g. "Daily Deck · small change · second-brain".
    var detailMetaLine: String {
        let size: String? = switch self.size {
        case "S": "small change"
        case "M": "medium change"
        case "L": "large change"
        default: nil
        }
        return [feature, size, planRepo]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The row's secondary text, e.g. "Prep · Plan ready · S".
    var metaLine: String { metaLine(status: status.label) }

    func metaLine(status: String) -> String {
        [feature, status, size ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
