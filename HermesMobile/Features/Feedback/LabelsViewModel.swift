import Foundation
import Observation

/// The labels one screen shows and sets. Saving is non-optimistic: a label shows once the
/// server has it, and a failed save leaves the last confirmed label with an inline error.
/// The screen that owns it lives in the server-keyed shell, so nothing crosses servers.
@MainActor
@Observable
final class LabelsViewModel {
    /// Confirmed labels; a key with no entry is unlabeled.
    private(set) var verdicts: [LabelKey: LabelVerdict] = [:]
    /// The verdict being saved for each key in flight.
    private(set) var pending: [LabelKey: LabelVerdict] = [:]
    private(set) var errors: [LabelKey: String] = [:]
    /// Labels the server made from a feedback note rather than a tap.
    private var fromNotes: Set<LabelKey> = []
    /// The day (`yyyy-MM-dd`) each tapped label was set, from the server's `ts`.
    private var tappedDays: [LabelKey: String] = [:]
    /// Scopes read successfully: `feature` alone for a feature-wide read, `feature|item` for one item.
    private var loadedScopes: Set<String> = []

    @ObservationIgnored let client: any LabelsDataClient

    init(client: any LabelsDataClient) {
        self.client = client
    }

    func verdict(for key: LabelKey) -> LabelVerdict? { verdicts[key] }
    func isPending(_ key: LabelKey) -> Bool { pending[key] != nil }
    func error(for key: LabelKey) -> String? { errors[key] }

    /// How many of `feature`'s items got a tapped label on `day` (`yyyy-MM-dd`); a card's label
    /// and its question's count once.
    func tappedItemCount(feature: String, on day: String) -> Int {
        Set(tappedDays.filter { $0.key.feature == feature && $0.value == day && verdicts[$0.key] != nil }.map(\.key.item)).count
    }

    /// Whether `item`'s labels have been read, by a feature-wide read or its own. Rate rows
    /// stay hidden until then, so "unlabeled" never stands in for "couldn't read".
    /// Without `item`, whether the whole feature has been read.
    func isLoaded(feature: String, item: String? = nil) -> Bool {
        loadedScopes.contains(feature) || item.map { loadedScopes.contains("\(feature)|\($0)") } == true
    }

    /// Reads `feature`'s labels (one `item`'s when given), replacing what was held for them.
    func load(feature: String, item: String? = nil) async throws {
        let records = try await client.labels(feature: feature, item: item)
        for key in verdicts.keys where key.feature == feature && (item == nil || key.item == item) && pending[key] == nil {
            verdicts[key] = nil
        }
        for record in records where pending[record.key] == nil {
            verdicts[record.key] = record.currentVerdict
            if record.source == "feedback" { fromNotes.insert(record.key) } else { fromNotes.remove(record.key) }
            tappedDays[record.key] = record.source == "feedback" ? nil : record.ts.map { String($0.prefix(10)) }
        }
        loadedScopes.insert(item.map { "\(feature)|\($0)" } ?? feature)
    }

    /// A tap on ✓ (`.good`) or ✗ (`.bad`): sets it, or clears it when it is already the label.
    /// A blank note is left out. Ignored while this key is saving.
    func tap(_ verdict: LabelVerdict, for key: LabelKey, note: String? = nil, title: String? = nil) async {
        guard pending[key] == nil, verdict != .clear else { return }
        let target: LabelVerdict = verdicts[key] == verdict ? .clear : verdict
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = LabelCreate(
            key: key, verdict: target,
            note: target == .bad && trimmed?.isEmpty == false ? trimmed : nil,
            title: title)
        pending[key] = target
        errors[key] = nil
        defer { pending[key] = nil }
        do {
            let saved = try await client.save(body)
            verdicts[key] = saved.currentVerdict
            fromNotes.remove(key)
            tappedDays[key] = saved.ts.map { String($0.prefix(10)) } ?? DailyDeckPaths.day(Date())
        } catch {
            errors[key] = "Couldn't save. Try again."
        }
    }
}
