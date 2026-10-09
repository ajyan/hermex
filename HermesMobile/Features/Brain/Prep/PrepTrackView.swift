import SwiftUI

/// One track's path: a cover strip and summary, then each level's skills as rows
/// with a mastery ring. Pushed as `.brainRoute(.prep(.track(id)))`; owns no
/// `NavigationStack`.
struct PrepTrackView: View {
    @State private var viewModel: PrepTrackViewModel
    /// Built once per screen, never in `body`.
    private let cover: BrainCoverSpec

    init(track: String, server: URL) {
        _viewModel = State(initialValue: PrepTrackViewModel(
            track: track, client: APIClientPrepAdapter(apiClient: APIClient(baseURL: server))))
        self.cover = BrainCoverSpec.make(id: PrepCopy.coverID(track), tag: "career")
    }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: title))
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
    }

    private var title: String {
        if case .loaded(let map) = viewModel.state, !map.title.isEmpty { return map.title }
        return "Track"
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            PrepUnavailableView()
        case .failed(let message):
            PrepFailedView(title: "Couldn't load this track", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let map):
            loaded(map)
        }
    }

    private func loaded(_ map: PrepTrackMap) -> some View {
        let ringColor = BrainStyle.coverRamp(cover.ramp).strong
        return ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.xl) {
                VStack(alignment: .leading, spacing: 0) {
                    BrainCoverView(spec: cover)
                        .frame(height: 70)
                        .frame(maxWidth: .infinity)
                        .drawingGroup()
                    BrainRow(
                        title: PrepCopy.mapTitle(mastered: map.summary.mastered, total: map.summary.total),
                        subtitle: PrepCopy.mapSubtitle(problems: map.summary.problems, due: map.summary.due)
                    )
                    .padding(.horizontal, BrainStyle.cardHorizontalPadding)
                    .padding(.vertical, BrainStyle.xs)
                }
                .brainCardSurface()

                // A level's position is its identity: the server sends levels in a fixed order.
                ForEach(Array(map.levels.enumerated()), id: \.offset) { _, level in
                    VStack(alignment: .leading, spacing: BrainStyle.s) {
                        BrainSectionHeader(title: level.title, trailing: level.locked ? "Locked" : nil)
                        SectionCard {
                            VStack(spacing: 0) {
                                ForEach(Array(level.skills.enumerated()), id: \.element.id) { offset, skill in
                                    if offset > 0 { PrepRowDivider() }
                                    PrepSkillRow(skill: skill, levelLocked: level.locked, ringColor: ringColor)
                                }
                            }
                        }
                    }
                }
            }
            .padding(BrainStyle.l)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        }
        .refreshable { await viewModel.load() }
    }
}

/// A skill on the path, laid out like `BrainRow`: a mastery ring, the title (dimmed
/// when locked) and the detail, with an amber dot when the skill is weak.
private struct PrepSkillRow: View {
    let skill: PrepSkill
    let levelLocked: Bool
    let ringColor: Color
    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 6

    /// A skill in a locked level reads as locked whatever its own state says.
    private var state: PrepSkillState { levelLocked ? .locked : skill.state }

    var body: some View {
        HStack(alignment: .center, spacing: BrainStyle.m) {
            PrepMasteryRing(state: state, mastery: skill.mastery, color: ringColor)
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                Text(verbatim: skill.title)
                    .font(BrainStyle.rowTitle)
                    .foregroundStyle(state == .locked ? Color.hxTextSecondary : Color.hxTextPrimary)
                    .lineLimit(2)
                if !skill.detail.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: BrainStyle.xs + 2) {
                        if state == .weak {
                            Circle()
                                .fill(Color.hxWarning)
                                .frame(width: dot, height: dot)
                                // Sit the dot on the text's x-height, not its baseline.
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + dot / 2 }
                        }
                        Text(verbatim: skill.detail)
                            .brainText(.rowSubtitle)
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, BrainStyle.s)
        .frame(minHeight: BrainStyle.minTapTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: PrepCopy.skillLabel(
            title: skill.title, state: state, detail: skill.detail)))
    }
}

/// A 28pt ring: its trim is mastery in the track's strong cover colour on a
/// separator track. Mastered fills it with a checkmark; locked shows a lock.
/// Drawn once, never animated.
struct PrepMasteryRing: View {
    let state: PrepSkillState
    let mastery: Double
    let color: Color
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 28

    var body: some View {
        let line = max(2.5, side * 0.12)
        ZStack {
            switch state {
            case .mastered:
                Circle().fill(color)
                Image(systemName: "checkmark")
                    .font(.system(size: side * 0.45, weight: .bold))
                    .foregroundStyle(Color.hxOnAccent)
            case .locked:
                Circle().stroke(Color.hxSeparator, lineWidth: line)
                Image(systemName: "lock")
                    .font(.system(size: side * 0.42, weight: .semibold))
                    .foregroundStyle(Color.hxTextSecondary)
            default:
                Circle().stroke(Color.hxSeparator, lineWidth: line)
                Circle()
                    .trim(from: 0, to: min(max(mastery, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(line / 2)
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
