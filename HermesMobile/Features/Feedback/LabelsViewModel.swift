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
    /// Confirmed reasons (`LabelReason` keys), on bad labels only.
    private(set) var reasons: [LabelKey: String] = [:]
    /// The reason chip being set or cleared for each key in flight.
    private(set) var pendingReasons: [LabelKey: String] = [:]
    /// Each bad label's confirmed note, sent again when a reason changes so it isn't lost.
    private var notes: [LabelKey: String] = [:]
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
    /// Whether a verdict or a reason is saving for `key`.
    func isPending(_ key: LabelKey) -> Bool { pending[key] != nil || pendingReasons[key] != nil }
    func error(for key: LabelKey) -> String? { errors[key] }
    /// Why `key`'s ✗ is bad, once the server has it; nil when unset or not bad.
    func reason(for key: LabelKey) -> String? { reasons[key] }
    /// Whether `key`'s ✗ should ask "Why?": confirmed bad, chips to choose from, none chosen yet.
    func asksWhy(for key: LabelKey) -> Bool {
        verdicts[key] == .bad && reasons[key] == nil && !LabelReason.options(for: key).isEmpty
    }

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
        for key in verdicts.keys where key.feature == feature && (item == nil || key.item == item) && !isPending(key) {
            verdicts[key] = nil
            reasons[key] = nil
            notes[key] = nil
        }
        for record in records where !isPending(record.key) {
            verdicts[record.key] = record.currentVerdict
            keepBadDetails(of: record)
            if record.source == "feedback" { fromNotes.insert(record.key) } else { fromNotes.remove(record.key) }
            tappedDays[record.key] = record.source == "feedback" ? nil : record.ts.map { String($0.prefix(10)) }
        }
        loadedScopes.insert(item.map { "\(feature)|\($0)" } ?? feature)
    }

    /// A tap on ✓ (`.good`) or ✗ (`.bad`): sets it, or clears it when it is already the label.
    /// A blank note is left out. Ignored while this key is saving. A new ✗ starts without a reason.
    func tap(_ verdict: LabelVerdict, for key: LabelKey, note: String? = nil, title: String? = nil) async {
        guard !isPending(key), verdict != .clear else { return }
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
            confirm(saved, for: key)
        } catch {
            errors[key] = "Couldn't save. Try again."
        }
    }

    /// A tap on a reason chip under a confirmed ✗: saves the label again as bad with `reason`
    /// (its note kept), or without one when `reason` is already the label's. Non-optimistic like
    /// `tap`. Ignored unless the label is bad, and while this key is saving.
    func tapReason(_ reason: String, for key: LabelKey, title: String? = nil) async {
        guard !isPending(key), verdicts[key] == .bad else { return }
        let target = reasons[key] == reason ? nil : reason
        let body = LabelCreate(key: key, verdict: .bad, note: notes[key], title: title, reason: target)
        pendingReasons[key] = reason
        errors[key] = nil
        defer { pendingReasons[key] = nil }
        do {
            let saved = try await client.save(body)
            confirm(saved, for: key)
        } catch {
            errors[key] = "Couldn't save. Try again."
        }
    }

    private func confirm(_ saved: LabelRecord, for key: LabelKey) {
        verdicts[key] = saved.currentVerdict
        keepBadDetails(of: saved, as: key)
        fromNotes.remove(key)
        tappedDays[key] = saved.ts.map { String($0.prefix(10)) } ?? DailyDeckPaths.day(Date())
    }

    /// A bad label's reason and note as the server holds them; any other verdict has neither.
    private func keepBadDetails(of record: LabelRecord, as key: LabelKey? = nil) {
        let key = key ?? record.key
        let isBad = record.currentVerdict == .bad
        reasons[key] = isBad ? record.reason : nil
        notes[key] = isBad ? record.note : nil
    }
}
