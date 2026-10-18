import SwiftUI

/// The behavioral stories on Prep home: each active story with its three readiness marks (told
/// in time, scored 4 or better, probes held), tapping a row to drill that story on its own, and
/// a Bench row for stories waiting their turn. Hidden by the home when the server has no stories.
struct PrepStorySection: View {
    let list: PrepStoryList

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(
                title: "Stories",
                trailing: PrepCopy.storiesSubtitle(ready: list.readyCount, total: list.activeTotal))
            SectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(list.activeStories.enumerated()), id: \.element.id) { offset, story in
                        if offset > 0 { PrepRowDivider() }
                        NavigationLink(value: ShellPushDestination.brainRoute(.prep(.story(story.id)))) {
                            PrepStoryRow(story: story)
                        }
                        .buttonStyle(.plain)
                    }
                    if !list.benchStories.isEmpty {
                        if !list.activeStories.isEmpty { PrepRowDivider() }
                        BrainRow(
                            title: "Bench",
                            subtitle: list.benchStories.map(\.title).joined(separator: " · "),
                            trailing: "\(list.benchStories.count)")
                    }
                }
            }
        }
    }
}

/// One active story: its title, when it was last told, and the three marks.
private struct PrepStoryRow: View {
    let story: PrepStorySummary

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            BrainRow(
                title: story.title,
                subtitle: story.last.map { "Last told \($0)" },
                badge: story.ready ? "Ready" : nil)
            HStack(spacing: BrainStyle.m) {
                PrepStoryMark(kind: .time, value: story.marks.time)
                PrepStoryMark(kind: .score, value: story.marks.score)
                PrepStoryMark(kind: .probes, value: story.marks.probes)
            }
        }
        .padding(.vertical, BrainStyle.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A readiness mark: its word and a glyph (a check when earned, a hollow dot when not yet, a
/// quiet dash with no rep). The glyph is in the Prep paper's glow only once earned.
private struct PrepStoryMark: View {
    let kind: PrepStoryMarkKind
    let value: Bool?

    var body: some View {
        HStack(spacing: 3) {
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
