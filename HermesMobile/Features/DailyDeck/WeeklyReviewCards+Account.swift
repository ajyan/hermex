import SwiftUI

// The weekly review's Account chapter: last week's word, the five values, and predictions come due.

/// "Last Sunday you said": each commitment tapped through kept, missed, dropped, and back to none.
struct WeekCommitmentsCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    var body: some View {
        let statuses = viewModel.answer(for: card)?.statuses ?? [:]
        VStack(alignment: .leading, spacing: 0) {
            WeekCardHeading(title: card.title ?? "Last Sunday you said", palette: palette)
            Text(verbatim: card.items.isEmpty ? "Nothing was carried from last week." : "Tap each to mark it kept, missed, or dropped.")
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(Array(card.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { WeekHairline(palette: palette) }
                    row(item, status: statuses[item.id])
                }
            }
            .padding(.top, 10)
            DeckFootnote(card: card, palette: palette)
        }
    }

    private func row(_ item: DeckReviewItem, status: String?) -> some View {
        let carried = item.carried ?? 0
        let dropped = status == CommitmentStatus.dropped
        let text = Self.text(item)
        return Button {
            viewModel.setStatus(item.id, CommitmentStatus.next(after: status), for: card)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Self.mark(status, palette: palette)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: text)
                        .font(AppFont.body())
                        .foregroundStyle(dropped ? Color.hxTextSecondary : Color.hxTextPrimary)
                        .strikethrough(dropped)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if status != nil || carried >= 2 {
                        // One run of text, so it wraps as words at large sizes.
                        (Text(verbatim: Self.word(status) ?? "").foregroundStyle(Self.color(status))
                            + Text(verbatim: status != nil && carried >= 2 ? " · " : "").foregroundStyle(Color.hxTextSecondary)
                            + Text(verbatim: carried >= 2 ? "carried \(carried)×" : "").foregroundStyle(Color.hxWarning))
                            .font(AppFont.footnote(weight: .medium))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: text + (carried >= 2 ? ", carried \(carried) weeks" : "")))
        .accessibilityValue(Text(verbatim: Self.word(status) ?? "Not marked"))
        .accessibilityHint(Text(verbatim: "Marks it \(Self.word(CommitmentStatus.next(after: status))?.lowercased() ?? "unmarked")"))
    }

    /// Kept is a check, missed a warning, dropped a struck-out dash, and none a dashed circle, so
    /// the shape says it before the color does.
    @ViewBuilder
    static func mark(_ status: String?, palette: DeckPalette) -> some View {
        switch status {
        case CommitmentStatus.kept:
            Image(systemName: "checkmark.circle.fill").font(AppFont.title3()).foregroundStyle(Color.hxSuccess)
        case CommitmentStatus.missed:
            Image(systemName: "exclamationmark.circle.fill").font(AppFont.title3()).foregroundStyle(Color.hxWarning)
        case CommitmentStatus.dropped:
            Image(systemName: "minus.circle").font(AppFont.title3()).foregroundStyle(Color.hxTextSecondary)
        default:
            Image(systemName: "circle.dashed").font(AppFont.title3()).foregroundStyle(palette.ink)
        }
    }

    /// A person he meant to see reads as "See Jon Chan"; the one thing as he wrote it.
    static func text(_ item: DeckReviewItem) -> String {
        item.id.hasPrefix("who-") ? "See \(item.text)" : item.text
    }

    static func word(_ status: String?) -> String? {
        switch status {
        case CommitmentStatus.kept: "Kept"
        case CommitmentStatus.missed: "Missed"
        case CommitmentStatus.dropped: "Dropped"
        default: nil
        }
    }

    static func color(_ status: String?) -> Color {
        switch status {
        case CommitmentStatus.kept: .hxSuccess
        case CommitmentStatus.missed: .hxWarning
        default: .hxTextSecondary
        }
    }
}

/// "How you lived your values": each of the five scored on ten segments, and under the week's
/// strongest and weakest, the evidence for it in his words (Atlas's line until he edits it).
struct WeekValuesCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @ScaledMetric(relativeTo: .body) private var segmentHeight: CGFloat = 10
    @State private var editing: DeckValue?

    var body: some View {
        let answer = viewModel.answer(for: card)
        let scores = answer?.scores ?? [:]
        let marked = WeeklyValues.topAndBottom(scores, order: card.values.map(\.id))
        VStack(alignment: .leading, spacing: 0) {
            WeekCardHeading(title: card.title ?? "How you lived your values", palette: palette)
            VStack(alignment: .leading, spacing: 20) {
                ForEach(card.values) { value in
                    VStack(alignment: .leading, spacing: 6) {
                        row(value, score: scores[value.id])
                        if let rank = marked.firstIndex(of: value.id) {
                            evidence(value, note: answer?.notes?[value.id], isTop: rank == 0)
                                .padding(.top, 6)
                        }
                    }
                }
            }
            .padding(.top, 18)
            DeckFootnote(card: card, palette: palette)
        }
        .sheet(item: $editing) { value in
            WeekEditorSheet(title: "Where \(value.name.lowercased()) showed", placeholder: "A line about the week",
                            serif: true, palette: palette, initial: evidenceText(value)) {
                viewModel.setNote(value.id, $0, for: card)
            }
        }
    }

    private func row(_ value: DeckValue, score: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: value.name)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(verbatim: score.map(String.init) ?? "–")
                    .font(AppFont.display(style: .headline, weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .monospacedDigit()
            }
            HStack(spacing: 4) {
                ForEach(1...10, id: \.self) { segment in
                    Button { viewModel.setScore(value.id, segment, for: card) } label: {
                        Capsule()
                            .fill(segment <= (score ?? 0) ? palette.ink : Color.hxSeparator)
                            .frame(height: min(segmentHeight, 14))
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // One adjustable element for VoiceOver: "Present, 7 of 10".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: value.name))
        .accessibilityValue(Text(verbatim: score.map { "\($0) of 10" } ?? "Not scored"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if (score ?? 0) < 10 { viewModel.setScore(value.id, (score ?? 0) + 1, for: card) }
            case .decrement: if let score, score > 1 { viewModel.setScore(value.id, score - 1, for: card) }
            @unknown default: break
            }
        }
    }

    /// The note once he's written one, else Atlas's evidence.
    private func evidenceText(_ value: DeckValue) -> String {
        viewModel.answer(for: card)?.notes?[value.id] ?? value.evidence ?? ""
    }

    private func evidence(_ value: DeckValue, note: String?, isTop: Bool) -> some View {
        let text = (note ?? value.evidence ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Button { editing = value } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: isTop ? "Strongest this week" : "Most room to grow")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink)
                Text(verbatim: text.isEmpty ? "Add a line about where it showed" : text)
                    .font(AppFont.serif(style: .subheadline))
                    .foregroundStyle(text.isEmpty ? Color.hxTextSecondary : Color.hxTextPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glowSurface(palette.colors, cornerRadius: HXRadius.md, opaque: true)
            .contentShape(RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(isTop ? "Strongest" : "Most room to grow"), \(value.name): \(text.isEmpty ? "no line yet" : text)"))
        .accessibilityHint(Text(verbatim: "Edits the line"))
    }
}

/// Predictions made weeks ago, now due: what happened (hit, partly, miss) and a line about it.
struct WeekPredictionsCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @State private var editing: DeckReviewItem?

    private static let grades = [("hit", "Hit"), ("partly", "Partly"), ("miss", "Miss")]

    var body: some View {
        let answer = viewModel.answer(for: card)
        VStack(alignment: .leading, spacing: 0) {
            WeekCardHeading(title: card.title ?? "Predictions come due", palette: palette)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(card.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { WeekHairline(palette: palette).padding(.vertical, 16) }
                    prediction(item, grade: answer?.statuses?[item.id], note: answer?.notes?[item.id])
                }
            }
            .padding(.top, 16)
            DeckFootnote(card: card, palette: palette)
        }
        .sheet(item: $editing) { item in
            WeekEditorSheet(title: "What happened?", placeholder: "A line about how it turned out", palette: palette,
                            initial: viewModel.answer(for: card)?.notes?[item.id] ?? "") {
                viewModel.setNote(item.id, $0, for: card)
            }
        }
    }

    private func prediction(_ item: DeckReviewItem, grade: String?, note: String?) -> some View {
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: item.text)
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let meta = Self.meta(item) {
                Text(verbatim: meta)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
            }
            Text(verbatim: "What happened?")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(palette.ink)
                .padding(.top, 4)
            FlowRow(spacing: 8) {
                ForEach(Self.grades, id: \.0) { id, label in
                    WeekChoiceChip(title: label, isSelected: grade == id, palette: palette) {
                        viewModel.setStatus(item.id, grade == id ? nil : id, for: card)
                    }
                    .accessibilityLabel(Text(verbatim: "\(label): \(item.text)"))
                }
            }
            Button { editing = item } label: {
                Label { Text(verbatim: note.isEmpty ? "Add a line" : note) } icon: {
                    Image(systemName: note.isEmpty ? "plus" : "pencil")
                }
                .font(AppFont.subheadline())
                .foregroundStyle(note.isEmpty ? palette.ink : Color.hxTextPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(verbatim: "Edits the line about how it turned out"))
        }
    }

    /// "You said 70% · made Oct 4".
    static func meta(_ item: DeckReviewItem) -> String? {
        let parts = [item.probability.map { "You said \($0)%" }, item.madeWeek.map { "made \(DailyDeckPaths.label($0))" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
