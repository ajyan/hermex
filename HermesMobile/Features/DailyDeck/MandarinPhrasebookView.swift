import Observation
import SwiftUI

/// The Mandarin phrasebook as he reads it: every phrase grouped by the day it was added (newest
/// first, "Today · call with Dad"), search over characters, toneless pinyin and English, every pattern
/// taken away, and an optional Review round over the phrases due (Got it / Again count only once the
/// server has them).
@MainActor
@Observable
final class MandarinPhrasebookModel: Identifiable {
    struct Section: Identifiable, Equatable {
        let title: String
        let rows: [MandarinBookPhrase]
        var id: String { title }
    }

    enum Loading: Equatable {
        case idle
        case loading
        case failed(String)
    }

    var query = ""
    private(set) var loading: Loading = .idle
    private(set) var book = MandarinPhrasebook()
    private(set) var reviewQueue: [DeckPhrase] = []
    private(set) var reviewError: String?
    private(set) var isSavingReview = false

    @ObservationIgnored private let client: (any MandarinPracticeClient)?
    @ObservationIgnored private let date: String

    init(client: (any MandarinPracticeClient)?, date: String) {
        self.client = client
        self.date = date
    }

    func load() async {
        guard let client, loading != .loading else { return }
        loading = .loading
        do {
            book = try await client.phrasebook()
            reviewQueue = book.due
            loading = .idle
        } catch {
            loading = .failed("Couldn't load your phrasebook.")
        }
    }

    var patterns: [MandarinPattern] { book.patterns }

    var sections: [Section] {
        let needle = Self.fold(query)
        let rows = needle.isEmpty ? book.phrases : book.phrases.filter { phrase in
            phrase.hanzi.contains(query.trimmingCharacters(in: .whitespaces))
                || Self.fold(phrase.pinyin ?? "").contains(needle)
                || Self.fold(phrase.en ?? "").contains(needle)
        }
        var order: [String] = []
        var byDay: [String: [MandarinBookPhrase]] = [:]
        for row in rows {
            let day = row.added ?? ""
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(row)
        }
        return order.map { day in
            let group = byDay[day] ?? []
            let callers = Set(group.map(\.call))
            let who = callers.count == 1 ? callers.first.flatMap { $0 } : nil
            return Section(title: dayTitle(day) + (who.map { " · call with \(MandarinCardCopy.name($0))" } ?? ""), rows: group)
        }
    }

    /// Got it or Again on the first phrase in the Review round.
    func answer(_ phrase: DeckPhrase, got: Bool) async {
        guard let client, !isSavingReview else { return }
        isSavingReview = true
        reviewError = nil
        defer { isSavingReview = false }
        do {
            _ = try await client.recall(MandarinRecallRequest(date: date, hanzi: phrase.hanzi, got: got))
            reviewQueue.removeAll { $0.hanzi == phrase.hanzi }
        } catch {
            reviewError = "Couldn't save that. Try again."
        }
    }

    private func dayTitle(_ day: String) -> String {
        guard let today = Self.parse(date), let added = Self.parse(day) else { return day.isEmpty ? "Earlier" : day }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.iso.timeZone
        let days = calendar.dateComponents([.day], from: added, to: today).day ?? 0
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        return Self.title.string(from: added)
    }

    /// Lowercased, accents and spaces dropped: "Biǎo dá" and "biaoda" match.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: " ", with: "")
    }

    private static func parse(_ day: String) -> Date? { iso.date(from: day) }

    private static let iso: DateFormatter = formatter("yyyy-MM-dd")
    private static let title: DateFormatter = formatter("MMM d")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}

/// The phrasebook screen: Phrases (search, by day, ▶) and Patterns (each opens to its full takeaway),
/// with Review when phrases are due.
struct MandarinPhrasebookView: View {
    @State var model: MandarinPhrasebookModel
    let palette: DeckPalette

    @State private var tab = Tab.phrases
    @State private var speaker = MandarinSpeaker()
    @State private var isReviewing = false
    @State private var openPattern: String?
    @Environment(\.dismiss) private var dismiss

    private enum Tab: Hashable { case phrases, patterns }

    var body: some View {
        NavigationStack {
            List {
                Picker(selection: $tab) {
                    Text(verbatim: "Phrases").tag(Tab.phrases)
                    Text(verbatim: "Patterns").tag(Tab.patterns)
                } label: { EmptyView() }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                if case let .failed(message) = model.loading {
                    Text(verbatim: message).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
                }
                switch tab {
                case .phrases: phrases
                case .patterns: patterns
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.hxCanvas.ignoresSafeArea())
            .hxNavigationTitle("Phrasebook")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Done") }
                }
            }
            .searchable(text: $model.query, prompt: Text(verbatim: "Search hanzi, pinyin, English"))
            .sheet(isPresented: $isReviewing) { MandarinReviewSheet(model: model, palette: palette) }
        }
        .tint(palette.ink)
        .task { await model.load() }
        .onDisappear { speaker.stop() }
    }

    @ViewBuilder
    private var phrases: some View {
        if !model.reviewQueue.isEmpty {
            Button { speaker.stop(); isReviewing = true } label: {
                Label { Text(verbatim: "Review: hear the English, say it") } icon: { Image(systemName: "rectangle.stack") }
                    .font(AppFont.body(weight: .semibold))
            }
        }
        ForEach(model.sections) { section in
            Section {
                ForEach(section.rows) { row in phraseRow(row) }
            } header: {
                Text(verbatim: section.title)
            }
        }
    }

    private func phraseRow(_ row: MandarinBookPhrase) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.hanzi).font(AppFont.body(weight: .semibold))
                Text(verbatim: [row.pinyin, row.en].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
            }
            Spacer(minLength: 0)
            playButton(row.hanzi)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(verbatim: "Play")) { speaker.toggle(row.hanzi) }
    }

    @ViewBuilder
    private var patterns: some View {
        ForEach(Array(model.patterns.enumerated()), id: \.offset) { index, pattern in
            let key = "\(index)"
            Section {
                Button {
                    openPattern = openPattern == key ? nil : key
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: pattern.name).font(AppFont.body(weight: .semibold)).foregroundStyle(palette.ink)
                        Text(verbatim: pattern.form).font(AppFont.footnote()).foregroundStyle(Color.hxTextPrimary)
                    }
                }
                .accessibilityHint(Text(verbatim: openPattern == key ? "Hides the takeaway" : "Shows the takeaway"))
                if openPattern == key {
                    if let use = pattern.use, !use.isEmpty {
                        Text(verbatim: use).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
                    }
                    if let rebuilt = pattern.rebuilt, !rebuilt.isEmpty { sentence(rebuilt, note: pattern.said.map { "You said: " + $0 }) }
                    ForEach(pattern.examples, id: \.self) { sentence($0.hanzi, note: $0.en) }
                }
            } header: {
                if let date = pattern.date { Text(verbatim: date) }
            }
        }
    }

    private func sentence(_ hanzi: String, note: String?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: hanzi).font(AppFont.body())
                if let note, !note.isEmpty {
                    Text(verbatim: note).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
                }
            }
            Spacer(minLength: 0)
            playButton(hanzi)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(verbatim: "Play")) { speaker.toggle(hanzi) }
    }

    private func playButton(_ text: String) -> some View {
        Button { speaker.toggle(text) } label: {
            Image(systemName: speaker.speaking == text ? "stop.fill" : "play.fill")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(palette.ink)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }
}

/// Review: one due phrase at a time, English first; Show me, then Got it or Again.
private struct MandarinReviewSheet: View {
    let model: MandarinPhrasebookModel
    let palette: DeckPalette

    @State private var revealed = false
    @State private var speaker = MandarinSpeaker()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let phrase = model.reviewQueue.first {
                    Text(verbatim: phrase.en ?? phrase.hanzi)
                        .font(AppFont.display(style: .title2, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: "Say it out loud, then check.").font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
                    if revealed {
                        MandarinTakeaway(tag: "Phrase", text: phrase.hanzi, pinyin: phrase.pinyin, note: nil,
                                         palette: palette, speaker: speaker)
                        HStack(spacing: 8) {
                            answerButton("Again", "arrow.counterclockwise", phrase, got: false, filled: false)
                            answerButton("Got it", "checkmark", phrase, got: true, filled: true)
                        }
                        .disabled(model.isSavingReview)
                    } else {
                        Button { revealed = true } label: {
                            Label { Text(verbatim: "Show me") } icon: { Image(systemName: "eye") }
                                .font(AppFont.body(weight: .semibold))
                                .foregroundStyle(palette.onInk)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(palette.ink, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if let error = model.reviewError {
                        Text(verbatim: error).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
                    }
                } else {
                    Text(verbatim: "All reviewed").font(AppFont.display(style: .title3, weight: .semibold))
                    Text(verbatim: "They come back on their own schedule.").font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.paper.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Done") }
                }
            }
        }
        .tint(palette.ink)
        .onDisappear { speaker.stop() }
    }

    private func answerButton(_ label: String, _ symbol: String, _ phrase: DeckPhrase, got: Bool, filled: Bool) -> some View {
        Button {
            speaker.stop()
            Task {
                await model.answer(phrase, got: got)
                if model.reviewError == nil { revealed = false }
            }
        } label: {
            Label { Text(verbatim: label) } icon: { Image(systemName: symbol) }
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(filled ? palette.onInk : palette.ink)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(filled ? palette.ink : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.ink, lineWidth: filled ? 0 : 1))
        }
        .buttonStyle(.plain)
    }
}
