import SwiftUI

/// A birthday within 30 days, on a glow card in the person paper. Lines keep their inline
/// Markdown, so a `brain://` link opens (in Nous blue: a link is a control, so the card sets no
/// paper tint).
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

/// A person's key facts (at most three) as chips in the person wash.
struct BrainProfileChips: View {
    /// Plain text: a chip is a label, not a link.
    private let chips: [String]

    init(chips: [String]) {
        self.chips = chips.map { String(BrainArticleDigestView.inlineMarkdown($0).characters) }
    }

    var body: some View {
        FlowRow(spacing: BrainStyle.s) {
            // A fixed list from one page load, so position is a stable id.
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                HXChip(paper: BrainModuleID.people.paper, label: chip)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The rest of the profile on one neutral card titled "About": each section a small header and
/// its items as compact rows whose links open, sections split by hairlines. A section shows three
/// items and "N more" for the rest. Family items like "Father: Bo Test" show the role in secondary.
struct BrainPersonAbout: View {
    fileprivate struct Section: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    fileprivate struct Row {
        let role: String?
        let text: AttributedString
    }

    private let sections: [Section]

    init(sections: [BrainPersonLayout.AboutSection]) {
        self.sections = sections.map { section in
            Section(id: section.id, title: section.title, rows: section.items.map { item in
                if section.id == "family", let split = BrainPersonLayout.roleSplit(item) {
                    return Row(role: split.role, text: BrainArticleDigestView.inlineMarkdown(split.value))
                }
                return Row(role: nil, text: BrainArticleDigestView.inlineMarkdown(item))
            })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.m) {
            BrainSectionHeader(title: "About")
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 {
                    Rectangle().fill(Color.hxSeparator).frame(height: 0.5).accessibilityHidden(true)
                }
                BrainAboutSection(section: section)
            }
        }
        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
        .padding(.vertical, BrainStyle.cardVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brainCardSurface()
    }
}

/// One About section: its header, the first three rows, and "N more" / "Show less" for the rest.
private struct BrainAboutSection: View {
    let section: BrainPersonAbout.Section
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cap = 3

    var body: some View {
        let hidden = section.rows.count - Self.cap
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            Text(verbatim: section.title)
                .font(BrainStyle.meta.weight(.semibold))
                .foregroundStyle(Color.hxTextSecondary)
                .accessibilityAddTraits(.isHeader)
            // A fixed list from one page load, so position is a stable id.
            ForEach(Array(section.rows.prefix(expanded ? section.rows.count : Self.cap).enumerated()), id: \.offset) { _, row in
                rowView(row)
            }
            if hidden > 0 {
                Button(action: toggle) {
                    Text(verbatim: expanded ? "Show less" : "\(hidden) more")
                        .font(BrainStyle.rowSubtitle.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: expanded ? "Show less in \(section.title)" : "Show \(hidden) more in \(section.title)"))
            }
        }
    }

    private func rowView(_ row: BrainPersonAbout.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BrainStyle.s) {
            if let role = row.role {
                Text(verbatim: role)
                    .foregroundStyle(Color.hxTextSecondary)
            }
            Text(row.text)
                .foregroundStyle(Color.hxTextPrimary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(BrainStyle.rowSubtitle)
        .accessibilityElement(children: .combine)
    }

    private func toggle() {
        if reduceMotion {
            expanded.toggle()
        } else {
            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        }
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
                    case .encounter:
                        BrainEncounterCard(entry: entry)
                    case .journal(let mention):
                        BrainJournalMentionCard(entry: entry, mention: mention)
                    }
                }
            }
        }
    }
}

/// One encounter on a neutral card: when, the headline, two more bullets and "N more" (or "More"
/// when the rest is prose). Tapping the card adds the remaining bullets in the same style, then the
/// prose as Markdown, where links open. A same-day journal entry sits at the foot.
struct BrainEncounterCard: View {
    let entry: BrainPersonLayout.Entry
    /// The headline and preview without links: inside the tap target they could not open.
    private let headline: AttributedString
    private let preview: [AttributedString]
    /// Every bullet after the headline, links kept, for the expanded card.
    private let bullets: [AttributedString]
    private let journalSnippet: AttributedString?
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(entry: BrainPersonLayout.Entry) {
        self.entry = entry
        self.headline = Self.unlinked(entry.headline)
        self.preview = entry.preview.map(Self.unlinked)
        self.bullets = (entry.preview + entry.rest).map(BrainArticleDigestView.inlineMarkdown)
        self.journalSnippet = entry.journal.map {
            BrainConnectionsLayout.highlighted($0.snippet, mention: $0.mention, paper: BrainModuleID.people.paper)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            Group {
                if entry.canExpand {
                    Button(action: toggle) { header }
                        .buttonStyle(.plain)
                } else {
                    header
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: accessibilityLabel))
            .accessibilityValue(Text(verbatim: entry.canExpand ? (expanded ? "Expanded" : "Collapsed") : ""))
            .accessibilityHint(Text(verbatim: entry.canExpand ? "Shows or hides every note" : ""))
            if expanded {
                if !bullets.isEmpty {
                    BrainBulletList(lines: bullets, bullet: Color.hxTextSecondary)
                }
                if !entry.extra.isEmpty {
                    MarkdownRenderer(content: entry.extra)
                }
                Button(action: toggle) {
                    Text(verbatim: "Show less")
                        .font(BrainStyle.rowSubtitle.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let journal = entry.journal, let journalSnippet {
                Rectangle().fill(Color.hxSeparator).frame(height: 0.5).accessibilityHidden(true)
                BrainFoldedJournalRow(mention: journal, snippet: journalSnippet)
            }
        }
        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
        .padding(.vertical, BrainStyle.cardVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brainCardSurface()
    }

    /// The meta line and headline, plus the preview and "N more" while collapsed; the whole row
    /// (at least a tap target tall) toggles.
    private var header: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            Text(verbatim: entry.meta)
                .brainText(.meta)
            if !entry.headline.isEmpty {
                Text(headline)
                    .brainText(.rowTitle)
                    .fontWeight(.semibold)
                    .lineLimit(expanded ? nil : 1)
            }
            if !expanded {
                if !preview.isEmpty {
                    BrainBulletList(lines: preview, bullet: Color.hxTextSecondary)
                }
                if entry.canExpand {
                    Text(verbatim: entry.moreCount > 0 ? "\(entry.moreCount) more" : "More")
                        .font(BrainStyle.rowSubtitle.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .topLeading)
        .contentShape(Rectangle())
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

/// A same-day journal entry at the foot of an encounter: the journal glyph, "Journal", and one
/// line of the day's words in serif with the name marked. Opens the day.
private struct BrainFoldedJournalRow: View {
    let mention: BrainJournalMention
    let snippet: AttributedString

    var body: some View {
        NavigationLink(value: ShellPushDestination.brainRoute(.page(.journal, mention.id))) {
            HStack(alignment: .firstTextBaseline, spacing: BrainStyle.s) {
                Image(systemName: BrainModuleID.journal.symbolName)
                    .font(BrainStyle.meta.weight(.semibold))
                    .foregroundStyle(Color.hxTextSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: "Journal")
                    .brainText(.meta)
                Text(snippet)
                    .font(AppFont.serif(style: .subheadline))
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: BrainStyle.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
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
                           bullets: ["loved the **Rothko** room", "moving to Lisbon in spring", "sister visiting",
                                     "asked about the climbing gym"],
                           body: "- loved the **Rothko** room\n- moving to Lisbon in spring\n- sister visiting\n- asked about the climbing gym\n\n_Source: invented note_"),
            BrainEncounter(id: "2026-09-25#0", date: "2026-09-25", bullets: ["dinner after the opening"],
                           body: "- dinner after the opening"),
            BrainEncounter(id: "2026-06-05#0", date: "2026-06-05", bullets: ["coffee near the park"],
                           body: "- coffee near the park")
        ],
        profile: [BrainProfileSection(label: "Family", items: ["Father: Bo Quill", "sister Mina", "Mother: Ana Quill",
                                                               "cousin Teo"]),
                  BrainProfileSection(label: "Company", items: ["Orbit Labs", "Was at Lumen before"]),
                  BrainProfileSection(label: "Likes", items: ["jazz", "climbing"])],
        questions: ["How is the move going?"],
        nextBirthday: "2026-10-26",
        journal: [BrainJournalMention(id: "journal/2026/09-September/2026-09-25.md", date: "2026-09-25",
                                      snippet: "Dinner with Dara Quill after the opening.", mention: "Dara Quill"),
                  BrainJournalMention(id: "journal/2026/09-September/2026-09-10.md", date: "2026-09-10",
                                      snippet: "Ran into Dara Quill at the market.", mention: "Dara Quill")])
    let page = BrainPage(item: BrainItem(module: .people, id: "people/dara-quill.md", title: "Dara Quill",
                                         subtitle: "college friend"),
                         facts: [BrainFact(label: "Industry", value: "Robotics")], person: person)
    let layout = BrainPersonLayout(page: page, person: person, today: .now)
    return NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.xl) {
                BrainPersonCardView(item: page.item, facts: [], subtitle: layout.subtitle)
                BrainNextTimeCard(lines: layout.nextTime)
                BrainProfileChips(chips: layout.chips)
                BrainPersonAbout(sections: layout.aboutSections)
                BrainPersonTimeline(entries: layout.timeline)
            }
            .padding(BrainStyle.l)
        }
        .background(Color.hxCanvas)
    }
}
#endif
