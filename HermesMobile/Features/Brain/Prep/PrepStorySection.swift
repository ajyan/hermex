import SwiftUI

/// The behavioral stories on Prep home: each active story with its three readiness marks (told
/// in time, scored 4 or better, probes held), tapping a row to drill that story on its own, then
/// the bench stories under a Bench label, drillable the same way (spec §3.1), and last a
/// Dismissed (N) row that reveals the candidates set aside with Not now, each with Add to bench.
/// Hidden by the home when the server has no stories or candidates.
struct PrepStorySection: View {
    let list: PrepStoryList
    /// Candidate ids with a verdict in flight, and why the last verdict on one failed.
    var inFlight: Set<String> = []
    var errors: [String: String] = [:]
    var onAct: (PrepStoryCandidate, PrepStoryCandidateAction) -> Void = { _, _ in }

    @State private var showsDismissed = false

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(
                title: "Stories",
                trailing: PrepCopy.storiesSubtitle(ready: list.readyCount, total: list.activeTotal))
            ForEach(list.candidates) { candidate in
                PrepStoryCandidateCard(
                    candidate: candidate, isActing: inFlight.contains(candidate.id), failure: errors[candidate.id],
                    onAct: { onAct(candidate, $0) })
            }
            if !list.stories.isEmpty {
                SectionCard {
                    VStack(spacing: 0) {
                        rows(list.activeStories)
                        if !list.benchStories.isEmpty {
                            if !list.activeStories.isEmpty { PrepRowDivider() }
                            HStack {
                                Text(verbatim: "Bench")
                                    .font(BrainStyle.meta.weight(.semibold))
                                    .foregroundStyle(Color.hxTextSecondary)
                                Spacer(minLength: BrainStyle.s)
                                Text(verbatim: "\(list.benchStories.count)")
                                    .font(BrainStyle.meta)
                                    .foregroundStyle(Color.hxTextSecondary)
                                    .monospacedDigit()
                            }
                            .padding(.top, BrainStyle.s)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)
                            rows(list.benchStories)
                        }
                    }
                }
            }
            if !list.dismissed.isEmpty {
                dismissedCard
            }
        }
    }
}

private extension PrepStorySection {
    /// "Dismissed (N)", tapping to show or hide the set-aside candidates.
    var dismissedCard: some View {
        SectionCard {
            VStack(spacing: 0) {
                Button {
                    showsDismissed.toggle()
                } label: {
                    HStack {
                        Text(verbatim: "Dismissed (\(list.dismissed.count))")
                            .font(BrainStyle.meta.weight(.semibold))
                            .foregroundStyle(Color.hxTextSecondary)
                        Spacer(minLength: BrainStyle.s)
                        Image(systemName: showsDismissed ? "chevron.up" : "chevron.down")
                            .font(BrainStyle.meta)
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                    .frame(minHeight: BrainStyle.minTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "Dismissed stories, \(list.dismissed.count)"))
                .accessibilityValue(Text(verbatim: showsDismissed ? "Shown" : "Hidden"))
                if showsDismissed {
                    ForEach(list.dismissed) { candidate in
                        PrepRowDivider()
                        PrepDismissedCandidateRow(
                            candidate: candidate, isActing: inFlight.contains(candidate.id),
                            failure: errors[candidate.id], onAdd: { onAct(candidate, .add) })
                    }
                }
            }
        }
    }

    /// One row per story, each drilling that story on its own.
    func rows(_ stories: [PrepStorySummary]) -> some View {
        ForEach(Array(stories.enumerated()), id: \.element.id) { offset, story in
            if offset > 0 { PrepRowDivider() }
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.story(story.id)))) {
                PrepStoryRow(story: story)
            }
            .buttonStyle(.plain)
        }
    }
}

/// A story the Tuesday scout found, waiting for a verdict: why it might be one, the prompt it
/// would answer, and Add to bench or Not now. A drafting candidate (the server is writing it up)
/// reads "Drafting\u{2026}" with both buttons off; so does one with a verdict on its way.
struct PrepStoryCandidateCard: View {
    let candidate: PrepStoryCandidate
    let isActing: Bool
    /// Why the last verdict failed, when it did.
    let failure: String?
    let onAct: (PrepStoryCandidateAction) -> Void

    private var isDrafting: Bool { candidate.status == "drafting" }

    @ViewBuilder
    private var buttons: some View {
        PrepCandidateButton(
            title: isDrafting ? "Drafting\u{2026}" : "Add to bench", prominent: true,
            accessibility: isDrafting ? "Drafting \(candidate.title)" : "Add \(candidate.title) to bench",
            enabled: !isDrafting && !isActing) { onAct(.add) }
        PrepCandidateButton(
            title: "Not now", prominent: false, accessibility: "Not now for \(candidate.title)",
            enabled: !isDrafting && !isActing) { onAct(.dismiss) }
    }

    var body: some View {
        let paper = HermexPaper.knowledge
        HXCard(.wash(paper), title: candidate.title, spacing: BrainStyle.s, kicker: {
            HXChip(paper: paper, label: "That's a story") { EmptyView() }
        }, content: {
            if let prompt = candidate.forPrompt, !prompt.isEmpty {
                Text(verbatim: "For: \(prompt)")
                    .font(BrainStyle.rowSubtitle)
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let why = candidate.why, !why.isEmpty {
                Text(verbatim: why)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = failure ?? candidate.error, !message.isEmpty {
                Text(verbatim: message)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }, footer: {
            // Side by side when they fit; stacked at accessibility text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BrainStyle.s) { buttons }
                VStack(alignment: .leading, spacing: BrainStyle.s) { buttons }
            }
        })
        .accessibilityElement(children: .contain)
    }
}

/// A candidate set aside with Not now: its title, the prompt it would answer, and Add to bench.
private struct PrepDismissedCandidateRow: View {
    let candidate: PrepStoryCandidate
    let isActing: Bool
    let failure: String?
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BrainStyle.m) {
                    BrainRow(title: candidate.title, subtitle: subtitle)
                    button
                }
                VStack(alignment: .leading, spacing: BrainStyle.s) {
                    BrainRow(title: candidate.title, subtitle: subtitle)
                    button
                }
            }
            if let failure, !failure.isEmpty {
                Text(verbatim: failure)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, BrainStyle.xs)
        .accessibilityElement(children: .contain)
    }

    private var subtitle: String? { candidate.forPrompt.flatMap { $0.isEmpty ? nil : "For: \($0)" } }

    private var button: some View {
        PrepCandidateButton(
            title: "Add to bench", prominent: true, accessibility: "Add \(candidate.title) to bench",
            enabled: !isActing) { onAdd() }
    }
}

/// A capsule button on the candidate card: accent when prominent, quiet otherwise, dimmed when off.
private struct PrepCandidateButton: View {
    let title: String
    let prominent: Bool
    let accessibility: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(BrainStyle.rowSubtitle.weight(.semibold))
                .foregroundStyle(prominent && enabled ? Color.hxOnAccent : Color.hxTextSecondary)
                .lineLimit(1)
                .padding(.horizontal, BrainStyle.l)
                .padding(.vertical, BrainStyle.s)
                .background(
                    prominent && enabled ? Color.accentColor : Color.hxSeparator.opacity(0.6), in: Capsule())
                .frame(minHeight: BrainStyle.minTapTarget)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(verbatim: accessibility))
    }
}

/// One story: its title, when it was last told, and the three marks.
private struct PrepStoryRow: View {
    let story: PrepStorySummary

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            BrainRow(
                title: story.title,
                subtitle: story.last.map { "Last told \($0)" },
                badge: story.ready ? "Ready" : nil)
            // One line when it fits; stacked at accessibility text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BrainStyle.m) { marks }
                VStack(alignment: .leading, spacing: BrainStyle.xs) { marks }
            }
        }
        .padding(.vertical, BrainStyle.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var marks: some View {
        PrepStoryMark(kind: .time, value: story.marks.time)
        PrepStoryMark(kind: .score, value: story.marks.score)
        PrepStoryMark(kind: .probes, value: story.marks.probes)
    }
}

/// A readiness mark: its word and a glyph (a check when earned, a hollow dot when not yet, a
/// quiet dash with no rep). The glyph is in the Prep paper's glow only once earned.
private struct PrepStoryMark: View {
    let kind: PrepStoryMarkKind
    let value: Bool?

    var body: some View {
        HStack(spacing: BrainStyle.xs) {
            Text(verbatim: kind.rawValue.capitalized)
                .font(BrainStyle.meta)
                .foregroundStyle(Color.hxTextSecondary)
            Text(verbatim: PrepCopy.storyMarkSymbol(value))
                .font(BrainStyle.meta.weight(.semibold))
                .foregroundStyle(value == true ? HermexPaper.knowledge.glow : Color.hxTextSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: PrepCopy.storyMarkLabel(kind, value)))
    }
}
