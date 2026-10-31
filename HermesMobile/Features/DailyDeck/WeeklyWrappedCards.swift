import SwiftUI

// The weekly review's own cards in the monthly format: did last week's intention hold, and next week's
// intention as Atlas proposes it. The rest of the weekly deck reuses the monthly cards.

/// Did it hold: last week's intention, the week's proof and his words about it, a coach's read, then
/// Held / Partly / Didn't (`statuses["held"]`). On Partly or Didn't, what got in the way, tapped from
/// chips drawn from his entries (`lists["reasons"]`).
struct WeekHeldCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var clearance: CGFloat = 30
    @State private var revealed = false

    private static let answers = [("held", "Held"), ("partly", "Partly"), ("didnt", "Didn't")]

    var body: some View {
        let month = card.month
        let answer = viewModel.answer(for: card)
        let held = answer?.statuses?["held"]
        let reasons = answer?.lists?["reasons"] ?? []
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: card.title ?? "Did it hold?")
                .font(AppFont.display(style: .largeTitle, weight: .bold))
                .foregroundStyle(palette.ink)
                .padding(.trailing, clearance)
                .accessibilityAddTraits(.isHeader)
            if let intention = month?.held?.intention {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "Last week you meant to")
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(palette.ink)
                    Text(verbatim: intention)
                        .font(AppFont.serif(style: .title3))
                        .foregroundStyle(Color.hxTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let ifThen = month?.held?.ifThen {
                        Text(verbatim: ifThen)
                            .font(AppFont.serif(style: .body).italic())
                            .foregroundStyle(Color.hxTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
                .padding(.top, 16)
            }
            HStack(spacing: 8) {
                ForEach(Self.answers, id: \.0) { id, label in
                    ChoiceButton(title: label, isSelected: held == id) {
                        withAnimation(HXMotion.quickState(reduceMotion: reduceMotion)) {
                            viewModel.setStatus("held", held == id ? nil : id, for: card)
                        }
                    }
                }
            }
            .padding(.top, 16)
            if held == "partly" || held == "didnt", let options = month?.held?.reasons, !options.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: "What got in the way?")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                    FlowRow(spacing: 8) {
                        ForEach(options, id: \.self) { reason in
                            ChoiceButton(title: reason, isSelected: reasons.contains(reason)) {
                                let next = reasons.contains(reason) ? reasons.filter { $0 != reason } : reasons + [reason]
                                viewModel.setList("reasons", next, for: card)
                            }
                        }
                    }
                }
                .padding(.top, 18)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            if let tiles = month?.tiles, !tiles.isEmpty {
                MonthHighlights(tiles: tiles, palette: palette, revealed: revealed).padding(.top, 18)
            }
            if let snippets = month?.snippets, !snippets.isEmpty {
                MonthSnippets(snippets: snippets, palette: palette, revealed: revealed, delay: 0.5).padding(.top, 22)
            }
            if let advisors = month?.advisors, !advisors.isEmpty {
                MonthAdvisors(title: "Your advisor's read", notes: advisors, palette: palette).padding(.top, 22)
            }
        }
        .monthReveal(card, viewModel, $revealed)
    }
}

/// Next week's intention as Atlas proposes it from the week: the intention, what could get in the way,
/// and the if-then. Use this accepts it (`statuses["plan"]`); a tap on a field edits it (`notes[field]`),
/// which stands in for Atlas's words. It shows on the morning This week divider all week.
struct WeekPlanCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var clearance: CGFloat = 30
    @State private var editing: Field?
    @State private var revealed = false

    struct Field: Identifiable {
        let id: String
        let label: String
    }

    private static let fields = [Field(id: "intention", label: "Intention"), Field(id: "obstacle", label: "What could get in the way"),
                                 Field(id: "if_then", label: "If-then")]

    private func proposed(_ id: String) -> String {
        switch id {
        case "intention": card.month?.proposal?.intention ?? ""
        case "obstacle": card.month?.proposal?.obstacle ?? ""
        default: card.month?.proposal?.ifThen ?? ""
        }
    }

    private func text(_ id: String) -> String {
        let edited = viewModel.answer(for: card)?.notes?[id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return edited.isEmpty ? proposed(id) : edited
    }

    var body: some View {
        let month = card.month
        let accepted = viewModel.answer(for: card)?.statuses?["plan"] == "accepted"
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: card.title ?? "Next week's intention")
                .font(AppFont.display(style: .largeTitle, weight: .bold))
                .foregroundStyle(palette.ink)
                .padding(.trailing, clearance)
                .accessibilityAddTraits(.isHeader)
            if let body = WeekLastIntentionCard.nonBlank(card.body) {
                Text(verbatim: body)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            if let snippets = month?.snippets, !snippets.isEmpty {
                MonthSnippets(title: "From your week", snippets: snippets, palette: palette, revealed: revealed, delay: 0.3)
                    .padding(.top, 20)
            }
            if let advisors = month?.advisors, !advisors.isEmpty {
                MonthAdvisors(title: "Your advisor's read", notes: advisors, palette: palette).padding(.top, 20)
            }
            Text(verbatim: "Atlas proposes")
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(palette.ink)
                .padding(.top, 24)
            VStack(spacing: 10) {
                ForEach(Self.fields) { field in
                    WeekWordsBox(label: field.label, text: text(field.id), placeholder: "Tap to write", palette: palette) {
                        editing = field
                    }
                }
            }
            .padding(.top, 10)
            Button {
                withAnimation(HXMotion.quickState(reduceMotion: reduceMotion)) {
                    viewModel.setStatus("plan", accepted ? nil : "accepted", for: card)
                }
            } label: {
                Label(accepted ? "Set for next week" : "Use this", systemImage: accepted ? "checkmark.circle.fill" : "checkmark")
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(accepted ? palette.ink : Color.hxOnAccent)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(accepted ? palette.colors.wash : Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .accessibilityHint(Text(verbatim: accepted ? "Undoes accepting the intention" : "Sets this as next week's intention"))
            Text(verbatim: "It shows on your morning This week line all week. Tap a line to make it yours.")
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .monthReveal(card, viewModel, $revealed)
        .sheet(item: $editing) { field in
            WeekEditorSheet(title: field.label, placeholder: proposed(field.id), serif: true, palette: palette,
                            initial: text(field.id)) { viewModel.setNote(field.id, $0, for: card) }
        }
    }
}

/// A letter to himself a year from now, sealed with the week and opened on this week next year. The
/// card offers what this week might be worth telling him (`month.themes`), then a letter sheet; once
/// written, the envelope seals. Filed as the card's answer text, as the note to the future always was.
struct WeekLetterCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var clearance: CGFloat = 30
    @State private var isWriting = false
    @State private var revealed = false

    var body: some View {
        let letter = viewModel.answer(for: card)?.text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: card.title ?? "A letter to next year")
                .font(AppFont.display(style: .largeTitle, weight: .bold))
                .foregroundStyle(palette.ink)
                .padding(.trailing, clearance)
                .accessibilityAddTraits(.isHeader)
            if let body = WeekLastIntentionCard.nonBlank(card.body) {
                Text(verbatim: body)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            let starred = starredMoments
            if !starred.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: "The moments you starred")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(palette.ink)
                    ForEach(starred) { day in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "star.fill")
                                .font(AppFont.caption(weight: .bold))
                                .foregroundStyle(palette.ink)
                            Text(verbatim: "\(day.day) · \(day.line)")
                                .font(AppFont.subheadline())
                                .foregroundStyle(Color.hxTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
                .padding(.top, 20)
            }
            if let themes = card.month?.themes, !themes.isEmpty {
                MonthThemes(title: starred.isEmpty ? "What you might want to remember" : "Also from this week", themes: themes, palette: palette, revealed: revealed)
                    .padding(.top, 20)
            }
            Button { isWriting = true } label: { envelope(letter) }
                .buttonStyle(.plain)
                .padding(.top, 22)
                .accessibilityLabel(Text(verbatim: letter == nil ? "Write the letter" : "Your sealed letter"))
                .accessibilityHint(Text(verbatim: letter == nil ? "Opens a letter to next year" : "Opens it to change it"))
        }
        .monthReveal(card, viewModel, $revealed)
        .sheet(isPresented: $isWriting) {
            WeekEditorSheet(title: "Dear me, a year from now", placeholder: starredMoments.first.map { "Start with \($0.day): \($0.line)" } ?? "It opens on this week next year", serif: true,
                            palette: palette, initial: letter ?? "") { text in
                withAnimation(HXMotion.pop(reduceMotion: reduceMotion)) {
                    viewModel.setText(text, for: card)
                }
            }
        }
    }

    /// The cover's days he starred, in order: what the letter could be about.
    private var starredMoments: [DeckMonth.DayLine] {
        guard let cover = viewModel.cards.first(where: { $0.type == .monthCover }),
              let stars = viewModel.answer(for: cover)?.lists?["stars"], !stars.isEmpty else { return [] }
        return (cover.month?.dayLines ?? []).filter { stars.contains($0.day) }
    }

    /// An open letter until he writes; then a sealed envelope with when it opens.
    private func envelope(_ letter: String?) -> some View {
        let sealed = letter != nil
        return VStack(spacing: 14) {
            ZStack {
                Image(systemName: sealed ? "envelope.fill" : "envelope.open")
                    .font(AppFont.display(style: .largeTitle, weight: .regular))
                    .foregroundStyle(palette.ink)
                if sealed {
                    Circle()
                        .fill(palette.ink)
                        .overlay(Image(systemName: "heart.fill").font(AppFont.caption2(weight: .bold)).foregroundStyle(palette.onInk))
                        .frame(width: 22, height: 22)
                        .offset(y: 8)
                        .transition(reduceMotion ? .opacity : .scale(scale: 2.2).combined(with: .opacity))
                }
            }
            .frame(height: 56)
            Text(verbatim: sealed ? "Sealed" : "Write to yourself")
                .font(AppFont.headline())
                .foregroundStyle(Color.hxTextPrimary)
            Text(verbatim: card.range.map { sealed ? "Opens \($0)" : "It opens \($0)" } ?? "It opens on this week next year")
                .font(AppFont.footnote(weight: .medium))
                .foregroundStyle(palette.ink)
            if let letter {
                Text(verbatim: letter)
                    .font(AppFont.serif(style: .footnote))
                    .foregroundStyle(Color.hxTextSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .blur(radius: 2.5)
                    .accessibilityHidden(true)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .glowSurface(palette.colors, cornerRadius: HXRadius.lg, opaque: true)
        .contentShape(RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous))
    }
}
