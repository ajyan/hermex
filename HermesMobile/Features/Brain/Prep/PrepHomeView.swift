import SwiftUI

/// Prep's landing screen: today's run, the tracks as cover cards, and what needs
/// work. Pushed as `.brainRoute(.prep(.home))`; owns no `NavigationStack`.
struct PrepHomeView: View {
    @State private var viewModel: PrepHomeViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(server: URL) {
        _viewModel = State(initialValue: PrepHomeViewModel(
            client: APIClientPrepAdapter(apiClient: APIClient(baseURL: server))))
    }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: "Interview prep"))
            .background(Color.hxCanvas.ignoresSafeArea())
            // Every appear refreshes quietly, so a finished run shows on the way back.
            .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            PrepUnavailableView()
        case .failed(let message):
            PrepFailedView(title: "Couldn't load Prep", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let home):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.xl) {
                    todaySection(home)
                    if !home.tracks.isEmpty { tracksSection(home.tracks) }
                    if !home.needsWork.isEmpty { needsWorkSection(home.needsWork) }
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
        }
    }

    // MARK: Today

    private func todaySection(_ home: PrepHome) -> some View {
        let action = PrepCopy.runAction(reps: home.run.reps, remaining: home.run.remaining)
        return VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Today")
            SectionCard {
                VStack(spacing: 0) {
                    HStack(spacing: BrainStyle.m) {
                        BrainRow(
                            title: "Today's run",
                            subtitle: PrepCopy.runSubtitle(
                                minutes: home.run.minutes, reps: home.run.reps, focus: home.run.focus)
                        )
                        PrepRunButton(action: action)
                    }
                    PrepRowDivider()
                    BrainRow(
                        title: PrepCopy.streakTitle(days: home.streak.days),
                        subtitle: PrepCopy.streakSubtitle(days: home.streak.days, freezes: home.streak.freezes)
                    )
                    if let readiness = home.readiness {
                        PrepRowDivider()
                        BrainRow(title: PrepCopy.readiness(readiness))
                    }
                }
            }
        }
    }

    // MARK: Tracks

    private func tracksSection(_ tracks: [PrepTrackSummary]) -> some View {
        let columns = BrainListLayout.columnCount(2, dynamicType: dynamicTypeSize)
        return VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Tracks")
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: BrainStyle.m, alignment: .top), count: columns),
                spacing: BrainStyle.m
            ) {
                ForEach(tracks) { track in
                    NavigationLink(value: ShellPushDestination.brainRoute(.prep(.track(track.id)))) {
                        PrepTrackCard(track: track)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Needs work

    private func needsWorkSection(_ items: [PrepNeedsWork]) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Needs work", count: items.count)
            SectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                        if offset > 0 { PrepRowDivider() }
                        BrainRow(
                            leading: { PrepCoverThumbnail(id: PrepCopy.coverID(item.skill)) },
                            title: item.title,
                            subtitle: item.detail
                        )
                    }
                }
            }
        }
    }
}

/// Today's run action as a small accent capsule: Start or Resume push the run;
/// Done is shown disabled once nothing is left today.
private struct PrepRunButton: View {
    let action: PrepCopy.RunAction

    var body: some View {
        let title = PrepCopy.runActionTitle(action)
        if action == .done {
            label(title, enabled: false)
                .accessibilityLabel(Text(verbatim: "Today's run is done"))
        } else {
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.run))) {
                label(title, enabled: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "\(title) today's run"))
        }
    }

    private func label(_ title: String, enabled: Bool) -> some View {
        Text(verbatim: title)
            .font(BrainStyle.rowSubtitle.weight(.semibold))
            .foregroundStyle(enabled ? Color.hxOnAccent : Color.hxTextSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, BrainStyle.l)
            .padding(.vertical, BrainStyle.s)
            .background(enabled ? Color.accentColor : Color.hxSeparator.opacity(0.6), in: Capsule())
            .frame(minHeight: BrainStyle.minTapTarget)
            .contentShape(Capsule())
    }
}

/// A track as a Brain card: cover, title, the server's subtitle, and a thin
/// progress bar. Built from the same pieces and constants as `BrainCard`.
private struct PrepTrackCard: View {
    let track: PrepTrackSummary
    /// Built once per card, never in `body`.
    private let cover: BrainCoverSpec

    init(track: PrepTrackSummary) {
        self.track = track
        self.cover = BrainCoverSpec.make(id: PrepCopy.coverID(track.id), tag: "career")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The clear base takes the card's full width at the cover ratio; the art
            // is an overlay so it can never be narrower than the card.
            Color.clear
                .aspectRatio(BrainStyle.coverAspectRatio, contentMode: .fit)
                .overlay { BrainCoverView(spec: cover).drawingGroup() }
                .clipped()
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                Text(verbatim: track.title)
                    .brainText(.rowTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !track.subtitle.isEmpty {
                    Text(verbatim: track.subtitle)
                        .brainText(.meta)
                        .lineLimit(2)
                }
                PrepProgressBar(fraction: track.progress)
                    .padding(.top, BrainStyle.xs)
            }
            .padding(.horizontal, BrainStyle.cardHorizontalPadding)
            .padding(.vertical, BrainStyle.cardVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .brainCardSurface()
        .contentShape(BrainStyle.cardShape())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [track.title, track.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityValue(Text(verbatim: "\(Int((min(max(track.progress, 0), 1) * 100).rounded())) percent"))
    }
}

/// A 3pt bar: the filled share in `.hxTextSecondary` at 55% on a separator track.
struct PrepProgressBar: View {
    let fraction: Double

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        Capsule()
            .fill(Color.hxSeparator)
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.hxTextSecondary.opacity(0.55))
                        .frame(width: proxy.size.width * clamped)
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Shared Prep pieces

/// A square cover thumbnail for a row's leading slot (40pt, scaled with Dynamic Type).
struct PrepCoverThumbnail: View {
    private let cover: BrainCoverSpec
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 40

    init(id: String) {
        self.cover = BrainCoverSpec.make(id: id, tag: "career")
    }

    var body: some View {
        BrainCoverView(spec: cover)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: BrainStyle.thumbnailCorner, style: .continuous))
            .drawingGroup()
    }
}

/// The hairline between rows inside a `SectionCard`.
struct PrepRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.hxSeparator)
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

/// The "no Prep here" state: a stock server answers the tutor API with 404.
struct PrepUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label { Text(verbatim: "No Prep on this server") } icon: { Image(systemName: "target") }
        } description: {
            Text(verbatim: "This server doesn't serve interview prep. It needs the tutor API from your hermes-webui fork.")
        }
    }
}

/// A load failure with a retry.
struct PrepFailedView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label { Text(verbatim: title) } icon: { Image(systemName: "exclamationmark.triangle") }
        } description: {
            Text(verbatim: message)
        } actions: {
            Button(action: retry) { Text(verbatim: "Try again") }
        }
    }
}
