import AVKit
import SwiftUI

/// A Tell a story card's speaking technique (wire `techniques`): one is picked before recording.
struct DeckStoryTechnique: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    /// One plain line on how to do it, shown under the picks once chosen.
    let how: String?
}

/// The four things he rates himself on after watching a telling back, filed as the answer's `scores` (1–5).
enum DeckStoryRating: String, CaseIterable, Identifiable {
    case words, voice, gestures, energy

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// The Tell a story card (DESIGN.md object key: `.story`, violet): the time of his life, the question, three
/// techniques to practise, then a minute on the front camera. Once recorded: the telling (a still on the
/// stacked card, the player once the card is open), Tell it again, a 1–5 rating per area and what he
/// noticed. The video stays on the phone (`StoryVideoStore`); the vault files the technique
/// (`statuses["technique"]`), the ratings (`scores`) and his note (`text`).
struct DeckStoryCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel
    /// Open to fill the screen: the telling plays here; on the stacked card a tap opens the card instead.
    let isOpen: Bool
    /// Opens the writing sheet for what he noticed.
    let write: () -> Void

    @State private var isRecording = false
    @State private var video: StoryVideoStore.Telling?

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
            if !card.techniques.isEmpty { techniquePicker.padding(.top, 18) }
            if let video {
                watchBack(video).padding(.top, 22)
            } else {
                recordButton.padding(.top, 24)
            }
        }
        .task(id: viewModel.date) { refresh() }
        .fullScreenCover(isPresented: $isRecording, onDismiss: refresh) {
            StoryRecordView(question: viewModel.question(for: card), kindLabel: card.kindLabel(palette),
                            technique: technique, paper: palette.colors, store: store, date: viewModel.date) { _ in
                viewModel.setStatus("recorded", "yes", for: card)
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
                Text(verbatim: how)
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
        }
    }

    private func watchBack(_ video: StoryVideoStore.Telling) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                if isOpen {
                    StoryVideoPlayer(url: video.url, version: video.modified)
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
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "What did you notice?")
                    .font(AppFont.display(style: .subheadline, weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                Button(action: write) {
                    DeckAnswerBoxLabel(text: answer?.text, prompt: "Started at the peak? Hands? Pace?", palette: palette)
                }
                .buttonStyle(.chatTactile(.card))
                .accessibilityLabel(Text(verbatim: "What did you notice?"))
                .accessibilityValue(Text(verbatim: answer?.text ?? "Not written yet"))
            }
        }
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
private struct StoryVideoPlayer: View {
    let url: URL
    let version: Date
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .task(id: version) {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                player = AVPlayer(playerItem: AVPlayerItem(url: url))
            }
            .onDisappear { player?.pause() }
            .accessibilityLabel(Text(verbatim: "Your telling"))
    }
}

/// The telling's first frame on the stacked card, under a play mark; tapping the card opens it to play.
private struct StoryVideoStill: View {
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
