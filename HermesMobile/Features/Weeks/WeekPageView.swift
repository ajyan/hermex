import PhotosUI
import SwiftUI

/// One sealed week, to reread for years: the photo, the week and its days, the title, the story,
/// then what he kept of it (energy, the deep answer, the values, the one thing, who, the note to the
/// future, the prediction and its grade). A moments record (`momentsSections`) is its
/// moments, how it ended, and his answers instead. Empty sections are left out, so a backfilled week
/// is its photo, title, and story. Edit reopens the filed deck (also when the record can't be read); the
/// photo can be added, replaced, or removed.
struct WeekPageView: View {
    let model: WeeksModel
    let weekEnding: String
    let edit: () -> Void

    private enum Phase { case loading, missing, ready(WeekRecord) }

    @State private var phase = Phase.loading
    @State private var grade: String?
    @State private var showsPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var confirmsRemoval = false
    /// A photo is being read, uploaded, or removed.
    @State private var isBusyWithPhoto = false
    @State private var photoError: String?
    /// The week whose record, grade, and photo state are on screen.
    @State private var shownWeek: String
    /// Whether the photo loader found an image, for when the photo listing couldn't be read.
    @State private var showsLoadedPhoto = false

    let palette = DeckPalette.week

    /// Whether the week has a photo: the listing's answer, else what the loader found.
    private var hasPhoto: Bool {
        model.photosListed ? model.photoDates.contains(weekEnding) : showsLoadedPhoto
    }

    private var isLoading: Bool { if case .loading = phase { true } else { false } }

    /// Try the photo itself when the listing has it or couldn't be read.
    private var loadsPhoto: Bool { !model.photosListed || model.photoDates.contains(weekEnding) }

    init(model: WeeksModel, weekEnding: String, edit: @escaping () -> Void) {
        self.model = model
        self.weekEnding = weekEnding
        self.edit = edit
        // A record this model already read shows at once, without a spinner.
        _phase = State(initialValue: model.cachedRecord(weekEnding).map(Phase.ready) ?? .loading)
        _shownWeek = State(initialValue: weekEnding)
    }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
        }
        .background(Color.hxCanvas.ignoresSafeArea())
        .hxNavigationTitle("Your week")
        .toolbar {
            // Edit stays when the record can't be read, so the week can be sealed again.
            if !isLoading {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if case .ready = phase { photoMenu }
                    Button("Edit", action: edit)
                        .accessibilityHint(Text(verbatim: "Reopens the week's review to change and seal again"))
                }
            }
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await upload(item) }
        }
        .confirmationDialog("Remove this week's photo?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove Photo", role: .destructive) { Task { await removePhoto() } }
        } message: {
            Text(verbatim: "It's deleted from your vault. The week's record stays.")
        }
        .task(id: weekEnding) { await load() }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        case .missing:
            VStack(spacing: 12) {
                Text(verbatim: "This week's record couldn't be read.")
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextSecondary)
                Button("Try Again") { Task { await load() } }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        case .ready(let record):
            page(record)
        }
    }

    private func load() async {
        let week = weekEnding
        if shownWeek != week {
            shownWeek = week
            phase = model.cachedRecord(week).map(Phase.ready) ?? .loading
            grade = nil
            photoError = nil
        }
        if case .ready = phase {} else { phase = .loading }
        if !model.isLoaded { await model.load() }
        let record = await model.record(week)
        guard week == weekEnding else { return }
        guard let record else {
            phase = .missing
            return
        }
        phase = .ready(record)
        if let id = record.prediction?.id {
            let found = await model.grade(for: id)
            if week == weekEnding { grade = found }
        }
    }

    // MARK: Page

    private func page(_ record: WeekRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            photo
            Text(verbatim: WeeksModel.weekLabel(weekEnding: weekEnding, number: record.weekNumber))
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(palette.ink)
                .padding(.top, 20)
            Text(verbatim: Self.nonEmpty(record.title) ?? "Week \(record.weekNumber ?? WeekCoverCard.weekNumber(ofDay: weekEnding) ?? 0)")
                .font(AppFont.display(style: .largeTitle, weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
            if record.moments.isEmpty {
                if let story = Self.nonEmpty(record.story) {
                    saved(story, style: .title3)
                        .padding(.top, 14)
                }
                sections(record)
            } else {
                momentsSections(record)
            }
        }
    }

    @ViewBuilder private func sections(_ record: WeekRecord) -> some View {
        if !record.energy.gave.isEmpty || !record.energy.drained.isEmpty {
            section("Energy") {
                VStack(alignment: .leading, spacing: 12) {
                    chips("Gave you energy", record.energy.gave)
                    chips("Drained you", record.energy.drained)
                }
            }
        }
        if let deep = record.deep, let answer = Self.nonEmpty(deep.answer) {
            section(Self.nonEmpty(deep.rotation) ?? "The deep question") {
                VStack(alignment: .leading, spacing: 8) {
                    if let question = Self.nonEmpty(deep.question) {
                        Text(verbatim: question)
                            .font(AppFont.display(style: .headline, weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    saved(answer)
                }
            }
        }
        let scored = record.values.filter { $0.score != nil }
        if !scored.isEmpty {
            section("Values") {
                FlowRow(spacing: 8) {
                    ForEach(scored) { value in
                        let name = value.name ?? value.id.capitalized
                        HXChip(paper: palette.colors, label: "\(name) \(value.score ?? 0)")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(verbatim: "\(name), \(value.score ?? 0) of 10"))
                    }
                }
            }
        }
        if let oneThing = Self.nonEmpty(record.oneThing?.text) {
            section("The one thing") { saved(oneThing) }
        }
        if !record.who.isEmpty {
            section("Who to see") {
                Text(verbatim: record.who.map(\.name).joined(separator: ", "))
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let note = record.note, let text = Self.nonEmpty(note.text) {
            noteRow(text: text, opensOn: note.opensOn)
                .padding(.top, 28)
        }
        if let prediction = record.prediction, let text = Self.nonEmpty(prediction.text) {
            section("Your prediction") { predictionView(prediction, text: text) }
        }
    }

    // MARK: Photo

    /// Taller once there's a photo; a quiet dusk wash until then, which opens the library.
    @ViewBuilder private var photo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if loadsPhoto {
                    WeekPhotoImage(server: model.server, sessionID: model.sessionID, path: WeeksModel.photoPath(weekEnding),
                                   version: model.photoVersion(for: weekEnding), hasPhoto: $showsLoadedPhoto,
                                   load: { await model.photoData(path: $0) }) { photoPlaceholder }
                        .frame(height: 200)
                        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous))
                        // `.disabled` doesn't reach a context menu; an empty one doesn't open.
                        .contextMenu { if !isBusyWithPhoto { photoMenuItems } }
                        .accessibilityElement()
                        .accessibilityLabel(Text(verbatim: "Photo of the week"))
                        .accessibilityAddTraits(.isImage)
                        .accessibilityHint(Text(verbatim: "Touch and hold to replace or remove it"))
                } else {
                    Button { showsPhotoPicker = true } label: { photoPlaceholder.frame(height: 110) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: "Add a photo of the week"))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous))
            .overlay {
                if isBusyWithPhoto {
                    RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay { ProgressView() }
                }
            }
            .disabled(isBusyWithPhoto)
            if let photoError {
                Text(verbatim: photoError)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxDanger)
            }
        }
    }

    private var photoPlaceholder: some View {
        Color.clear
            .glowSurface(palette.colors, cornerRadius: HXRadius.lg)
            .overlay {
                Image(systemName: palette.symbol)
                    .font(AppFont.title())
                    .foregroundStyle(palette.ink.opacity(0.5))
                    .accessibilityHidden(true)
            }
    }

    /// Replace (or add) and remove: on the photo as a context menu, and in the toolbar.
    @ViewBuilder private var photoMenuItems: some View {
        Button { showsPhotoPicker = true } label: {
            Label(hasPhoto ? "Replace Photo" : "Add a Photo", systemImage: "photo.on.rectangle")
        }
        if hasPhoto {
            Button(role: .destructive) { confirmsRemoval = true } label: {
                Label("Remove Photo", systemImage: "trash")
            }
        }
    }

    private var photoMenu: some View {
        Menu {
            photoMenuItems
        } label: {
            Image(systemName: "photo")
        }
        .disabled(isBusyWithPhoto)
        .accessibilityLabel(Text(verbatim: "Photo of the week"))
    }

    private func upload(_ item: PhotosPickerItem) async {
        isBusyWithPhoto = true
        photoError = nil
        defer { isBusyWithPhoto = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let jpeg = await Task.detached(priority: .userInitiated, operation: { WeekPhoto.jpeg(from: data) }).value
        else {
            photoError = "That photo couldn't be read. Pick another."
            return
        }
        do {
            try await model.setPhoto(jpeg, for: weekEnding)
        } catch {
            photoError = WeekPhoto.errorMessage(error, removing: false)
        }
    }

    private func removePhoto() async {
        isBusyWithPhoto = true
        photoError = nil
        defer { isBusyWithPhoto = false }
        do {
            try await model.removePhoto(for: weekEnding)
        } catch {
            photoError = WeekPhoto.errorMessage(error, removing: true)
        }
    }

    // MARK: Sections

    func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: title)
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 28)
    }

    /// Words he wrote and kept, in serif.
    func saved(_ text: String, style: Font.TextStyle = .body) -> some View {
        Text(verbatim: text)
            .font(AppFont.serif(style: style))
            .foregroundStyle(Color.hxTextPrimary)
            .lineSpacing(style == .body ? 3 : 5)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func chips(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                FlowRow(spacing: 6) {
                    ForEach(items, id: \.self) { HXChip(paper: palette.colors, label: $0, lines: 2) }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Sealed until the day it opens, then his words.
    func noteRow(text: String, opensOn: String?) -> some View {
        let isOpen = opensOn.map { $0 <= model.today } ?? true
        let opens = opensOn.map(WeeksModel.dayLabel)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: isOpen ? "envelope.open" : "envelope.fill")
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .frame(width: 36, height: 36)
                    .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "A note to the future")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                    Text(verbatim: isOpen ? (opens.map { "Opened \($0)" } ?? "Opened") : "Sealed · opens \(opens ?? "")")
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                }
                Spacer(minLength: 0)
            }
            if isOpen { saved(text) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous).strokeBorder(palette.colors.edge, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func predictionView(_ prediction: WeekRecord.Prediction, text: String) -> some View {
        let meta = [prediction.probability.map { "\($0)%" }, prediction.due.map { "due \(WeeksModel.dayLabel($0))" }]
            .compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: text)
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !meta.isEmpty {
                Text(verbatim: meta)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
                    .monospacedDigit()
            }
            if let grade, let label = Self.gradeLabels[grade] {
                HXChip(paper: palette.colors, symbol: label.symbol, label: "Graded · \(label.title)")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static let gradeLabels: [String: (title: String, symbol: String)] = [
        "hit": ("Hit", "checkmark"), "partly": ("Partly", "circle.lefthalf.filled"), "miss": ("Miss", "xmark")
    ]

    static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

// MARK: Moments record

/// A moments record (`WeekRecord.moments` non-empty): the week as he sealed it, in the order of
/// the review: moments, how it ended, last week's intention, what he reflected on, each value,
/// next week's intention, and the note. A section with nothing in it is left out.
extension WeekPageView {
    @ViewBuilder func momentsSections(_ record: WeekRecord) -> some View {
        section("Moments") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(record.moments.enumerated()), id: \.offset) { _, moment in
                    momentRow(moment)
                }
                if let ended = Self.nonEmpty(record.ended) {
                    (Text(verbatim: "Ended: ").foregroundStyle(palette.ink).fontWeight(.semibold)
                        + Text(verbatim: ended).foregroundStyle(Color.hxTextPrimary))
                        .font(AppFont.subheadline())
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
        }
        if let last = record.lastIntention, let text = Self.nonEmpty(last.text) {
            section("Last week") { lastIntentionView(last, text: text) }
        }
        let reflections = [record.reflect?.proud, record.reflect?.lesson].compactMap { $0 }
            .filter { Self.nonEmpty($0.answer) != nil }
        if !reflections.isEmpty {
            section("Reflect") {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(reflections.enumerated()), id: \.offset) { _, reflection in
                        VStack(alignment: .leading, spacing: 8) {
                            if let question = Self.nonEmpty(reflection.question) {
                                Text(verbatim: question)
                                    .font(AppFont.display(style: .headline, weight: .semibold))
                                    .foregroundStyle(Color.hxTextPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            saved(Self.nonEmpty(reflection.answer) ?? "")
                        }
                    }
                }
            }
        }
        let scored = record.values.filter { $0.score != nil }
        if !scored.isEmpty {
            section("Values") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(scored) { valueRow($0) }
                }
            }
        }
        if let intention = record.intention, Self.nonEmpty(intention.text) != nil {
            section("This week") { intentionView(intention) }
        }
        if let note = record.note, let text = Self.nonEmpty(note.text) {
            noteRow(text: text, opensOn: note.opensOn)
                .padding(.top, 28)
        }
    }

    private func momentRow(_ moment: WeekRecord.Moment) -> some View {
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
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [moment.day, moment.line, value ?? ""].filter { !$0.isEmpty }.joined(separator: ". ")))
    }

    /// The words of last week's intention, how it went, and what he said got in the way.
    private func lastIntentionView(_ last: WeekRecord.LastIntention, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: text)
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = last.status.flatMap({ Self.intentionStatus[$0] }) {
                HXChip(paper: palette.colors, label: status)
            }
            if let note = Self.nonEmpty(last.note) { saved(note) }
        }
        .accessibilityElement(children: .combine)
    }

    private static let intentionStatus = ["held": "Held", "partly": "Partly", "didnt": "Didn't"]

    /// A value's name and score, the week's fact, and his answer in serif.
    private func valueRow(_ value: WeekRecord.Value) -> some View {
        let name = value.name ?? value.id.capitalized
        let score = value.score ?? 0
        let fact = [value.fact?.big, value.fact?.line].compactMap(Self.nonEmpty).joined(separator: " \u{b7} ")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: name)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                HXChip(paper: palette.colors, label: "\(score)")
                    .accessibilityHidden(true)
            }
            if !fact.isEmpty {
                Text(verbatim: fact)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let answer = Self.nonEmpty(value.answer) { saved(answer) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: ["\(name), \(score) of 10", fact, Self.nonEmpty(value.answer) ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ". ")))
    }

    private func intentionView(_ intention: WeekRecord.Intention) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            saved(Self.nonEmpty(intention.text) ?? "")
            planLine("What might get in the way", intention.obstacle)
            planLine("If-then", intention.ifThen)
        }
    }

    @ViewBuilder private func planLine(_ label: String, _ text: String?) -> some View {
        if let text = Self.nonEmpty(text) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: label)
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(Color.hxTextSecondary)
                Text(verbatim: text)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
