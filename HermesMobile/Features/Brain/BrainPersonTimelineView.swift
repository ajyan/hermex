import SwiftUI

/// What to bring up the next time you see someone: open questions and a near birthday, on a
/// glow card in the person paper. Lines keep their inline Markdown, so a `brain://` link opens
/// (in Nous blue: a link is a control, so the card sets no paper tint).
struct BrainNextTimeCard: View {
    private let lines: [AttributedString]

    init(lines: [String]) {
        self.lines = lines.map(BrainArticleDigestView.inlineMarkdown)
    }

    var body: some View {
        let paper = BrainModuleID.people.paper
        let shape = RoundedRectangle(cornerRadius: HXRadius.xl, style: .continuous)
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            Text(verbatim: "Next time")
                .font(AppFont.display(style: .headline, weight: .semibold))
                .foregroundStyle(paper.glow)
                .accessibilityAddTraits(.isHeader)
            BrainBulletList(lines: lines, bullet: paper.glow)
        }
        .padding(BrainStyle.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(paper.card, in: shape)
        .overlay(shape.strokeBorder(paper.edge, lineWidth: 0.5))
        .hxShadow(.paper)
    }
}

/// A person's profile: short items as chips in the person wash, longer ones as a list under them.
struct BrainProfileChips: View {
    /// Plain text: a chip is a label, not a link.
    private let chips: [String]
    private let longItems: [AttributedString]

    init(chips: [String], longItems: [String]) {
        self.chips = chips.map { String(BrainArticleDigestView.inlineMarkdown($0).characters) }
        self.longItems = longItems.map(BrainArticleDigestView.inlineMarkdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.m) {
            if !chips.isEmpty {
                FlowRow(spacing: BrainStyle.s) {
                    // A fixed list from one page load, so position is a stable id.
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                        HXChip(paper: BrainModuleID.people.paper, label: chip)
                    }
                }
            }
            if !longItems.isEmpty {
                BrainBulletList(lines: longItems, bullet: Color.hxTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Timeline": a person's encounters and the journal days that name them, newest first.
struct BrainPersonTimeline: View {
    let entries: [BrainPersonLayout.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Timeline", count: entries.count)
            LazyVStack(alignment: .leading, spacing: BrainStyle.s) {
                ForEach(entries) { entry in
                    switch entry.kind {
                    case .encounter(let encounter):
                        BrainEncounterCard(entry: entry, encounter: encounter)
                    case .journal(let mention):
                        BrainJournalMentionCard(entry: entry, mention: mention)
                    }
                }
            }
        }
    }
}

/// One encounter on a neutral card: when, the headline, two more bullets and "N more". Tapping
/// the card swaps the preview for the encounter's full Markdown, where its links open.
struct BrainEncounterCard: View {
    let entry: BrainPersonLayout.Entry
    private let markdown: String
    /// The headline and preview without links: inside the tap target they could not open.
    private let headline: AttributedString
    private let preview: [AttributedString]
    /// Untitled encounters lead with their first bullet, which the full Markdown repeats.
    private let keepsHeadlineExpanded: Bool
    private let canExpand: Bool
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(entry: BrainPersonLayout.Entry, encounter: BrainEncounter) {
        self.entry = entry
        self.markdown = encounter.body
        self.headline = Self.unlinked(entry.headline)
        self.preview = entry.preview.map(Self.unlinked)
        self.keepsHeadlineExpanded = !(encounter.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.canExpand = !encounter.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: BrainStyle.xs) {
                    Text(verbatim: entry.meta)
                        .brainText(.meta)
                    if !entry.headline.isEmpty, !expanded || keepsHeadlineExpanded {
                        Text(headline)
                            .brainText(.rowTitle)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }
                    if !expanded {
                        if !preview.isEmpty {
                            BrainBulletList(lines: preview, bullet: Color.hxTextSecondary)
                        }
                        if entry.moreCount > 0 {
                            Text(verbatim: "\(entry.moreCount) more")
                                .font(BrainStyle.rowSubtitle.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: accessibilityLabel))
            .accessibilityValue(Text(verbatim: canExpand ? (expanded ? "Expanded" : "Collapsed") : ""))
            .accessibilityHint(Text(verbatim: canExpand ? "Shows or hides every note" : ""))
            if expanded {
                MarkdownRenderer(content: markdown)
            }
        }
        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
        .padding(.vertical, BrainStyle.cardVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brainCardSurface()
    }

    /// "Oct 8, 2026 · 6 days ago. Gallery crawl. 2 more notes."
    private var accessibilityLabel: String {
        var parts = [entry.meta, String(headline.characters)].filter { !$0.isEmpty }
        if !expanded, entry.moreCount > 0 {
            parts.append("\(entry.moreCount) more \(entry.moreCount == 1 ? "note" : "notes")")
        }
        return parts.map { $0 + "." }.joined(separator: " ")
    }

    private func toggle() {
        if reduceMotion {
            expanded.toggle()
        } else {
            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        }
    }

    private static func unlinked(_ text: String) -> AttributedString {
        var attributed = BrainArticleDigestView.inlineMarkdown(text)
        for run in attributed.runs where run.link != nil {
            attributed[run.range].link = nil
        }
        return attributed
    }
}

/// A journal day that names the person: lighter than an encounter, on a dashed hairline, with
/// the day's words in serif and the name marked in the person paper. Opens the day.
struct BrainJournalMentionCard: View {
    let entry: BrainPersonLayout.Entry
    let mention: BrainJournalMention
    private let snippet: AttributedString

    init(entry: BrainPersonLayout.Entry, mention: BrainJournalMention) {
        self.entry = entry
        self.mention = mention
        self.snippet = BrainConnectionsLayout.highlighted(entry.headline, mention: mention.mention,
                                                          paper: BrainModuleID.people.paper)
    }

    var body: some View {
        let shape = BrainStyle.cardShape()
        NavigationLink(value: ShellPushDestination.brainRoute(.page(.journal, mention.id))) {
            HStack(alignment: .firstTextBaseline, spacing: BrainStyle.m) {
                Image(systemName: BrainModuleID.journal.symbolName)
                    .font(BrainStyle.meta.weight(.semibold))
                    .foregroundStyle(Color.hxTextSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: BrainStyle.xs) {
                    Text(verbatim: entry.meta)
                        .brainText(.meta)
                    if !entry.headline.isEmpty {
                        Text(snippet)
                            .font(AppFont.serif(style: .subheadline))
                            .foregroundStyle(Color.hxTextPrimary)
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(BrainStyle.meta.weight(.semibold))
                    .foregroundStyle(Color.hxTextSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, BrainStyle.cardHorizontalPadding)
            .padding(.vertical, BrainStyle.cardVerticalPadding)
            .frame(minHeight: BrainStyle.minTapTarget)
            .background(Color.hxCanvas, in: shape)
            .overlay(shape.strokeBorder(Color.hxSeparator, style: StrokeStyle(lineWidth: 0.5, dash: [4, 3])))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
    }
}

/// Lines with a leading dot, the dot decorative.
private struct BrainBulletList: View {
    let lines: [AttributedString]
    let bullet: Color

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            // A fixed list from one page load, so position is a stable id.
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: BrainStyle.s) {
                    Text(verbatim: "•")
                        .foregroundStyle(bullet)
                        .accessibilityHidden(true)
                    Text(line)
                        .foregroundStyle(Color.hxTextPrimary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(BrainStyle.rowSubtitle)
            }
        }
    }
}

#if DEBUG
#Preview("Person timeline") {
    let person = BrainPerson(
        encounters: [
            BrainEncounter(id: "2026-10-08#0", date: "2026-10-08", title: "Gallery crawl",
                           bullets: ["- loved the **Rothko** room", "- moving to Lisbon in spring", "- sister visiting",
                                     "- asked about the climbing gym"],
                           body: "- loved the **Rothko** room\n- moving to Lisbon in spring\n- sister visiting\n- asked about the climbing gym"),
            BrainEncounter(id: "2026-06-05#0", date: "2026-06-05", bullets: ["- coffee near the park"],
                           body: "- coffee near the park")
        ],
        profile: [BrainProfileSection(label: "Family", items: ["sister Mina"]),
                  BrainProfileSection(label: "Company", items: ["Orbit Labs"])],
        questions: ["How is the move going?"],
        nextBirthday: "2026-10-26",
        journal: [BrainJournalMention(id: "journal/2026/09-September/2026-09-25.md", date: "2026-09-25",
                                      snippet: "Dinner with Dara Quill after the opening.", mention: "Dara Quill")])
    let page = BrainPage(item: BrainItem(module: .people, id: "people/dara-quill.md", title: "Dara Quill",
                                         subtitle: "college friend"),
                         facts: [BrainFact(label: "Industry", value: "Robotics")], person: person)
    let layout = BrainPersonLayout(page: page, person: person, today: .now)
    return NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.xl) {
                BrainPersonCardView(item: page.item, facts: [], subtitle: layout.subtitle)
                BrainNextTimeCard(lines: layout.nextTime)
                BrainProfileChips(chips: layout.chips, longItems: layout.longItems)
                BrainPersonTimeline(entries: layout.timeline)
            }
            .padding(BrainStyle.l)
        }
        .background(Color.hxCanvas)
    }
}
#endif
