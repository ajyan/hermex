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
    static let groupOrder: [FeedbackGroup] = [.toApprove, .toMerge, .toRetry, .inProgress, .done]

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

    /// Posts a decision. On success the server's folded entry replaces the row. A 409 shows
    /// the server's reason when it gives one ("Not on master yet. …"), else says the entry
    /// moved on, and the inbox reloads. A reply needs a note.
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
        } catch let conflict as APIError where Self.isConflict(conflict) {
            error = conflict.serverMessage ?? "This changed on the server. Showing the latest."
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

    static func isConflict(_ error: Error) -> Bool {
        if case APIError.http(let statusCode, _) = error { return statusCode == 409 }
        return false
    }

    /// The entry's current status a 409 reports: the body's `status`, which the server sends
    /// with every transition conflict, else read from its "cannot go from <status> to …" error.
    static func conflictStatus(_ error: Error) -> FeedbackStatus? {
        guard case APIError.http(409, let body) = error else { return nil }
        if let data = body?.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = object["status"] as? String {
            return FeedbackStatus(wire: status)
        }
        guard let message = (error as? APIError)?.serverMessage,
              let range = message.range(of: "cannot go from ") else { return nil }
        let word = message[range.upperBound...].prefix { !$0.isWhitespace }
        return FeedbackStatus(wire: String(word))
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

extension FeedbackGroup {
    /// The inbox section header.
    var title: String {
        switch self {
        case .toApprove: "Approve to build tonight"
        case .toMerge: "Ready to merge"
        case .toRetry: "Needs a retry"
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

    /// Whether Drop (a `reject` decision) is offered in the detail's action bar: for every
    /// status with decisions, and for a note still waiting for tonight.
    var canReject: Bool { hasDecisions || self == .new }

    /// Whether Undo is offered: a fix the nightly job shipped.
    var canUndo: Bool { self == .shipped }

    /// Whether the detail shows its action bar: the decisions, Drop on a new note, Undo on a
    /// shipped fix, or Redo plan on an undone one.
    var hasActions: Bool { canReject || self == .shipped || self == .reverted }

    /// The Drop confirmation's title and message.
    var rejectConfirmation: (title: String, message: String) {
        switch self {
        case .ready: ("Drop this branch?", "It moves to Done. The branch stays on your Mac until you delete it.")
        case .new: ("Drop this note?", "It moves to Done and won't be planned.")
        default: ("Drop this?", "It moves to Done and won't be built.")
        }
    }

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

    /// The one-line result a request card shows: the plan's `after`, else its summary.
    var outcome: String? {
        [after, summary].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    /// The button on a request card. A plan with questions opens to answer them first, so
    /// nothing gets built on answers the user never saw; a branch opens to its checks.
    enum QuickAction: Equatable {
        case build, answer, review, retry
    }

    var quickAction: QuickAction? {
        switch status {
        case .planned: questionCount > 0 ? .answer : .build
        case .ready: .review
        case .failed: .retry
        default: nil
        }
    }

    /// The ready entry's main button. The server merges a vault or webui branch that isn't on its base
    /// yet; an app fix lands as a PR first; a build with no branch found its fix already on the base.
    var mergeAction: (title: String, caption: String) {
        if branch == nil { return ("Mark done", "Already on main. Moves it to Done.") }
        if repo == "hermex" { return ("I merged it", "Merge the PR and pull master on the Mac first.") }
        return ("Merge it", "Merges the branch on the Mac and moves it to Done.")
    }

    /// A failure's first line, for its card.
    var errorLine: String {
        error?.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "Failed"
    }

    /// The change's size in a word.
    var sizeWord: String? {
        switch size {
        case "S": "Small"
        case "M": "Medium"
        case "L": "Large"
        default: nil
        }
    }

    /// Where the change lands and how big it is, e.g. "second-brain · Small".
    var placeLine: String? {
        let parts = [planRepo ?? repo, sizeWord].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How many of the build's checks passed, couldn't be checked, or failed.
    func checkCount(_ state: FeedbackCheck.State) -> Int {
        checks.lazy.filter { $0.state == state }.count
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
