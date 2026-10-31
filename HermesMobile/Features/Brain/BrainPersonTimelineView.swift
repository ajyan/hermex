import SwiftUI

/// A structured person page, laid out and its words parsed once, when the page loads
/// (`BrainPageViewModel`). The reader re-runs its body on any tap (Show all, the diagram, a label
/// loading); Catch up, the chips, About and the timeline only read from this.
@MainActor
struct BrainPersonPage {
    let layout: BrainPersonLayout
    fileprivate let catchUpSummary: AttributedString?
    fileprivate let catchUpLines: [AttributedString]
    fileprivate let chips: [String]
    fileprivate let about: [BrainPersonAbout.Section]
    fileprivate let timelineTexts: [BrainPersonLayout.Entry.ID: BrainTimelineCardText]

    init(page: BrainPage, person: BrainPerson, today: Date, calendar: Calendar = .current) {
        layout = BrainPersonLayout(page: page, person: person, today: today, calendar: calendar)
        catchUpSummary = layout.catchUp?.summary.map(BrainArticleDigestView.inlineMarkdown)
        catchUpLines = (layout.catchUp?.lines ?? []).map(BrainArticleDigestView.inlineMarkdown)
        // Plain text: a chip is a label, not a link.
        chips = layout.chips.map { String(BrainArticleDigestView.inlineMarkdown($0).characters) }
        about = BrainPersonAbout.sections(layout.aboutSections)
        timelineTexts = Dictionary(layout.timeline.map { ($0.id, BrainTimelineCardText(entry: $0)) },
                                   uniquingKeysWith: { first, _ in first })
    }
}

/// "Catch up": the nightly digest's recap and its lines (a near birthday, then the open
/// threads) on a glow card in the person paper, like a Daily Brief card. Lines keep their
/// inline Markdown, so a `brain://` link opens (in Nous blue: a link is a control, so the card
/// sets no paper tint).
struct BrainCatchUpCard: View {
    private let summary: AttributedString?
    private let lines: [AttributedString]

    init(person: BrainPersonPage) {
        self.summary = person.catchUpSummary
        self.lines = person.catchUpLines
    }

    var body: some View {
        let paper = BrainModuleID.people.paper
        HXCard(.glow(paper), title: "Catch up", spacing: BrainStyle.s) {
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
    private let chips: [String]

    init(person: BrainPersonPage) {
        self.chips = person.chips
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
/// shows three items and "+ N more" for the rest. Labelled items like "Father: Bo Test" (and,
/// elsewhere, "**Education**: …") show the label in secondary on its own line above the value.
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

    init(person: BrainPersonPage) {
        self.sections = person.about
    }

    fileprivate static func sections(_ sections: [BrainPersonLayout.AboutSection]) -> [Section] {
        sections.map { section in
            Section(id: section.id, title: section.title, rows: section.items.map { item in
                // Family items ("Father: Bo Test") always take the label layout; elsewhere only
                // a bold lead-in ("**Education**: …"), so plain sentences with a colon stay whole.
                let labelled = section.id == "family" || BrainPersonLayout.isBoldLeadIn(item)
                if labelled, let split = BrainPersonLayout.roleSplit(item) {
                    return Row(role: split.role,
                               text: BrainArticleDigestView.inlineMarkdown(BrainPersonLayout.aboutItem(split.value)))
                }
                return Row(role: nil, text: BrainArticleDigestView.inlineMarkdown(BrainPersonLayout.aboutItem(item)))
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
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                ForEach(Array(section.rows.prefix(expanded ? section.rows.count : Self.cap).enumerated()), id: \.offset) { _, row in
                    rowView(row)
                }
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
        // Like `BrainBulletList`: a decorative marker, the row's words after it.
        HStack(alignment: .firstTextBaseline, spacing: BrainStyle.s) {
            Text(verbatim: "·")
                .foregroundStyle(Color.hxTextSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                if let role = row.role {
                    Text(verbatim: role)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(row.text)
                    .font(BrainStyle.rowSubtitle)
                    .foregroundStyle(Color.hxTextPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func toggle() {
        withAnimation(HXMotion.disclosure(reduceMotion: reduceMotion)) { expanded.toggle() }
    }
}

/// "Timeline" over a person's encounters and the journal days that name them, newest first, as rows
/// on one neutral card: the kind's tile (a note, a text, a journal day), the headline on up to two
/// lines, and when. Three show, then "Show all N". Tapping a row opens its card full screen (the
/// review's open card), where a journal day's "Open the journal day" sits at the foot.
struct BrainPersonTimeline: View {
    let entries: [BrainPersonLayout.Entry]
    let open: (BrainRoute) -> Void
    /// Each entry's words, parsed once per page load (`BrainPersonPage`).
    private let texts: [BrainPersonLayout.Entry.ID: BrainTimelineCardText]
    @State private var showsAll = false
    private static let shown = 3

    init(person: BrainPersonPage, open: @escaping (BrainRoute) -> Void) {
        self.entries = person.layout.timeline
        self.open = open
        self.texts = person.timelineTexts
    }

    var body: some View {
        let visible = showsAll ? entries : Array(entries.prefix(Self.shown))
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            HXSectionHeader(title: "Timeline", trailing: entries.count > Self.shown ? "\(entries.count)" : nil)
                .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Rectangle().fill(Color.hxSeparator).frame(height: 0.5).accessibilityHidden(true)
                    }
                    if let text = texts[entry.id] {
                        BrainTimelineRow(entry: entry, text: text, open: open)
                    }
                }
                if !showsAll, entries.count > Self.shown {
                    Rectangle().fill(Color.hxSeparator).frame(height: 0.5).accessibilityHidden(true)
                    Button { showsAll = true } label: {
                        Text(verbatim: "Show all \(entries.count)")
                            .font(AppFont.subheadline(weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, BrainStyle.cardHorizontalPadding)
            .padding(.vertical, BrainStyle.xs)
            .hxCard()
        }
    }
}

/// One timeline row: the kind's tile in its paper, the headline (serif for a journal day's own
/// words), and when. A tap opens the entry's card full screen.
private struct BrainTimelineRow: View {
    let entry: BrainPersonLayout.Entry
    let text: BrainTimelineCardText
    let open: (BrainRoute) -> Void

    var body: some View {
        let paper = BrainTimelineCard.paper(entry)
        HStack(alignment: .top, spacing: BrainStyle.m) {
            BrainModuleIcon(systemName: entry.symbol, paper: paper)
            VStack(alignment: .leading, spacing: 2) {
                Text(text.lead)
                    .font(isJournal ? AppFont.serif(style: .body) : AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: entry.when).brainText(.meta)
            }
        }
        .padding(.vertical, BrainStyle.s)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text.accessibilityLabel))
        .accessibilityValue(Text(verbatim: text.accessibilityValue))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(verbatim: "Opens the whole entry"))
        .opensAsFullCard(.glow(paper), action: journalID.map { id in
            HXCardAction(title: "Open the journal day") { open(.page(.journal, id)) }
        }) {
            BrainTimelineCard(entry: entry, text: text, open: open, isOpen: true)
        }
    }

    private var isJournal: Bool {
        if case .journal = entry.kind { return true }
        return false
    }

    /// The journal day the open card's foot button opens: the folded one, or the row's own.
    private var journalID: String? {
        switch entry.kind {
        case .encounter: entry.journal?.id
        case .journal(let mention): mention.id
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
    /// "Note · Oct 8 · 6 days ago. Gallery crawl"
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
    /// Drawn inside the open card (`opensAsFullCard`), without a card surface of its own.
    var isOpen = false

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
                      footnote: text.footnote, contentOpacity: contentOpacity, isOpen: isOpen) {
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
        profile: [BrainProfileSection(label: "Family", items: ["**Wife**: Meg Quill",
                                                               "**Daughter**: Nina (Alex's half-sister) - See [Douglas Quill.md](Douglas Quill.md)",
                                                               "Father: Bo Quill", "sister Mina", "Mother: Ana Quill",
                                                               "cousin Teo"]),
                  BrainProfileSection(label: "Company", items: ["Orbit Labs", "Was at Lumen before"]),
                  BrainProfileSection(label: "Professional", items: [
                    "**Education**: M.S. in Robotics from State U after a B.S. in Mechanical Engineering.",
                    "**Paris & French Culture**: Speaks fluent French and plans to teach in Paris next year.",
                    "Philosophy: Doesn't accept compliments."]),
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
    let personPage = BrainPersonPage(page: page, person: person, today: .now)
    let layout = personPage.layout
    return NavigationStack {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.xl) {
                VStack(alignment: .leading, spacing: BrainStyle.l) {
                    BrainPersonCardView(item: page.item, facts: [], subtitle: layout.subtitle)
                    BrainRhythmStrip(months: layout.rhythm, accessibilityLabel: layout.rhythmAccessibilityLabel)
                    BrainProfileChips(person: personPage)
                }
                if layout.catchUp != nil {
                    BrainCatchUpCard(person: personPage)
                }
                BrainPersonTimeline(person: personPage, open: { _ in })
                BrainPersonAbout(person: personPage)
            }
            .padding(BrainStyle.l)
        }
        .background(Color.hxCanvas)
    }
}
#endif

// MARK: Acting on a person

/// A person page's foot, on the hub pager's glass capsule: Text (with their iMessage number), Log a
/// catch-up, and Ask Atlas. Text is the one filled control, in Nous blue; the others are its tint.
struct BrainPersonActionBar: View {
    let firstName: String
    let canText: Bool
    let canAsk: Bool
    let onText: () -> Void
    let onLog: () -> Void
    let onAsk: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Every label when they fit; else Log and Ask Atlas keep only their symbols (VoiceOver keeps the words).
        ViewThatFits(in: .horizontal) {
            row(compact: dynamicTypeSize.isAccessibilitySize)
            row(compact: true)
        }
        .padding(BrainStyle.xs)
        // Opaque under the glass, so body text scrolling beneath never shows through the labels.
        .background(Color.hxSurface, in: Capsule())
        .adaptiveGlass(isInteractive: true, tint: Color.hxSurface, in: Capsule())
        .hxShadow(.float)
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: BrainStyle.xs) {
            if canText {
                Button(action: onText) {
                    label("Text \(firstName)", symbol: "message.fill", compact: false)
                        .foregroundStyle(Color.hxOnAccent)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(verbatim: "Opens Messages; the catch-up is logged once it sends"))
            }
            Button(action: onLog) {
                label("Log", symbol: "square.and.pencil", compact: compact).foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "Log a catch-up"))
            if canAsk {
                Button(action: onAsk) {
                    label("Ask Atlas", symbol: "bubble.left.and.text.bubble.right", compact: compact)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "Ask Atlas"))
                .accessibilityHint(Text(verbatim: "Starts a new chat about \(firstName)"))
            }
        }
    }

    private func label(_ title: String, symbol: String, compact: Bool) -> some View {
        Group {
            if compact {
                Image(systemName: symbol)
            } else {
                Label { Text(verbatim: title) } icon: { Image(systemName: symbol) }
            }
        }
        .font(AppFont.subheadline(weight: .semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, BrainStyle.m)
        .frame(minWidth: BrainStyle.minTapTarget, minHeight: BrainStyle.minTapTarget)
        .contentShape(Capsule())
    }
}

/// "Log a catch-up": what happened, in his words, written to the contact through the vault's
/// `crm log`. The words stay put on a failure, with the reason, so nothing typed is lost.
struct BrainPersonLogSheet: View {
    let name: String
    let save: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isSaving = false
    @State private var failure: String?
    @FocusState private var isFocused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: BrainStyle.m) {
                TextField(text: $text, axis: .vertical) {
                    Text(verbatim: "What happened with \(name)?")
                }
                .font(AppFont.body())
                .lineLimit(4...12)
                .focused($isFocused)
                .withDictation($text, isSubmitting: isSaving)
                .padding(BrainStyle.m)
                .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous).strokeBorder(Color.hxSeparator, lineWidth: 0.5))
                if let failure {
                    Label { Text(verbatim: failure) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxDanger)
                }
                Text(verbatim: "Saved to their page as today's note.")
                    .brainText(.meta)
                Spacer(minLength: 0)
            }
            .padding(BrainStyle.l)
            .background(Color.hxCanvas.ignoresSafeArea())
            .navigationTitle(Text(verbatim: "Log a catch-up"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Cancel") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button { Task { await submit() } } label: { Text(verbatim: "Save").bold() }
                            .disabled(trimmed.isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isSaving || !trimmed.isEmpty)
        .onAppear { isFocused = true }
    }

    private func submit() async {
        isSaving = true
        failure = nil
        do {
            try await save(trimmed)
            dismiss()
        } catch {
            failure = "Couldn't save: \(error.localizedDescription)"
        }
        isSaving = false
    }
}
