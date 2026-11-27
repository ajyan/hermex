import AVKit
import SwiftUI

/// A Tell a story card's speaking technique (wire `techniques`): one is picked before recording.
struct DeckStoryTechnique: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    /// One plain line on how to do it, shown under the picks once chosen.
    let how: String?
    /// Why it's offered today, when his feedback chose it: "from your notes", "your lowest-rated area".
    let why: String?
}

/// The server's hearing of a telling (`POST /api/stories/listen`): the words, and at most one observation
/// asked as a question, pointing `at` a second of the telling. Never a score.
struct StoryListen: Decodable, Equatable {
    struct Observation: Decodable, Equatable {
        let text: String?
        let at: Double?
    }
    let transcript: String?
    let observation: Observation?
}

enum StoryListenPhase: Equatable {
    case listening
    /// Why it couldn't be heard, in words that say what to do.
    case failed(String)

    static func reason(for error: Error) -> String {
        if error is StoryAudio.NoSound { return "This take has no sound. Turn the microphone on for Atlas in Settings, then tell it again." }
        if StoryKeepPhase.isOffline(error) { return "Couldn't reach your Mac. Try again when you're connected." }
        return "Your Mac couldn't hear it back just now."
    }
}

/// A telling's sound as AAC in an m4a, the upload `listen(to:for:)` sends (a minute is about 1 MB).
enum StoryAudio {
    struct NoSound: Error {}

    @Sendable static func m4a(_ video: URL) async throws -> Data {
        let asset = AVURLAsset(url: video)
        if try await asset.loadTracks(withMediaType: .audio).isEmpty { throw NoSound() }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileReadUnknown)
        }
        let out = FileManager.default.temporaryDirectory.appending(path: "story-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: out) }
        try await export.export(to: out, as: .m4a)
        return try Data(contentsOf: out)
    }
}

/// The four things he rates himself on after watching a telling back, filed as the answer's `scores` (1–5).
enum DeckStoryRating: String, CaseIterable, Identifiable {
    case words, voice, gestures, energy

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// What the story card shows under its picks (`DeckStoryStage.of`): Record or write it, his written telling,
/// or the video to watch back.
enum DeckStoryStage: Equatable {
    case record
    case written(String)
    case watch

    /// A video on the phone wins: recording after writing replaces the written telling (`listen` clears `told`).
    static func of(_ answer: DeckAnswer?, hasVideo: Bool) -> DeckStoryStage {
        if hasVideo { return .watch }
        if answer?.statuses?["told"] == "written", let telling = answer?.notes?["transcript"] { return .written(telling) }
        return .record
    }
}

/// The Tell a story card (DESIGN.md object key: `.story`, violet): the time of his life, the question, three
/// techniques to practise, then a minute on the front camera, or Write it instead. Once recorded: the telling
/// (a still on the stacked card, the player once the card is open), Tell it again, a 1–5 rating per area and
/// what he noticed. Once written: his telling (a tap edits it), Record it instead and what he noticed, with no
/// ratings, since voice, gestures and energy can't be rated from text. The video stays on the phone
/// (`StoryVideoStore`); the vault files the technique (`statuses["technique"]`), the ratings (`scores`), his
/// note (`text`) and the telling's words (`notes["transcript"]`, heard back or written).
struct DeckStoryCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel
    /// Open to fill the screen: the telling plays here; on the stacked card a tap opens the card instead.
    let isOpen: Bool
    /// Opens the writing sheet: for what he noticed (`.text`) or for the written telling (`.telling`).
    let write: (ReflectionTarget) -> Void

    @State private var isRecording = false
    @State private var video: StoryVideoStore.Telling?
    /// A second of the telling to jump to (the observation's), handed to the open card's player.
    @State private var seek: Double?
    @State private var showsTranscript = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var store: StoryVideoStore { StoryVideoStore(server: viewModel.server) }
    private var answer: DeckAnswer? { viewModel.answer(for: card) }
    private var picked: String? { answer?.statuses?["technique"] }
    private var technique: DeckStoryTechnique? { card.techniques.first { $0.id == picked } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeckKindLabel(symbol: palette.symbol, text: card.kindLabel(palette), ink: palette.secondaryInk)
            if let title = card.title {
                Text(verbatim: title)
                    .font(AppFont.display(style: .title2, weight: .bold))
                    .padding(.top, 14)
                    .accessibilityAddTraits(.isHeader)
            }
            if let place = card.context {
                Text(verbatim: place)
                    .font(AppFont.body())
                    .foregroundStyle(palette.secondaryInk)
                    .padding(.top, 2)
            }
            Rectangle().fill(palette.colors.edge).frame(height: 0.5).padding(.vertical, 16)
            if let question = viewModel.question(for: card) {
                Text(verbatim: question)
                    .font(AppFont.display(style: .headline, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let thread = card.thread {
                // Watch for: one line from his own recent notes, quoted as he wrote it (the label names the day).
                DeckThreadView(thread: DeckThread(label: thread.label, quote: thread.quote, at: nil), palette: palette)
                    .padding(12)
                    .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
                    .padding(.top, 16)
            }
            if !card.techniques.isEmpty { techniquePicker.padding(.top, 18) }
            switch DeckStoryStage.of(answer, hasVideo: video != nil) {
            case .watch:
                if let video { watchBack(video).padding(.top, 22) }
            case .written(let telling):
                writtenBack(telling).padding(.top, 22)
            case .record:
                recordButton.padding(.top, 24)
            }
        }
        .task(id: viewModel.date) { refresh() }
        .fullScreenCover(isPresented: $isRecording, onDismiss: refresh) {
            StoryRecordView(question: viewModel.question(for: card), kindLabel: card.kindLabel(palette),
                            technique: technique, paper: palette.colors, store: store, date: viewModel.date) { saved in
                viewModel.setStatus("recorded", "yes", for: card)
                viewModel.listen(to: saved, for: card)
            }
        }
    }

    private func refresh() {
        store.prune(keeping: viewModel.date)
        video = store.video(for: viewModel.date)
    }

    private var techniquePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Practice one")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(palette.secondaryInk)
            FlowRow(spacing: 6) {
                ForEach(card.techniques) { item in
                    ChoiceButton(title: item.name, isSelected: picked == item.id) {
                        viewModel.setStatus("technique", picked == item.id ? nil : item.id, for: card)
                    }
                }
            }
            if let how = technique?.how {
                Text(verbatim: [technique?.why.map { $0.prefix(1).uppercased() + $0.dropFirst() }, how].compactMap { $0 }.joined(separator: " · "))
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var recordButton: some View {
        VStack(spacing: 8) {
            Button { isRecording = true } label: {
                Label { Text(verbatim: "Record · 1 min") } icon: { Image(systemName: "video.fill") }
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(palette.onInk)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(palette.ink, in: Capsule())
            }
            .buttonStyle(.chatTactile(.capsule))
            Text(verbatim: "Prop your phone so your hands are in the shot.")
                .font(AppFont.caption())
                .foregroundStyle(palette.secondaryInk)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Button { write(.telling) } label: { Text(verbatim: "Write it instead") }
                .buttonStyle(.chatDecision(.secondary))
                .padding(.top, 4)
                .accessibilityHint(Text(verbatim: "Opens the writing sheet to tell the story in words"))
        }
    }

    /// A written telling in place of the video: his words (a tap opens them to edit), the technique, Record it
    /// instead and what he noticed. No ratings and no transcript row: the telling is already on the card.
    private func writtenBack(_ telling: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Your telling")
                    .font(AppFont.display(style: .subheadline, weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                Button { write(.telling) } label: {
                    DeckAnswerBoxLabel(text: telling, prompt: "Tell it the way you'd say it", palette: palette)
                }
                .buttonStyle(.chatTactile(.card))
                .accessibilityLabel(Text(verbatim: "Your telling"))
                .accessibilityValue(Text(verbatim: telling))
                .accessibilityHint(Text(verbatim: "Opens it to edit"))
            }
            HStack {
                if let technique { HXChip(paper: palette.colors, label: technique.name) }
                Spacer(minLength: 8)
                Button { isRecording = true } label: { Text(verbatim: "Record it instead") }
                    .buttonStyle(.chatDecision(.secondary))
                    .accessibilityHint(Text(verbatim: "Records a video telling in place of the written one"))
            }
            Rectangle().fill(palette.colors.edge).frame(height: 0.5)
            noticed
        }
    }

    private func watchBack(_ video: StoryVideoStore.Telling) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                if isOpen {
                    StoryVideoPlayer(url: video.url, version: video.modified, seek: $seek)
                } else {
                    StoryVideoStill(url: video.url, version: video.modified)
                }
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
            HStack {
                if let technique { HXChip(paper: palette.colors, label: technique.name) }
                Spacer(minLength: 8)
                Button { isRecording = true } label: { Text(verbatim: "Tell it again") }
                    .buttonStyle(.chatDecision(.secondary))
                    .accessibilityHint(Text(verbatim: "Records a new take in place of this one"))
            }
            Rectangle().fill(palette.colors.edge).frame(height: 0.5)
            ratings
            noticed
            heardBack(video)
        }
    }

    /// "What did you notice?": his note on the telling, the answer's `text`, written in the writing sheet.
    private var noticed: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "What did you notice?")
                .font(AppFont.display(style: .subheadline, weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
            Button { write(.text) } label: {
                DeckAnswerBoxLabel(text: answer?.text, prompt: "Started at the peak? Hands? Pace?", palette: palette)
            }
            .buttonStyle(.chatTactile(.card))
            .accessibilityLabel(Text(verbatim: "What did you notice?"))
            .accessibilityValue(Text(verbatim: answer?.text ?? "Not written yet"))
        }
    }

    /// What the server heard: while it listens, a line; if it couldn't, why and Try again; then the one
    /// observation (a question, with a jump to its moment on the open card) and the transcript, folded. A take
    /// recorded but never heard back (the app closed mid-listen) offers Hear it back.
    @ViewBuilder
    private func heardBack(_ video: StoryVideoStore.Telling) -> some View {
        let notes = answer?.notes ?? [:]
        switch viewModel.storyListen(for: card) {
        case .listening:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: "Listening to your telling…").font(AppFont.footnote()).foregroundStyle(palette.secondaryInk)
            }
        case .failed(let reason):
            HXFailedView(title: "Couldn't hear it back", message: reason, style: .inline) {
                viewModel.listen(to: video.url, for: card)
            }
        case nil:
            if let observation = notes["observation"] {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "From the recording")
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(palette.secondaryInk)
                    Text(verbatim: observation)
                        .font(AppFont.body())
                        .foregroundStyle(Color.hxTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isOpen, let at = notes["observationAt"].flatMap(Double.init) {
                        Button("Watch from \(Self.clock(at))") { seek = at }
                            .buttonStyle(.chatDecision(.secondary))
                            .padding(.top, 6)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
            }
            if let transcript = notes["transcript"] {
                transcriptRow(transcript)
            } else if !viewModel.storyListenUnavailable {
                Button { viewModel.listen(to: video.url, for: card) } label: { Text(verbatim: "Hear it back") }
                    .buttonStyle(.chatDecision(.secondary))
                    .accessibilityHint(Text(verbatim: "Sends the sound of this telling to your Mac for its transcript"))
            }
        }
    }

    /// The transcript folded like the idea card's parts (`DeckPartsList`): a 44 pt row with a chevron that
    /// swaps, opening on `HXMotion.disclosure`, closed by a hairline in the paper's edge.
    private func transcriptRow(_ transcript: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(HXMotion.disclosure(reduceMotion: reduceMotion)) { showsTranscript.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "Read the transcript")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                    Spacer(minLength: 8)
                    Image(systemName: showsTranscript ? "chevron.up" : "chevron.down")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(palette.secondaryInk)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(verbatim: showsTranscript ? "Open" : "Folded"))
            if showsTranscript {
                Text(verbatim: transcript)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.bottom, 12)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(palette.colors.edge).frame(height: 0.5) }
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var ratings: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "How did it go?")
                .font(AppFont.display(style: .subheadline, weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .padding(.bottom, 4)
            ForEach(DeckStoryRating.allCases) { area in
                StoryRatingRow(label: area.label, value: answer?.scores?[area.rawValue], ink: palette.ink,
                               edge: palette.colors.edge) { score in
                    viewModel.setScore(area.rawValue, score, for: card)
                }
            }
        }
    }
}

/// One area's 1–5 self-rating as five dots (DESIGN.md: numbers are dots), filled up to the score; tapping
/// the chosen dot again clears it (`DailyDeckViewModel.setScore`).
private struct StoryRatingRow: View {
    let label: String
    let value: Int?
    let ink: Color
    let edge: Color
    let set: (Int) -> Void

    var body: some View {
        HStack {
            Text(verbatim: label).font(AppFont.body()).foregroundStyle(Color.hxTextPrimary)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { score in
                    Button { set(score) } label: {
                        Circle()
                            .fill(score <= (value ?? 0) ? ink : Color.clear)
                            .overlay(Circle().strokeBorder(ink, lineWidth: 1.5))
                            .frame(width: 14, height: 14)
                            .frame(width: 32, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "\(label) \(score) of 5"))
                    .accessibilityAddTraits(score == value ? .isSelected : [])
                }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(edge).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: value.map { "\(label), \($0) of 5" } ?? "\(label), not rated"))
    }
}

/// The telling on the open card. A new player per file version, so a retake (same path) reloads; audio
/// plays out loud even with the ring switch silenced, as a video he chose to watch should.
struct StoryVideoPlayer: View {
    let url: URL
    let version: Date
    /// Set to jump there and play; cleared once done.
    @Binding var seek: Double?
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .task(id: version) {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                player = AVPlayer(playerItem: AVPlayerItem(url: url))
            }
            .onChange(of: seek) { _, at in
                guard let at else { return }
                seek = nil
                guard let player else { return }
                player.seek(to: CMTime(seconds: at, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
            }
            .onDisappear { player?.pause() }
            .accessibilityLabel(Text(verbatim: "Your telling"))
    }
}

/// The telling's first frame on the stacked card, under a play mark; tapping the card opens it to play.
struct StoryVideoStill: View {
    let url: URL
    let version: Date
    @State private var frame: UIImage?

    var body: some View {
        ZStack {
            Color.hxSurface
            if let frame {
                Image(uiImage: frame).resizable().scaledToFill()
            }
            Image(systemName: "play.fill")
                .font(AppFont.title2(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .frame(width: 56, height: 56)
                .adaptiveGlass(.regular, in: Circle())
        }
        .task(id: version) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)
            frame = (try? await generator.image(at: .zero)).map { UIImage(cgImage: $0.image) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Your telling. Open the card to play it"))
    }
}
