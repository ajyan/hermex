import PhotosUI
import SwiftUI

// The weekly review's cards, drawn inside `DeckCardView` on the `dusk` paper (`DeckPalette.week`).
// The cover lives here; last week, the values, and the intention in `WeeklyReviewCards+V3.swift`, the
// keepsakes in `WeeklyReviewCards+Steer.swift`, and the pieces they share in `WeeklyReviewParts.swift`.
// Words are edited in `WeekEditorSheet`, so a card never holds a long text field. Serif is only for
// words he wrote and keeps: a value's line, the intention's fields, and the note.

// MARK: Cover

/// The cover: the week and its range, the photo slot, the title (Atlas's until he edits it), a note
/// sealed a year ago (opened by a tap), the week's moments, and how it ended.
struct WeekCoverCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var clearance: CGFloat = 30
    @State private var isEditingTitle = false
    @State private var noteIsOpen = false
    @State private var showsPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    /// A picked photo is being read and converted, before the upload starts.
    @State private var isPreparingPhoto = false
    @State private var hasPhoto = false
    @State private var isAddingMoment = false

    private var isBusyWithPhoto: Bool { isPreparingPhoto || viewModel.isUploadingWeekPhoto }

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
            if let recap = card.recap {
                // "This week was about: <question>", when the week had a question.
                Text(verbatim: recap)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            if let note = card.noteFromPast {
                noteFromPast(note).padding(.top, 20)
            }
            moments.padding(.top, 18)
            Text(verbatim: "Swipe to begin")
                .font(AppFont.footnote())
                .foregroundStyle(palette.ink)
                .padding(.top, 20)
        }
        .sheet(isPresented: $isEditingTitle) {
            WeekEditorSheet(title: "The week's title", placeholder: card.title ?? "A few words for the week",
                            palette: palette, initial: title) { viewModel.setText($0, for: card) }
        }
        .weekAddAlert("Add a moment", prompt: "What happened?", isPresented: $isAddingMoment) { line in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { viewModel.addOwnMoment(line, for: card) }
        }
    }

    /// "Week 43 · Oct 19–25".
    private var weekLabel: String? {
        let parts = [card.weekNumber.map { "Week \($0)" }, card.range].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The week's photo: a tap opens the library, and picking again replaces it. The slot keeps its
    /// image while uploading and when an upload fails, with the reason under it.
    private var photoSlot: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showsPhotoPicker = true } label: {
                WeekPhotoView(viewModel: viewModel, palette: palette, hasPhoto: $hasPhoto)
                    .overlay {
                        if isBusyWithPhoto {
                            RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay { ProgressView() }
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusyWithPhoto)
            .accessibilityLabel(Text(verbatim: "Photo of the week"))
            .accessibilityValue(Text(verbatim: isBusyWithPhoto ? "Uploading" : hasPhoto ? "Added" : "None yet"))
            .accessibilityHint(Text(verbatim: "Chooses a photo from your library"))
            if let error = viewModel.weekPhotoError {
                Text(verbatim: error)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxDanger)
            }
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            isPreparingPhoto = true
            Task { await upload(item) }
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        defer { isPreparingPhoto = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let jpeg = await Task.detached(priority: .userInitiated, operation: { WeekPhoto.jpeg(from: data) }).value
        else {
            viewModel.weekPhotoUnreadable()
            return
        }
        await viewModel.setWeekPhoto(jpeg)
    }

    /// The moments he keeps, each with its weekday, line, and value, and Swap or remove while the
    /// rules allow; then how the week ended. A week with no moments asks for one of his own.
    @ViewBuilder
    private var moments: some View {
        let kept = viewModel.keptMoments(for: card)
        let canSwap = viewModel.canSwap(for: card)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(kept.enumerated()), id: \.element.id) { index, moment in
                if index > 0 { WeekHairline(palette: palette) }
                momentRow(moment, canSwap: canSwap, canRemove: viewModel.canRemoveMoment(moment.id, for: card))
            }
            if card.moments.isEmpty {
                Text(verbatim: "A quiet week on paper. Add a moment?")
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, kept.isEmpty ? 0 : 14)
                WeekAddChip(title: "moment", palette: palette) { isAddingMoment = true }
                    .padding(.top, 6)
                    .accessibilityLabel(Text(verbatim: "Add a moment"))
            } else if let ended = card.ended?.trimmingCharacters(in: .whitespacesAndNewlines), !ended.isEmpty {
                (Text(verbatim: "Ended: ").foregroundStyle(palette.ink).fontWeight(.semibold)
                    + Text(verbatim: ended).foregroundStyle(Color.hxTextPrimary))
                    .font(AppFont.subheadline())
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
        }
    }

    private func momentRow(_ moment: DeckMoment, canSwap: Bool, canRemove: Bool) -> some View {
        let value = WeekValues.shortName(moment.value)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: moment.day)
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(Color.hxTextSecondary)
                .frame(minWidth: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: moment.line)
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let value { HXChip(paper: palette.colors, label: value) }
            }
            Spacer(minLength: 4)
            if canSwap {
                Button { change { viewModel.swapMoment(moment.id, for: card) } } label: {
                    Text(verbatim: "Swap")
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if canRemove {
                Button { change { viewModel.removeMoment(moment.id, for: card) } } label: {
                    Image(systemName: "xmark")
                        .font(AppFont.caption(weight: .bold))
                        .foregroundStyle(palette.ink)
                        .frame(minWidth: 28, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        // One element for VoiceOver, with Swap and Remove as its actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [moment.day, moment.line, value].compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ". ")))
        .accessibilityActions {
            if canSwap {
                Button { change { viewModel.swapMoment(moment.id, for: card) } } label: { Text(verbatim: "Swap") }
            }
            if canRemove {
                Button { change { viewModel.removeMoment(moment.id, for: card) } } label: { Text(verbatim: "Remove") }
            }
        }
    }

    private func change(_ body: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2), body)
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
        return DailyDeckPaths.date(day: day, calendar: calendar).map { calendar.component(.weekOfYear, from: $0) }
    }
}
