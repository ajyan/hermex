import SwiftUI

/// One filed telling of the week on the Sunday pick card (wire `tellings`), with his own 1–5 ratings.
struct DeckStoryTelling: Decodable, Equatable, Identifiable {
    let date: String
    let age: Int?
    let technique: String?
    let question: String?
    let words: Int?
    let voice: Int?
    let gestures: Int?
    let energy: Int?

    var id: String { date }

    /// His ratings in the card's column order, nil where he didn't rate.
    var ratings: [Int?] { [words, voice, gestures, energy] }

    /// "Mon" for the row's lead.
    var weekday: String {
        let parse = DateFormatter()
        parse.calendar = Calendar(identifier: .gregorian)
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let day = parse.date(from: date) else { return date }
        return day.formatted(.dateTime.weekday(.abbreviated))
    }
}

/// The Sunday pick's upload, while it runs or after it failed.
enum StoryKeepPhase: Equatable {
    case saving(String)
    case removing(String)
    /// The date that couldn't be kept, and why.
    case failed(String, String)
    /// The date that couldn't come off the Mac, and why.
    case removeFailed(String, String)

    static func reason(for error: Error) -> String {
        if error is StoryKeepError { return "That telling is no longer on this phone." }
        if StoryKeepPhase.isOffline(error) { return "Couldn't reach your Mac. Try again when you're connected." }
        if case APIError.http(statusCode: 404, _) = error { return "Your Mac can't keep tellings yet." }
        return "Your Mac couldn't save it just now."
    }
}

enum StoryKeepError: Error { case gone }

extension StoryKeepPhase {
    /// No connection, raw or as the API client wraps it.
    static func isOffline(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case APIError.network = error { return true }
        return false
    }
}

/// The Sunday review's Keep your best telling card, in the story card's paper (`.story`): the week's tellings,
/// each with its still (tap to watch), the technique and his four ratings as pips under fixed columns; pick one,
/// say what you liked, Keep this one uploads it to the Mac. Kept, it says so and offers to take it off. A
/// telling past its 7 days on the phone can't be picked.
struct DeckStoryPickCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel
    /// Opens the writing sheet for what he liked.
    let write: () -> Void

    @State private var selected: String?
    @State private var playing: StoryVideoStore.Telling?
    /// The week's videos still on the phone, read once per deck (and after a keep), not on every redraw.
    @State private var videos: [String: StoryVideoStore.Telling] = [:]
    @State private var confirmsRemoval = false

    private var store: StoryVideoStore { StoryVideoStore(server: viewModel.server) }
    private var answer: DeckAnswer? { viewModel.answer(for: card) }
    private var kept: String? { answer?.statuses?["kept"] }
    private var choice: String? { selected ?? kept }
    private var phase: StoryKeepPhase? { viewModel.storyKeep(for: card) }
    private var isBusy: Bool {
        switch phase { case .saving, .removing: true; default: false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeckKindLabel(symbol: palette.symbol, text: card.reason ?? palette.name, ink: palette.secondaryInk)
            Text(verbatim: card.title ?? "Keep your best telling")
                .font(AppFont.display(style: .title2, weight: .bold))
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            columns.padding(.top, 16)
            ForEach(card.tellings) { telling in
                row(telling)
            }
            if choice != nil || !(answer?.text ?? "").isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "What did you like about it?")
                        .font(AppFont.display(style: .subheadline, weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                    Button(action: write) {
                        DeckAnswerBoxLabel(text: answer?.text, prompt: "The opening? The pause? Your hands?", palette: palette)
                    }
                    .buttonStyle(.chatTactile(.card))
                    .accessibilityLabel(Text(verbatim: "What did you like about it?"))
                    .accessibilityValue(Text(verbatim: answer?.text ?? "Not written yet"))
                }
                .padding(.top, 20)
            }
            keepControls.padding(.top, 20)
        }
        .task(id: viewModel.date) { refresh() }
        .onChange(of: kept) { refresh() }
        .sheet(item: $playing) { telling in
            StoryVideoPlayer(url: telling.url, version: telling.modified, seek: .constant(nil))
                .ignoresSafeArea()
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Take it off your Mac?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Delete the only copy", role: .destructive) { remove() }
        } message: {
            Text(verbatim: "This telling is no longer on your phone, so this deletes the only copy.")
        }
    }

    private func refresh() {
        var found: [String: StoryVideoStore.Telling] = [:]
        for telling in card.tellings { found[telling.date] = store.video(for: telling.date) }
        videos = found
    }

    private func remove() {
        viewModel.unkeepTelling(for: card)
        selected = nil
    }

    /// The four rating columns' names over the rows' pips, so every row lines up.
    private var columns: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 40, height: 1)
            HStack(spacing: 8) {
                ForEach(DeckStoryRating.allCases) { area in
                    Text(verbatim: area.label)
                        .font(AppFont.caption2())
                        .foregroundStyle(palette.secondaryInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 48, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private func row(_ telling: DeckStoryTelling) -> some View {
        let video = videos[telling.date]
        let isChosen = choice == telling.date
        return HStack(alignment: .center, spacing: 12) {
            Button {
                playing = video
            } label: {
                ZStack {
                    if let video {
                        StoryVideoStill(url: video.url, version: video.modified)
                    } else {
                        palette.colors.wash
                        Image(systemName: "video.slash").font(AppFont.caption()).foregroundStyle(palette.secondaryInk)
                    }
                }
                .frame(width: 40, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: HXRadius.xs, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(video == nil)
            .accessibilityLabel(Text(verbatim: "Watch \(telling.weekday)'s telling"))
            Button {
                selected = telling.date
                viewModel.clearStoryKeepFailure(for: card)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: [telling.weekday, telling.age.map { "You were \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                        Text(verbatim: video == nil ? "Not on this phone" : telling.technique ?? "")
                            .font(AppFont.footnote())
                            .foregroundStyle(palette.secondaryInk)
                        HStack(spacing: 8) {
                            ForEach(Array(telling.ratings.enumerated()), id: \.offset) { _, value in
                                StoryPips(value: value, ink: palette.ink, edge: palette.colors.edge)
                                    .frame(width: 48, alignment: .leading)
                            }
                        }
                        .padding(.top, 2)
                        if kept == telling.date {
                            HXChip(paper: palette.colors, symbol: "checkmark", label: "On your Mac").padding(.top, 4)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                        .font(AppFont.title3())
                        .foregroundStyle(isChosen ? palette.ink : palette.colors.edge)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy || (video == nil && kept != telling.date))
            .accessibilityLabel(Text(verbatim: Self.summary(telling, kept: kept == telling.date)))
            .accessibilityAddTraits(isChosen ? .isSelected : [])
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(palette.colors.edge).frame(height: 0.5) }
    }

    @ViewBuilder
    private var keepControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch phase {
            case .saving:
                busy("Saving to your Mac…")
            case .removing:
                busy("Taking it off your Mac…")
            case .failed(_, let reason):
                HXFailedView(title: "Couldn't keep it", message: reason, style: .inline) {
                    if let choice { viewModel.keepTelling(choice, for: card) }
                }
            case .removeFailed(_, let reason):
                HXFailedView(title: "Couldn't take it off your Mac", message: reason, style: .inline) {
                    viewModel.unkeepTelling(for: card)
                }
            case nil:
                EmptyView()
            }
            if !isBusy {
                if let choice, choice == kept {
                    Button("Take it off your Mac") {
                        if videos[choice] == nil { confirmsRemoval = true } else { remove() }
                    }
                    .font(AppFont.footnote(weight: .semibold))
                    .frame(minHeight: 44)
                } else if let choice, videos[choice] != nil, !isFailure {
                    Button {
                        viewModel.keepTelling(choice, for: card)
                    } label: {
                        Text(verbatim: "Keep this one")
                            .font(AppFont.body(weight: .semibold))
                            .foregroundStyle(palette.onInk)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(palette.ink, in: Capsule())
                    }
                    .buttonStyle(.chatTactile(.capsule))
                }
                Text(verbatim: "Keeping one saves it to your Mac, in place of any other this week. The rest leave your phone a week after their day.")
                    .font(AppFont.caption())
                    .foregroundStyle(palette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isFailure: Bool {
        switch phase { case .failed: true; default: false }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(verbatim: text).font(AppFont.footnote()).foregroundStyle(palette.secondaryInk)
        }
    }

    private static func summary(_ telling: DeckStoryTelling, kept: Bool) -> String {
        let rated = zip(DeckStoryRating.allCases, telling.ratings).compactMap { area, value in
            value.map { "\(area.label) \($0) of 5" }
        }
        return ([telling.weekday, telling.age.map { "you were \($0)" }, telling.technique].compactMap { $0 } + rated
                + (kept ? ["kept on your Mac"] : []))
            .joined(separator: ", ")
    }
}

/// A rating as five small pips (DESIGN.md: numbers are dots): filled to the score, rings after; faint edge rings
/// when he didn't rate it.
private struct StoryPips: View {
    let value: Int?
    let ink: Color
    /// The ring for an unrated area, so it never reads as a low score.
    let edge: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { n in
                Circle()
                    .fill(n <= (value ?? 0) ? ink : Color.clear)
                    .overlay(Circle().strokeBorder(value == nil ? edge : ink, lineWidth: 1))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

extension StoryVideoStore.Telling: Identifiable {
    var id: URL { url }
}
