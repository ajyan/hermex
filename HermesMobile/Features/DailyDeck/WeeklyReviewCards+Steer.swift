import SwiftUI

// The weekly review's Steer chapter: the one thing to carry, who to see, and the keepsakes.

/// On the one-thing card: last week's missed commitments (not people), each a tap away from being this week's.
/// Offered only while the answer is empty or is one of them, so a tap never overwrites his words.
struct WeekCarryChips: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    var body: some View {
        let missed = Self.carryable(viewModel.missedCommitments)
        let current = viewModel.answer(for: card)?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if Self.offers(missed, current: current) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Carry it from last week")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink)
                FlowRow(spacing: 8) {
                    ForEach(missed) { item in
                        WeekChoiceChip(title: item.text, symbol: "arrow.uturn.forward", isSelected: current == item.text,
                                       palette: palette) {
                            viewModel.setText(current == item.text ? "" : item.text, for: card)
                        }
                        .accessibilityHint(Text(verbatim: "Makes it this week's one thing"))
                    }
                }
            }
            .padding(.top, 18)
        }
    }

    /// The missed commitments a one thing can carry: everything but people, who carry on the who card.
    static func carryable(_ missed: [DeckReviewItem]) -> [DeckReviewItem] {
        missed.filter { !$0.id.hasPrefix("who-") }
    }

    /// Whether to offer `missed`: there are some, and the answer is empty or already one of them.
    static func offers(_ missed: [DeckReviewItem], current: String) -> Bool {
        !missed.isEmpty && (current.isEmpty || missed.contains { $0.text == current })
    }
}

/// Who to see this week: Atlas's suggestions and anyone he adds, tapped on or off, plus the
/// people he missed last week to carry.
struct WeekWhoCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @State private var isAdding = false

    private var chosen: [String] { viewModel.answer(for: card)?.lists?["who"] ?? [] }

    var body: some View {
        let chosen = chosen
        let offered = Self.unique(card.suggested + chosen)
        // A carried name moves up into the chips above; untapping it there sends it back.
        let missed = viewModel.missedCommitments.filter { $0.id.hasPrefix("who-") }.map(\.text)
            .filter { !offered.contains($0) }
        VStack(alignment: .leading, spacing: 0) {
            WeekCardHeading(title: card.title ?? "Who will you make time for?", palette: palette)
            FlowRow(spacing: 8) {
                ForEach(offered, id: \.self) { name in
                    WeekChoiceChip(title: name, symbol: chosen.contains(name) ? "checkmark" : nil,
                                   isSelected: chosen.contains(name), palette: palette) { toggle(name) }
                }
                WeekAddChip(title: "person", palette: palette) { isAdding = true }
                    .accessibilityLabel(Text(verbatim: "Add a person"))
            }
            .padding(.top, 16)
            if !missed.isEmpty {
                Text(verbatim: "Carry it from last week")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .padding(.top, 20)
                FlowRow(spacing: 8) {
                    ForEach(missed, id: \.self) { name in
                        WeekChoiceChip(title: name, symbol: "arrow.uturn.forward", isSelected: false,
                                       palette: palette) { toggle(name) }
                    }
                }
                .padding(.top, 8)
            }
            DeckFootnote(card: card, palette: palette)
        }
        .weekAddAlert("Add a person", prompt: "Name", isPresented: $isAdding) { name in
            viewModel.setList("who", Self.adding(name, to: chosen, suggested: card.suggested), for: card)
        }
    }

    private func toggle(_ name: String) {
        let chosen = chosen
        viewModel.setList("who", chosen.contains(name) ? chosen.filter { $0 != name } : chosen + [name], for: card)
    }

    /// `chosen` with `name` added. A name already offered, in any case, is chosen under its own
    /// spelling rather than added twice.
    static func adding(_ name: String, to chosen: [String], suggested: [String]) -> [String] {
        let same = { (other: String) in other.caseInsensitiveCompare(name) == .orderedSame }
        guard !chosen.contains(where: same) else { return chosen }
        return chosen + [suggested.first(where: same) ?? name]
    }

    static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}

/// Two things to leave for later: a note that opens in a year, and a prediction to grade.
struct WeekKeepsakesCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @Environment(\.dynamicTypeSize) private var typeSize
    /// One height for both tiles' icon rows, so their titles line up whatever the glyph.
    @ScaledMetric(relativeTo: .title3) private var iconRow: CGFloat = 28
    @State private var isWritingNote = false
    @State private var isPredicting = false

    var body: some View {
        let answer = viewModel.answer(for: card)
        let note = answer?.text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: 0) {
            WeekCardHeading(title: card.title ?? "Keepsakes", palette: palette)
            Text(verbatim: "Both optional. The note opens on this week next year.")
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            // Side by side; stacked at accessibility sizes, where half a card is too narrow.
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(spacing: 10) { tiles(note: note, prediction: answer?.prediction) }
                } else {
                    HStack(alignment: .top, spacing: 10) { tiles(note: note, prediction: answer?.prediction) }
                }
            }
            .padding(.top, 18)
            DeckFootnote(card: card, palette: palette)
        }
        .sheet(isPresented: $isWritingNote) {
            WeekEditorSheet(title: "A note to you, a year from now", placeholder: "It opens on this week next year",
                            serif: true, palette: palette, initial: note ?? "") { viewModel.setText($0, for: card) }
        }
        .sheet(isPresented: $isPredicting) {
            WeekPredictionSheet(card: card, palette: palette, viewModel: viewModel)
        }
    }

    @ViewBuilder
    private func tiles(note: String?, prediction: DeckPrediction?) -> some View {
        tile(symbol: "envelope", title: "Note to the future", isDone: note != nil) {
            if let note {
                Text(verbatim: note)
                    .font(AppFont.serif(style: .footnote))
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineLimit(3)
            } else {
                Text(verbatim: "Write to yourself a year from now")
            }
        } action: { isWritingNote = true }
        tile(symbol: "target", title: "Make a prediction", isDone: prediction != nil) {
            if let prediction {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: prediction.text)
                        .foregroundStyle(Color.hxTextPrimary)
                        .lineLimit(2)
                    Text(verbatim: "\(prediction.probability)% · by \(DailyDeckPaths.label(prediction.due))")
                        .foregroundStyle(palette.ink)
                }
            } else {
                Text(verbatim: "Something you'll know in a few weeks")
            }
        } action: { isPredicting = true }
    }

    private func tile<Detail: View>(symbol: String, title: String, isDone: Bool, @ViewBuilder detail: () -> Detail,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol)
                        .font(AppFont.title3(weight: .semibold))
                        .foregroundStyle(palette.ink)
                    Spacer(minLength: 4)
                    if isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .font(AppFont.body())
                            .foregroundStyle(palette.ink)
                    }
                }
                .frame(height: iconRow)
                Text(verbatim: title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                detail()
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .glowSurface(palette.colors, cornerRadius: HXRadius.lg, opaque: true)
            .contentShape(RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(verbatim: isDone ? "Edits it" : "Opens an editor"))
    }
}

/// The prediction: what will happen, how sure he is (10–90%), and the day it can be graded.
/// Saves as he goes; clearing the words clears the prediction.
private struct WeekPredictionSheet: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var text = ""
    @State private var probability = DeckPrediction.defaultProbability
    @State private var due = Date()
    /// The picker's first day: today, or a saved due day already behind it.
    @State private var earliest = Date()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(verbatim: "Make a prediction")
                    .font(AppFont.display(style: .title3, weight: .semibold))
                    .foregroundStyle(palette.ink)
                TextField(text: $text, axis: .vertical) { Text(verbatim: "What will happen?") }
                    .font(AppFont.body())
                    .lineLimit(2...5)
                    .focused($isFocused)
                    .padding(12)
                    .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
                Stepper(value: $probability, in: 10...90, step: 10) {
                    HStack {
                        Text(verbatim: "How sure")
                        Spacer(minLength: 8)
                        Text(verbatim: "\(probability)%").monospacedDigit().foregroundStyle(palette.ink)
                    }
                    .font(AppFont.body())
                }
                .accessibilityValue(Text(verbatim: "\(probability) percent"))
                DatePicker(selection: $due, in: earliest..., displayedComponents: .date) {
                    Text(verbatim: "Know by").font(AppFont.body())
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(palette.paper.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Done") }
                }
            }
            .toolbarBackground(palette.paper, for: .navigationBar)
        }
        .tint(palette.ink)
        .onAppear {
            let saved = viewModel.answer(for: card)?.prediction
            text = saved?.text ?? ""
            probability = saved?.probability ?? DeckPrediction.defaultProbability
            due = DeckPrediction.date(day: saved?.due ?? DeckPrediction.defaultDue(deckDate: viewModel.date)) ?? Date()
            earliest = Calendar.current.startOfDay(for: min(due, Date()))
            isFocused = saved == nil
        }
        .onChange(of: text) { save() }
        .onChange(of: probability) { save() }
        .onChange(of: due) { save() }
        .presentationDragIndicator(.visible)
    }

    private func save() {
        viewModel.setPrediction(DeckPrediction(text: text, probability: probability, due: DailyDeckPaths.day(due)), for: card)
    }
}
