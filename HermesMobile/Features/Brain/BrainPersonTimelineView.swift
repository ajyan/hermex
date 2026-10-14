import SwiftUI

/// "Catch up": the nightly digest's recap and its lines (a near birthday, then the open
/// threads) on a glow card in the person paper, like a Daily Brief card. Lines keep their
/// inline Markdown, so a `brain://` link opens (in Nous blue: a link is a control, so the card
/// sets no paper tint).
struct BrainCatchUpCard: View {
    private let summary: AttributedString?
    private let lines: [AttributedString]

    init(catchUp: BrainPersonLayout.CatchUp) {
        self.summary = catchUp.summary.map(BrainArticleDigestView.inlineMarkdown)
        self.lines = catchUp.lines.map(BrainArticleDigestView.inlineMarkdown)
    }

    var body: some View {
        let paper = BrainModuleID.people.paper
        let shape = RoundedRectangle(cornerRadius: HXRadius.xl, style: .continuous)
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            Text(verbatim: "Catch up")
                .font(AppFont.display(style: .headline, weight: .semibold))
                .foregroundStyle(paper.glow)
                .accessibilityAddTraits(.isHeader)
            if let summary {
                Text(summary)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !lines.isEmpty {
                BrainBulletList(lines: lines, marker: "·", markerColor: paper.glow, textColor: paper.glow,
                                font: AppFont.subheadline(weight: .medium))
            }
        }
        .padding(BrainStyle.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(paper.card, in: shape)
        .overlay(shape.strokeBorder(paper.edge, lineWidth: 0.5))
        .hxShadow(.paper)
    }
}

/// The last twelve months as dots, oldest first: filled in the person glow for a month they
/// were seen, a hairline-gray dot otherwise, the first and last month named at the ends.
/// VoiceOver reads it as one line ("Seen in 4 of the last 12 months").
struct BrainRhythmStrip: View {
    let months: [BrainPersonLayout.RhythmMonth]
    let accessibilityLabel: String
    @ScaledMetric(relativeTo: .caption) private var dot: CGFloat = 8

    var body: some View {
        let glow = BrainModuleID.people.paper.glow
        HStack(spacing: BrainStyle.s) {
            if let first = months.first {
                Text(verbatim: first.label).brainText(.meta)
            }
            HStack(spacing: BrainStyle.xs) {
                ForEach(months) { month in
                    Circle()
                        .fill(month.seen ? glow : Color.hxSeparator)
                        .frame(width: dot, height: dot)
                }
            }
            if let last = months.last {
                Text(verbatim: last.label).brainText(.meta)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
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

/// The rest of the profile under "About", on one neutral card: each section a sentence-case
/// header and its items as compact rows whose links open, sections split by hairlines. A section
/// shows three items and "+ N more" for the rest. Family items like "Father: Bo Test" show the
/// role in secondary.
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
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            HXSectionHeader(title: "About")
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: BrainStyle.m) {
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
}

/// One About section: its header, the first three rows, and "+ N more" / "Show less" for the rest.
private struct BrainAboutSection: View {
    let section: BrainPersonAbout.Section
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cap = 3

    var body: some View {
        let hidden = section.rows.count - Self.cap
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            HXSectionHeader(title: section.title)
            // A fixed list from one page load, so position is a stable id.
            ForEach(Array(section.rows.prefix(expanded ? section.rows.count : Self.cap).enumerated()), id: \.offset) { _, row in
                rowView(row)
            }
            if hidden > 0 {
                Button(action: toggle) {
                    // The review summary's "+ N more" row, in Nous blue since it is a control.
                    Text(verbatim: expanded ? "Show less" : "+ \(hidden) more")
                        .font(AppFont.subheadline())
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

/// "Timeline · 1 of 8" over a swipe deck (`CardStack`) of a person's encounters and the journal
/// days that name them, newest first, one fixed-height `BrainDeckCard` each.
struct BrainPersonTimeline: View {
    let entries: [BrainPersonLayout.Entry]
    let open: (BrainRoute) -> Void
    /// Each card's words, parsed once here: `CardStack` rebuilds its top cards on every drag frame.
    private let texts: [BrainPersonLayout.Entry.ID: BrainTimelineCardText]
    @State private var index = 0
    @ScaledMetric(relativeTo: .body) private var deckHeight: CGFloat = BrainStyle.timelineDeckHeight

    init(entries: [BrainPersonLayout.Entry], open: @escaping (BrainRoute) -> Void) {
        self.entries = entries
        self.open = open
        self.texts = Dictionary(entries.map { ($0.id, BrainTimelineCardText(entry: $0)) },
                                uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            HXSectionHeader(title: "Timeline", trailing: BrainPersonLayout.position(index: index, count: entries.count))
                .padding(.horizontal, 4)
            CardStack(pages: entries, index: $index, tilt: { DeckStackView.tilt(ofID: $0.id) }) { entry, contentOpacity in
                if let text = texts[entry.id] {
                    BrainTimelineCard(entry: entry, text: text, open: open, contentOpacity: contentOpacity)
                }
            } edge: { entry in
                // Far down the stack only the card's paper shows, peeking out askew.
                BrainDeckCard.shape
                    .fill(BrainTimelineCard.paper(entry).card)
                    .hxShadow(.stacked)
                    .padding(.vertical, 12)
            }
            // A fixed height, cut to what fits in the reader's visible height.
            .containerRelativeFrame(.vertical) { length, _ in
                max(min(deckHeight, length - BrainStyle.deckViewportMargin), BrainStyle.minimumDeckHeight)
            }
        }
        .onChange(of: entries.count) { _, count in
            index = min(index, max(count - 1, 0))
        }
    }
}

/// One timeline card's words, built once per timeline rather than per drag frame.
private struct BrainTimelineCardText {
    struct Line {
        let text: AttributedString
        /// A `####` subhead, its marks dropped.
        let isHeading: Bool
    }

    let lead: AttributedString
    let bullets: [AttributedString]
    /// `extra`, line by line.
    let prose: [Line]
    /// "Journal: <the day's words>" for a journal day folded into an encounter; nil otherwise.
    let footnote: AttributedString?
    /// "Encounter · Oct 8 · 6 days ago. Gallery crawl"
    let accessibilityLabel: String
    /// The notes under the lead, read after the label.
    let accessibilityValue: String

    init(entry: BrainPersonLayout.Entry) {
        let person = BrainModuleID.people.paper
        switch entry.kind {
        case .encounter:
            lead = BrainArticleDigestView.inlineMarkdown(entry.headline)
        case .journal(let mention):
            lead = BrainConnectionsLayout.highlighted(entry.headline, mention: mention.mention, paper: person)
        }
        bullets = entry.bullets.map(BrainArticleDigestView.inlineMarkdown)
        prose = entry.extra.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let isHeading = line.hasPrefix("#")
            let text = isHeading ? line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) : line
            return text.isEmpty ? nil : Line(text: BrainArticleDigestView.inlineMarkdown(text), isHeading: isHeading)
        }
        footnote = entry.journal.map { journal in
            // The label keeps the card's glow; the day's words read in the body color.
            var words = BrainConnectionsLayout.highlighted(journal.snippet, mention: journal.mention, paper: person)
            for run in words.runs where run.foregroundColor == nil {
                words[run.range].foregroundColor = Color.hxTextPrimary
            }
            return AttributedString("Journal: ") + words
        }
        accessibilityLabel = [entry.kicker, String(lead.characters)].filter { !$0.isEmpty }.joined(separator: ". ")
        let notes = bullets.map { String($0.characters) } + prose.map { String($0.text.characters) }
            + (footnote.map { [String($0.characters)] } ?? [])
        accessibilityValue = notes.filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

/// One timeline card, drawn like a review bite. An encounter wears the person paper: its
/// kicker, the headline as the lead, then its bullets and any prose; a same-day journal entry
/// adds one line of its words and "Open the journal day". A journal day on its own wears the
/// journal paper, its words in serif with the name marked, and opens the day.
private struct BrainTimelineCard: View {
    let entry: BrainPersonLayout.Entry
    let text: BrainTimelineCardText
    let open: (BrainRoute) -> Void
    var contentOpacity: Double = 1

    static func paper(_ entry: BrainPersonLayout.Entry) -> HermexPaper {
        switch entry.kind {
        case .encounter: BrainModuleID.people.paper
        case .journal: BrainModuleID.journal.paper
        }
    }

    /// The journal day the footer opens: the folded one, or the card's own.
    private var journalID: String? {
        switch entry.kind {
        case .encounter: entry.journal?.id
        case .journal(let mention): mention.id
        }
    }

    var body: some View {
        let paper = Self.paper(entry)
        BrainDeckCard(paper: paper, footer: "Open the journal day",
                      open: journalID.map { id in { open(.page(.journal, id)) } },
                      accessibilityLabel: text.accessibilityLabel, accessibilityValue: text.accessibilityValue,
                      footnote: text.footnote, contentOpacity: contentOpacity) {
            Text(verbatim: entry.kicker)
                .font(AppFont.footnote(weight: .semibold))
            if !entry.headline.isEmpty {
                Text(text.lead)
                    .font(leadFont)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
            if !text.bullets.isEmpty {
                BrainBulletList(lines: text.bullets, marker: "•", markerColor: paper.glow,
                                textColor: Color.hxTextPrimary, font: AppFont.body())
                    .padding(.top, 22)
            }
            if !text.prose.isEmpty {
                VStack(alignment: .leading, spacing: BrainStyle.s) {
                    // A fixed list from one page load, so position is a stable id.
                    ForEach(Array(text.prose.enumerated()), id: \.offset) { _, line in
                        Text(line.text)
                            .font(AppFont.body(weight: line.isHeading ? .semibold : nil))
                            .foregroundStyle(Color.hxTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, text.bullets.isEmpty ? 22 : BrainStyle.m)
            }
        }
    }

    /// The Daily Deck's lead sizes; a journal day's words keep the serif.
    private var leadFont: Font {
        let style = DeckCardText.leadStyle(length: entry.headline.count, isQuote: false)
        switch entry.kind {
        case .encounter: return AppFont.display(style: style, weight: .semibold)
        case .journal: return AppFont.serif(style: style)
        }
    }
}

/// Lines with a leading marker, the marker decorative.
private struct BrainBulletList: View {
    let lines: [AttributedString]
    let marker: String
    let markerColor: Color
    let textColor: Color
    let font: Font

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            // A fixed list from one page load, so position is a stable id.
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: BrainStyle.s) {
                    Text(verbatim: marker)
                        .foregroundStyle(markerColor)
                        .accessibilityHidden(true)
                    Text(line)
                        .foregroundStyle(textColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(font)
            }
        }
    }
}

#if DEBUG
#Preview("Person page") {
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
                                      snippet: "Ran into Dara Quill at the market.", mention: "Dara Quill")],
        catchup: "Moving to Lisbon in spring and still deciding on the flat.",
        threads: ["the Lisbon move", "her sister's visit"],
        rhythm: [0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 2, 1])
    let page = BrainPage(item: BrainItem(module: .people, id: "people/dara-quill.md", title: "Dara Quill",
                                         subtitle: "college friend"),
                         facts: [BrainFact(label: "Industry", value: "Robotics")], person: person)
    let layout = BrainPersonLayout(page: page, person: person, today: .now)
    return NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.xl) {
                VStack(alignment: .leading, spacing: BrainStyle.l) {
                    BrainPersonCardView(item: page.item, facts: [], subtitle: layout.subtitle)
                    BrainRhythmStrip(months: layout.rhythm, accessibilityLabel: layout.rhythmAccessibilityLabel)
                    BrainProfileChips(chips: layout.chips)
                }
                if let catchUp = layout.catchUp {
                    BrainCatchUpCard(catchUp: catchUp)
                }
                BrainPersonTimeline(entries: layout.timeline, open: { _ in })
                BrainPersonAbout(sections: layout.aboutSections)
            }
            .padding(BrainStyle.l)
        }
        .background(Color.hxCanvas)
    }
}
#endif
