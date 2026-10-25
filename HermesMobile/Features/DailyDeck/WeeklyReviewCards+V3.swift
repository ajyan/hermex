import SwiftUI

// The weekly review's middle: last week's intention, one card per value, and next week's intention.

/// "Last week you meant to": the intention (and its if-then), how it went, the fact when one is
/// tracked, and what got in the way when it didn't fully hold.
struct WeekLastIntentionCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @State private var isEditing = false

    private static let statuses = [("held", "Held"), ("partly", "Partly"), ("didnt", "Didn't")]

    var body: some View {
        let answer = viewModel.answer(for: card)
        let status = answer?.statuses?["last"]
        VStack(alignment: .leading, spacing: 0) {
            WeekKicker(text: "Last week you meant to", palette: palette)
            WeekCardHeading(title: card.text ?? card.title ?? "", palette: palette)
            if let ifThen = Self.nonBlank(card.ifThen) {
                Text(verbatim: ifThen)
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            if let fact = Self.nonBlank(card.fact?.line) {
                Text(verbatim: fact)
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            FlowRow(spacing: 8) {
                ForEach(Self.statuses, id: \.0) { id, label in
                    WeekChoiceChip(title: label, isSelected: status == id, palette: palette) {
                        viewModel.setStatus("last", status == id ? nil : id, for: card)
                    }
                }
            }
            .padding(.top, 16)
            if status == "partly" || status == "didnt" {
                WeekWordsBox(label: "What got in the way?", text: answer?.text ?? "", placeholder: "Add a line",
                             palette: palette) { isEditing = true }
                    .padding(.top, 14)
            }
            DeckFootnote(card: card, palette: palette)
        }
        .sheet(isPresented: $isEditing) {
            WeekEditorSheet(title: "What got in the way?", placeholder: "A line about it", palette: palette,
                            initial: answer?.text ?? "") { viewModel.setText($0, for: card) }
        }
    }

    static func nonBlank(_ text: String?) -> String? {
        text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
}

/// One value: "People · 2 of 5", the week's fact for it when there is one, the question, his
/// line, and a 1–10 score.
struct WeekValueCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @State private var isEditing = false

    private var valueID: String { card.valueID ?? card.id }
    private var name: String { card.name ?? WeekValues.shortName(valueID) ?? valueID }

    /// "Showed up for my people · 2 of 5"; the name alone for a value outside the five.
    private var kicker: String {
        guard let index = WeekValues.order.firstIndex(of: valueID) else { return name }
        return "\(name) · \(index + 1) of \(WeekValues.order.count)"
    }

    private var question: String {
        WeekLastIntentionCard.nonBlank(card.question) ?? "Anything for \(name) this week?"
    }

    var body: some View {
        let answer = viewModel.answer(for: card)
        VStack(alignment: .leading, spacing: 0) {
            WeekKicker(text: kicker, palette: palette)
            if let fact = card.fact, fact.big != nil || fact.line != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let big = WeekLastIntentionCard.nonBlank(fact.big) {
                        Text(verbatim: big)
                            .font(AppFont.display(style: .largeTitle, weight: .semibold))
                            .foregroundStyle(palette.ink)
                    }
                    if let line = WeekLastIntentionCard.nonBlank(fact.line) {
                        Text(verbatim: line)
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .padding(.bottom, 16)
            }
            WeekCardHeading(title: question, palette: palette)
            WeekWordsBox(text: answer?.text ?? "", placeholder: "A line about the week", palette: palette) {
                isEditing = true
            }
            .padding(.top, 14)
            WeekScoreRow(title: name, score: answer?.scores?[valueID], palette: palette) { score in
                viewModel.setScore(valueID, score, for: card)
            }
            .padding(.top, 20)
            DeckFootnote(card: card, palette: palette)
        }
        .sheet(isPresented: $isEditing) {
            WeekEditorSheet(title: name, subtitle: question, placeholder: "A line about the week", serif: true,
                            palette: palette, initial: answer?.text ?? "") { viewModel.setText($0, for: card) }
        }
    }
}

/// Next week: the thread, the intention, the obstacle, and the if-then, drafted from his answers
/// into the fields he hasn't touched, then the goal coach's changes to accept.
struct WeekIntentionCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @State private var editing: Field?
    /// Goals whose confirm failed on this screen; a retry clears it.
    @State private var failed: Set<String> = []

    struct Field: Identifiable {
        let id: String
        let label: String
        let placeholder: String
    }

    private static let fields = [
        Field(id: "thread", label: "Thread", placeholder: "One sentence for the week"),
        Field(id: "text", label: "Intention", placeholder: "What you mean to do"),
        Field(id: "obstacle", label: "Obstacle", placeholder: "What could get in the way"),
        Field(id: "if_then", label: "If-then", placeholder: "If that happens, then…"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WeekCardHeading(title: card.title ?? "This week", palette: palette)
            if viewModel.isDraftingIntention {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: "Drafting from your answers")
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                }
                .padding(.top, 8)
                .accessibilityElement(children: .combine)
            }
            VStack(spacing: 10) {
                ForEach(Self.fields) { field in
                    WeekWordsBox(label: field.label, text: viewModel.intentionField(field.id, for: card),
                                 placeholder: field.placeholder, palette: palette) { editing = field }
                }
            }
            .padding(.top, 14)
            if !card.changes.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(card.changes.enumerated()), id: \.element.id) { index, change in
                        if index > 0 { WeekHairline(palette: palette) }
                        changeRow(change)
                    }
                }
                .padding(.top, 18)
            }
            DeckFootnote(card: card, palette: palette)
        }
        .sheet(item: $editing) { field in
            WeekEditorSheet(title: field.label, placeholder: field.placeholder, serif: true, palette: palette,
                            initial: viewModel.intentionField(field.id, for: card)) {
                viewModel.setIntentionField(field.id, $0, for: card)
            }
        }
        .task {
            // A filed week, or one he's started, keeps what it has; a draft would read as an edit.
            let answer = viewModel.answer(for: card)
            guard !viewModel.isFiled, answer?.text == nil, answer?.notes?.isEmpty ?? true else { return }
            await viewModel.intentionDraft()
        }
    }

    /// "Outreach 10 → 5 · Accept", the coach's reason under it.
    private func changeRow(_ change: DeckGoalChange) -> some View {
        let accepted = viewModel.isAccepted(change, for: card)
        let accepting = viewModel.acceptingChanges.contains(change.goal)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: change.label.isEmpty ? change.title : change.label)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                if !change.reason.isEmpty {
                    Text(verbatim: change.reason)
                        .font(AppFont.caption())
                        .foregroundStyle(Color.hxTextSecondary)
                }
                if failed.contains(change.goal) {
                    Text(verbatim: "Couldn't confirm. Try again.")
                        .font(AppFont.caption())
                        .foregroundStyle(Color.hxDanger)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if accepted {
                Label { Text(verbatim: "Accepted") } icon: { Image(systemName: "checkmark") }
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink)
            } else if accepting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text(verbatim: "Confirming"))
            } else {
                Button {
                    failed.remove(change.goal)
                    Task {
                        let accepted = await viewModel.acceptChange(change, for: card)
                        if !accepted { failed.insert(change.goal) }
                    }
                } label: {
                    Text(verbatim: "Accept").font(AppFont.footnote(weight: .semibold))
                }
                .buttonStyle(.borderless)
                .tint(Color.accentColor)
                .frame(minHeight: 44)
                .accessibilityLabel(Text(verbatim: "Accept \(change.label.isEmpty ? change.title : change.label)"))
            }
        }
        .padding(.vertical, 8)
    }
}
