import SwiftUI

// The v2 weekly review's cards, drawn inside `DeckCardView` on the `dusk` paper (`DeckPalette.week`).
// The cover, Remember, and Understand live here; Account in `WeeklyReviewCards+Account.swift`, Steer in
// `WeeklyReviewCards+Steer.swift`, and the pieces they share in `WeeklyReviewParts.swift`. Words are edited in `WeekEditorSheet`, so a card never holds a
// long text field. Serif is only for words he wrote and keeps: the story, evidence, and the note.

// MARK: Cover

/// The cover: the week and its range, the photo slot, the title (Atlas's until he edits it), the
/// four chapters with their minutes, and a note sealed a year ago, opened by a tap.
struct WeekCoverCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var clearance: CGFloat = 30
    @State private var isEditingTitle = false
    @State private var noteIsOpen = false

    private var editedTitle: String? {
        viewModel.answer(for: card)?.text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    private var title: String {
        editedTitle ?? card.title ?? card.weekNumber.map { "Week \($0)" } ?? "Your week"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label = weekLabel {
                HXChip(paper: palette.colors, label: label)
                    .padding(.trailing, clearance)
            }
            photoSlot.padding(.top, 14)
            Button { isEditingTitle = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: title)
                        .font(AppFont.display(style: .largeTitle, weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Label {
                        Text(verbatim: editedTitle == nil ? "Atlas's title, tap to change" : "Your title, tap to change")
                    } icon: { Image(systemName: "pencil") }
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .accessibilityLabel(Text(verbatim: "Title: \(title)"))
            .accessibilityHint(Text(verbatim: "Changes the week's title"))
            if !card.chapters.isEmpty {
                chapters.padding(.top, 22)
            }
            if let note = card.noteFromPast {
                noteFromPast(note).padding(.top, 20)
            }
            Text(verbatim: "Swipe to begin")
                .font(AppFont.footnote())
                .foregroundStyle(palette.ink)
                .padding(.top, 20)
        }
        .sheet(isPresented: $isEditingTitle) {
            WeekEditorSheet(title: "The week's title", placeholder: card.title ?? "A few words for the week",
                            palette: palette, initial: title) { viewModel.setText($0, for: card) }
        }
    }

    /// "Week 43 · Oct 19–25".
    private var weekLabel: String? {
        let parts = [card.weekNumber.map { "Week \($0)" }, card.range].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Where the week's photo goes (Task 11 fills it); for now a quiet placeholder.
    private var photoSlot: some View {
        RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous)
            .fill(Color.clear)
            .aspectRatio(4 / 3, contentMode: .fit)
            .glowSurface(palette.colors, cornerRadius: HXRadius.lg)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(AppFont.title())
                    Text(verbatim: "Photo of the week")
                        .font(AppFont.subheadline(weight: .medium))
                }
                .foregroundStyle(palette.ink)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "Photo of the week, none yet"))
    }

    private var chapters: some View {
        VStack(spacing: 0) {
            ForEach(Array(card.chapters.enumerated()), id: \.element.id) { index, chapter in
                if index > 0 { WeekHairline(palette: palette) }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: "\(index + 1)")
                        .font(AppFont.display(style: .subheadline, weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .monospacedDigit()
                        .frame(minWidth: 14, alignment: .leading)
                    Text(verbatim: chapter.label)
                        .font(AppFont.body())
                        .foregroundStyle(Color.hxTextPrimary)
                    Spacer(minLength: 8)
                    if let minutes = chapter.minutes {
                        Text(verbatim: "\(minutes) min")
                            .font(AppFont.footnote())
                            .foregroundStyle(Color.hxTextSecondary)
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, 9)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "Chapter \(index + 1), \(chapter.label)"
                    + (chapter.minutes.map { ", \($0) minutes" } ?? "")))
            }
        }
    }

    /// A sealed envelope until tapped; then the note, in his own words.
    private func noteFromPast(_ note: DeckPastNote) -> some View {
        let week = note.weekEnding.flatMap(Self.weekNumber(ofDay:)).map { "Week \($0)" } ?? "a year ago"
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { noteIsOpen.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: noteIsOpen ? "envelope.open" : "envelope.fill")
                        .font(AppFont.body(weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .frame(width: 36, height: 36)
                        .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "A note from \(week)")
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                        Text(verbatim: noteIsOpen ? "You wrote this a year ago" : "Sealed a year ago · tap to open")
                            .font(AppFont.footnote())
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                    Spacer(minLength: 0)
                }
                if noteIsOpen {
                    Text(verbatim: note.text)
                        .font(AppFont.serif(style: .body))
                        .foregroundStyle(Color.hxTextPrimary)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glowSurface(palette.colors, cornerRadius: HXRadius.md, opaque: true)
            .contentShape(RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: noteIsOpen ? "A note from \(week): \(note.text)" : "A sealed note from \(week)"))
        .accessibilityHint(Text(verbatim: noteIsOpen ? "Closes the note" : "Opens the note"))
    }

    /// The ISO week of a `yyyy-MM-dd` Sunday, as the vault numbers weeks.
    static func weekNumber(ofDay day: String) -> Int? {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return DeckPrediction.date(day: day, calendar: calendar).map { calendar.component(.weekOfYear, from: $0) }
    }
}

// MARK: Remember

/// The week as seven rows: the day, its line and who was there, a run when there was one, and a
/// small bar for the night's sleep.
struct WeekFilmstripCard: View {
    let card: DeckCard
    let palette: DeckPalette

    @ScaledMetric(relativeTo: .body) private var barHeight: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WeekCardHeading(title: card.title ?? "Your week", palette: palette)
            VStack(spacing: 0) {
                ForEach(Array(card.days.enumerated()), id: \.offset) { index, day in
                    if index > 0 { WeekHairline(palette: palette) }
                    row(day)
                }
            }
            .padding(.top, 12)
            if card.days.contains(where: { $0.sleepHours != nil }) {
                Text(verbatim: "bar = sleep")
                    .font(AppFont.caption2())
                    .foregroundStyle(Color.hxTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 6)
                    .accessibilityHidden(true)
            }
            DeckFootnote(card: card, palette: palette)
        }
    }

    private func row(_ day: DeckDay) -> some View {
        let line = day.line.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "—"
        return HStack(alignment: .center, spacing: 12) {
            Text(verbatim: day.label)
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(Color.hxTextSecondary)
                .frame(minWidth: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                (Text(verbatim: line).foregroundStyle(Color.hxTextPrimary)
                    + Text(verbatim: day.people.isEmpty ? "" : " · " + day.people.map(Self.shortName).joined(separator: ", "))
                    .foregroundStyle(Color.hxTextSecondary))
                    .font(AppFont.subheadline())
                    .fixedSize(horizontal: false, vertical: true)
                if let run = day.run {
                    Label { Text(verbatim: run) } icon: { Image(systemName: "figure.run") }
                        .font(AppFont.caption(weight: .medium))
                        .foregroundStyle(palette.ink)
                }
            }
            Spacer(minLength: 8)
            sleepBar(day.sleepHours)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.spoken(day, line: line)))
    }

    /// The night as a bar out of ten hours, in the week's glow; an empty track when there's no reading.
    private func sleepBar(_ hours: Double?) -> some View {
        Capsule()
            .fill(palette.colors.wash)
            .frame(width: 6, height: barHeight)
            .overlay(alignment: .bottom) {
                if let hours {
                    Capsule()
                        .fill(palette.ink)
                        .frame(width: 6, height: barHeight * min(max(hours, 0), 10) / 10)
                }
            }
    }

    /// "Mom", "Jon" from "Jon Chan": rows stay one glance long.
    static func shortName(_ name: String) -> String {
        String(name.split(separator: " ").first ?? Substring(name))
    }

    static func spoken(_ day: DeckDay, line: String) -> String {
        var parts = ["\(day.label): \(line)"]
        if !day.people.isEmpty { parts.append("with \(day.people.joined(separator: ", "))") }
        if let run = day.run { parts.append("run, \(run)") }
        if let hours = day.sleepHours { parts.append("slept \(hours.formatted(.number.precision(.fractionLength(0...1)))) hours") }
        return parts.joined(separator: ". ")
    }
}

/// Atlas's draft of the week, in his words once he edits it.
struct WeekStoryCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @State private var isEditing = false

    private var edited: String? {
        viewModel.answer(for: card)?.text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    private var draft: String? {
        card.storyDraft.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    var body: some View {
        let story = edited ?? draft
        VStack(alignment: .leading, spacing: 0) {
            WeekCardHeading(title: card.title ?? "The week", palette: palette)
            Button { isEditing = true } label: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: edited == nil ? "The week, drafted · edit anything" : "Your week · edit anything")
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(palette.ink)
                    Text(verbatim: story ?? "Write the week in a few lines")
                        .font(AppFont.serif(style: .title3))
                        .foregroundStyle(story == nil ? Color.hxTextSecondary : Color.hxTextPrimary)
                        .lineSpacing(5)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Label { Text(verbatim: story == nil ? "Write" : "Edit") } icon: { Image(systemName: "pencil") }
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(palette.ink)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glowSurface(palette.colors, cornerRadius: HXRadius.lg, opaque: true)
                .contentShape(RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
            .accessibilityLabel(Text(verbatim: story.map { "The week: \($0)" } ?? "Write the week in a few lines"))
            .accessibilityHint(Text(verbatim: "Edits the story"))
            DeckFootnote(card: card, palette: palette)
        }
        .sheet(isPresented: $isEditing) {
            WeekEditorSheet(title: "The week", placeholder: "Write the week in a few lines", serif: true,
                            palette: palette, initial: story ?? "") { viewModel.setText($0, for: card) }
        }
    }
}

// MARK: Understand

/// What gave him energy and what drained him: Atlas's chips to keep or remove, and his own to add.
struct WeekEnergyCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @State private var adding: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WeekCardHeading(title: card.title ?? "Where your energy went", palette: palette)
            section("gave", "Gave you energy", drafted: card.gave).padding(.top, 16)
            section("drained", "Drained you", drafted: card.drained).padding(.top, 20)
            DeckFootnote(card: card, palette: palette)
        }
        .weekAddAlert(adding == "gave" ? "Gave you energy" : "Drained you", prompt: "What was it?", isPresented: Binding(
            get: { adding != nil }, set: { if !$0 { adding = nil } })) { text in
            guard let key = adding else { return }
            let list = list(key, drafted: key == "gave" ? card.gave : card.drained)
            guard !list.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) else { return }
            viewModel.setList(key, list + [text], for: card)
        }
    }

    /// The answer's list once he's touched it, else Atlas's.
    private func list(_ key: String, drafted: [String]) -> [String] {
        viewModel.answer(for: card)?.lists?[key] ?? drafted
    }

    private func section(_ key: String, _ title: String, drafted: [String]) -> some View {
        let items = list(key, drafted: drafted)
        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .accessibilityAddTraits(.isHeader)
            FlowRow(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Button {
                        viewModel.setList(key, items.filter { $0 != item }, for: card)
                    } label: {
                        HXChip(paper: palette.colors, label: item) {
                            Image(systemName: "xmark").font(AppFont.caption2(weight: .bold))
                        }
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: item))
                    .accessibilityHint(Text(verbatim: "Removes it"))
                }
                WeekAddChip(title: "add", palette: palette) { adding = key }
                    .accessibilityLabel(Text(verbatim: "Add to \(title.lowercased())"))
            }
        }
    }
}

/// On the deep question: "This week's question", and which of the six it is.
struct WeekQuestionHeader: View {
    let rotation: String
    let palette: DeckPalette

    @ScaledMetric(relativeTo: .body) private var clearance: CGFloat = 30

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: "This week's question")
                .font(AppFont.footnote(weight: .semibold))
            Spacer(minLength: 8)
            Text(verbatim: "\(rotation) · rotates")
                .font(AppFont.footnote())
        }
        .foregroundStyle(palette.ink)
        .padding(.trailing, clearance)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }
}
