import SwiftData
import SwiftUI

/// The reader's pure layout decisions, kept out of the views so they can be tested.
enum BrainReaderLayout {
    /// Backlinks shown before "Show all N".
    static let backlinkPreviewCount = 5
    /// "<Kind> · <date>", the kind's first letter capitalised and the date in the one
    /// Brain format; either part may be absent.
    static func metaLine(kind: String, date: String, locale: Locale = .current) -> String {
        // A journal day's title already is its date; repeating it reads as a glitch.
        if kind == "day" { return "Journal" }
        let capitalised = kind.prefix(1).uppercased() + kind.dropFirst()
        return [capitalised, BrainStyle.displayDate(date, locale: locale)]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The line under a page's title. A page whose date the server labels (a wiki page) says
    /// how long ago: "Concept · updated 3 wk ago", "Source · added today"; any other page
    /// keeps `metaLine(kind:date:)`.
    /// A hub says so instead of its kind: "Hub · 8 pages · updated 3 wk ago".
    static func metaLine(for item: BrainItem, hubPageCount: Int = 0, today: Date = Date(),
                         calendar: Calendar = .current, locale: Locale = .current) -> String {
        let kind = hubPageCount > 0 ? "Hub · \(hubPageCount) pages" : metaLine(kind: item.kind, date: "", locale: locale)
        guard !item.dateLabel.isEmpty, let age = BrainListLayout.age(item.date, today: today, calendar: calendar) else {
            return hubPageCount > 0 ? kind : metaLine(kind: item.kind, date: item.date, locale: locale)
        }
        let when = age == "today" ? "\(item.dateLabel) today" : "\(item.dateLabel) \(age) ago"
        return [kind, when].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Reader tag chips without the ingest-channel tags every article or video carries.
    static func displayTags(_ tags: [String]) -> [String] {
        tags.filter { !["email", "youtube"].contains($0.lowercased()) }
    }

    /// The digest for an article or video note in the summary outline; nil keeps the
    /// plain markdown reader (wiki pages, journal days, people, and anything else).
    static func digest(for page: BrainPage) -> BrainArticleDigest? {
        let isSummary = page.item.module == .articles
            || (page.item.module == .highlights && page.item.kind == "video")
        return isSummary ? BrainArticleDigest.parse(page.content) : nil
    }

    /// The footer under a saved copy: a page the server no longer has reads as removed.
    static func cachedCopyFooter(isMissing: Bool) -> String {
        isMissing ? "Removed from the Brain · saved copy" : "Offline, showing saved copy"
    }

    enum LinkAction: Equatable {
        /// An in-app Brain page.
        case push(BrainRoute)
        /// A `brain://` link the app can't resolve; dropped rather than handed to the system.
        case discard
        /// Any other URL, opened by the system.
        case system
    }

    /// What tapping a link in a page's Markdown does.
    static func linkAction(for url: URL) -> LinkAction {
        if let ref = BrainLink.ref(from: url) {
            return .push(.page(ref.0, ref.1))
        }
        return url.scheme?.lowercased() == "brain" ? .discard : .system
    }

    static func visibleBacklinks(_ backlinks: [BrainRef], expanded: Bool) -> [BrainRef] {
        expanded ? backlinks : Array(backlinks.prefix(backlinkPreviewCount))
    }

    static func hasMoreBacklinks(_ backlinks: [BrainRef], expanded: Bool) -> Bool {
        !expanded && backlinks.count > backlinkPreviewCount
    }

    static func showAllTitle(_ count: Int) -> String {
        "Show all \(count)"
    }

    static func linkedFromTitle(_ module: BrainModuleID) -> String {
        module == .people ? "Mentioned in" : "Linked mentions"
    }
}

/// One page of the Brain (wiki, article, journal day, video note or person), pushed
/// as `.brainRoute(.page(module, id))` for every id that isn't a book. Owns no
/// `NavigationStack`: `push` and the rows' `NavigationLink`s go onto the shell's.
/// The hub pager swaps the page in place, so Back returns to where the reader came from.
struct BrainReaderView: View {
    @State private var viewModel: BrainPageViewModel
    /// The page the pager is loading; it replaces `viewModel` once it lands.
    @State private var stepTask: Task<Void, Never>?
    @State private var stepEdge: Edge = .trailing
    /// Bumped when the pager's next page couldn't load; plays an error haptic.
    @State private var failedSteps = 0
    /// The hub's page list, opened from the pager.
    @State private var showsHubPages = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Good/not-good on the page; shown only where the server has labels.
    @State private var labels: LabelsViewModel
    @Environment(FeedbackAvailability.self) private var availability: FeedbackAvailability?
    private let push: (BrainRoute) -> Void
    /// The page the route opened and the key idea to show on it. Stepping through the hub
    /// leaves the opened page, and the idea no longer applies there.
    private let opened: (module: BrainModuleID, id: String)
    private let focusIdea: Int?

    /// `hub` keeps the page in the hub it was opened from (its trail and pager).
    init(module: BrainModuleID, id: String, hub: String? = nil, server: URL, modelContext: ModelContext,
         onAPIError: @escaping (Error) -> Void, push: @escaping (BrainRoute) -> Void,
         focusIdea: Int? = nil) {
        let client = APIClientBrainAdapter(apiClient: APIClient(baseURL: server))
        let cache = BrainCacheHandle(server: server, context: modelContext)
        _viewModel = State(initialValue: BrainPageViewModel(
            module: module, id: id, hub: hub, client: client, cache: cache, onAPIError: onAPIError))
        _labels = State(initialValue: LabelsViewModel(client: APIClientLabelsAdapter(apiClient: APIClient(baseURL: server))))
        self.push = push
        self.opened = (module, id)
        self.focusIdea = focusIdea
    }

    var body: some View {
        content
            .id(viewModel.id)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .move(edge: stepEdge).combined(with: .opacity), removal: .opacity))
            .hxNavigationTitle(viewModel.page?.item.title ?? "")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { FeedbackMoreMenu() } }
            .feedbackContext(FeedbackContext(
                feature: "Brain", screen: viewModel.module.defaultTitle, item: viewModel.page?.item.title ?? viewModel.id,
                state: ["module": viewModel.module.rawValue, "item_id": viewModel.id]))
            .background(Color.hxCanvas.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if let hub = viewModel.page?.hub, BrainConnectionsLayout.showsPager(hub) {
                    BrainHubPager(hub: hub, onStep: step, onShowPages: { showsHubPages = true })
                        .padding(.horizontal, BrainStyle.l)
                        .padding(.bottom, BrainStyle.s)
                }
            }
            .sheet(isPresented: $showsHubPages) {
                if let hub = viewModel.page?.hub {
                    BrainHubPagesSheet(hub: hub, currentID: viewModel.id, onPick: jump)
                }
            }
            .task(id: viewModel.id) {
                // First appear, or back on screen after an earlier load was cancelled.
                if viewModel.state == .loading {
                    await viewModel.load()
                }
            }
            .task(id: "\(viewModel.module.rawValue)/\(viewModel.id)|\(labelsAvailable)") {
                // Runs on each appear, so a failed read retries; the row hides until one lands.
                let key = ratingKey
                guard labelsAvailable, !labels.isLoaded(feature: key.feature, item: key.item) else { return }
                try? await labels.load(feature: key.feature, item: key.item)
            }
            .sensoryFeedback(.error, trigger: failedSteps)
            .onDisappear { stepTask?.cancel() }
    }

    private var labelsAvailable: Bool { availability?.labelsAvailable == true }
    private var ratingKey: LabelKey { .brainPage(module: viewModel.module, id: viewModel.id) }

    /// Moves to the previous (-1) or next (+1) page in the hub. The next page loads behind
    /// the current one and slides in once it lands, so there is no spinner between pages.
    private func step(_ direction: Int) {
        guard let hub = viewModel.page?.hub,
              let target = direction < 0 ? hub.prev : hub.next
        else { return }
        move(to: target, in: hub, from: direction < 0 ? .leading : .trailing)
    }

    /// Moves to a page picked from the hub's list, sliding in from the side it sits on.
    private func jump(to target: BrainRef) {
        guard let hub = viewModel.page?.hub else { return }
        let before = (hub.pages.firstIndex { $0.id == target.id } ?? 0) < (hub.index ?? 0)
        move(to: target, in: hub, from: before ? .leading : .trailing)
    }

    private func move(to target: BrainRef, in hub: BrainHubContext, from edge: Edge) {
        let current = viewModel
        stepTask?.cancel()
        stepTask = Task {
            let next = await current.loadedSibling(module: target.module, id: target.id, hub: hub.ref.id)
            guard !Task.isCancelled else { return }
            guard let next else { failedSteps += 1; return }
            stepEdge = edge
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { viewModel = next }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label { Text(verbatim: "No Brain on this server") } icon: { Image(systemName: "brain") }
            }
        case .failed where viewModel.isMissing:
            ContentUnavailableView {
                Label { Text(verbatim: "This page moved or was removed") } icon: { Image(systemName: "doc.questionmark") }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label { Text(verbatim: "Couldn't load this page") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(verbatim: message)
            } actions: {
                Button { Task { await viewModel.load() } } label: { Text(verbatim: "Try again") }
            }
        case .loaded(let page):
            BrainReaderContent(
                page: page,
                person: viewModel.person,
                isShowingCachedCopy: viewModel.isShowingCachedCopy,
                isMissing: viewModel.isMissing,
                push: push,
                onStep: BrainConnectionsLayout.showsPager(page.hub) ? step : nil,
                rating: labelsAvailable && labels.isLoaded(feature: ratingKey.feature, item: ratingKey.item)
                    ? BrainPageRating(labels: labels, key: ratingKey) : nil,
                focusIdea: viewModel.module == opened.module && viewModel.id == opened.id ? focusIdea : nil
            )
            .refreshable { await viewModel.load() }
        }
    }
}

/// A loaded page, top to bottom: the cover (only without links), the trail, title block
/// (or person card), tags, the linked-page cards, body, linked and unlinked mentions,
/// Further reading, and journal paging. A person page the server structured (`page.person`)
/// adds the rhythm strip and profile chips under its header, then Catch up, the timeline deck
/// and About, then the leftover Markdown, with the timeline's journal days left out of the
/// mentions.
struct BrainReaderContent: View {
    let page: BrainPage
    let isShowingCachedCopy: Bool
    let isMissing: Bool
    let push: (BrainRoute) -> Void
    /// Pages through the hub (-1 previous, +1 next) on a sideways swipe; nil without a pager.
    var onStep: ((Int) -> Void)?
    /// The page's Rate control; nil where the server has no labels.
    var rating: BrainPageRating?
    /// The key idea a bite opened this page at; nil on any other page.
    var focusIdea: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Built once per page: the line under the title.
    private let meta: String
    /// Built once per page: a hub's own pages (In this hub).
    private let hubPages: [BrainRef]
    /// Articles and video notes in the summary outline read as a digest.
    private let digest: BrainArticleDigest?
    /// Built once per page: the linked-page cards.
    private let linkCards: [BrainRef]
    /// Built once per page load, by the view model: a structured person page's header, chips,
    /// Catch up, About and timeline, its words already parsed.
    private let person: BrainPersonPage?
    /// The mention sections, less the journal days a person's timeline already shows.
    private let backlinks: [BrainRef]
    private let unlinkedRefs: [BrainRef]
    private let unlinkedTotal: Int
    @State private var showsAllBacklinks = false
    @State private var showsAllHubPages = false
    /// The page's diagram sheet, while open.
    @State private var showsDiagram = false

    init(page: BrainPage, person: BrainPersonPage?, isShowingCachedCopy: Bool, isMissing: Bool = false,
         push: @escaping (BrainRoute) -> Void, onStep: ((Int) -> Void)? = nil, rating: BrainPageRating? = nil,
         focusIdea: Int? = nil) {
        self.page = page
        self.isShowingCachedCopy = isShowingCachedCopy
        self.isMissing = isMissing
        self.push = push
        self.onStep = onStep
        self.rating = rating
        self.focusIdea = focusIdea
        self.hubPages = BrainConnectionsLayout.hubPages(page)
        self.meta = BrainReaderLayout.metaLine(for: page.item, hubPageCount: hubPages.count)
        self.digest = BrainReaderLayout.digest(for: page)
        self.linkCards = BrainConnectionsLayout.linkCards(page)
        self.person = person
        let personLayout = person?.layout
        self.backlinks = personLayout?.remainingMentions(page.backlinks, total: page.backlinks.count).refs
            ?? page.backlinks
        let unlinked = personLayout?.remainingMentions(page.unlinked, total: page.unlinkedCount)
            ?? (refs: page.unlinked, total: page.unlinkedCount)
        self.unlinkedRefs = unlinked.refs
        self.unlinkedTotal = unlinked.total
    }

    var body: some View {
        ScrollViewReader { proxy in
            scrollContent
                .task(id: page.item.id) {
                    guard let focusIdea, digest?.ideas.contains(where: { $0.number == focusIdea }) == true else { return }
                    withAnimation(reduceMotion ? nil : .default) {
                        proxy.scrollTo(BrainArticleDigestView.ideaAnchor(focusIdea), anchor: .top)
                    }
                }
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.xl) {
                VStack(alignment: .leading, spacing: BrainStyle.l) {
                    BrainTrail(hub: page.hub?.ref)
                    if let person {
                        BrainPersonCardView(item: page.item, facts: [], subtitle: person.layout.subtitle)
                        if !person.layout.rhythm.isEmpty {
                            BrainRhythmStrip(months: person.layout.rhythm,
                                             accessibilityLabel: person.layout.rhythmAccessibilityLabel)
                        }
                        if !person.layout.chips.isEmpty {
                            BrainProfileChips(person: person)
                        }
                    } else if page.item.module == .people {
                        BrainPersonCardView(item: page.item, facts: page.facts)
                    } else {
                        titleBlock
                    }
                    if !BrainReaderLayout.displayTags(page.item.tags).isEmpty {
                        tagRow
                    }
                    if let diagram = page.diagram {
                        Button { showsDiagram = true } label: {
                            OpenDiagramLabel(paper: page.item.module.paper, isMap: diagram.isMap)
                        }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(verbatim: diagram.isMap ? "Open the map"
                                                     : "Open the diagram: \(diagram.title ?? page.item.title)"))
                            .accessibilityHint(Text(verbatim: diagram.isMap ? "Opens the piece's parts and argument, step by step"
                                                    : "Opens an interactive diagram"))
                    }
                }
                if !hubPages.isEmpty {
                    hubPagesSection
                }
                if let person {
                    // Outside the body's hub swipe, so paging the timeline never pages the hub.
                    personSections(person)
                        .environment(\.openURL, brainLinks)
                }
                if !linkCards.isEmpty {
                    BrainLinkCardsRow(refs: linkCards)
                }
                VStack(alignment: .leading, spacing: BrainStyle.xl) {
                    bodyAndMentions
                }
                .contentShape(Rectangle())
                .simultaneousGesture(swipe, including: onStep == nil ? .subviews : .all)
                furtherReading
                journalPaging
                if let rating {
                    RateControl(label: "Rate this page", key: rating.key, title: page.item.title, labels: rating.labels)
                        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
                        .brainCardSurface()
                }
                if isShowingCachedCopy {
                    Text(verbatim: BrainReaderLayout.cachedCopyFooter(isMissing: isMissing))
                        .brainText(.meta)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(BrainStyle.l)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        }
        .sheet(isPresented: $showsDiagram) {
            if let diagram = page.diagram {
                DiagramSheet(title: diagram.title ?? page.item.title) { diagram.html }
            }
        }
    }

    /// A sideways swipe over the body pages through the hub. Kept off the card row, which
    /// scrolls sideways itself.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                if let onStep, let direction = BrainConnectionsLayout.swipeStep(value.translation) {
                    onStep(direction)
                }
            }
    }

    /// A structured person page's Catch up, Timeline and About, in that order.
    @ViewBuilder
    private func personSections(_ person: BrainPersonPage) -> some View {
        if person.layout.catchUp != nil {
            BrainCatchUpCard(person: person)
        }
        if !person.layout.timeline.isEmpty {
            BrainPersonTimeline(person: person, open: push)
        }
        if !person.layout.aboutSections.isEmpty {
            BrainPersonAbout(person: person)
        }
    }

    @ViewBuilder
    private var bodyAndMentions: some View {
        if self.person != nil, let person = page.person {
            if !person.other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownRenderer(content: person.other)
                    .environment(\.openURL, brainLinks)
            }
        } else if !page.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Group {
                if let digest {
                    BrainArticleDigestView(digest: digest, focusIdea: focusIdea)
                } else {
                    MarkdownRenderer(content: page.content)
                }
            }
            .environment(\.openURL, brainLinks)
        }
        linkedFrom
        unlinked
    }

    /// Opens a page's `brain://` links in the reader, drops ones the app can't resolve, and
    /// hands any other URL to the system.
    private var brainLinks: OpenURLAction {
        OpenURLAction { url in
            switch BrainReaderLayout.linkAction(for: url) {
            case .push(let route):
                push(route)
                return .handled
            case .discard:
                return .discarded
            case .system:
                return .systemAction
            }
        }
    }

    /// The title, then what kind of page it is and how fresh.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            Text(verbatim: page.item.title)
                .brainText(.readerTitle)
                .accessibilityAddTraits(.isHeader)
            if !meta.isEmpty {
                Text(verbatim: meta)
                    .brainText(.meta)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The page's tags, display only.
    private var tagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BrainStyle.s) {
                ForEach(BrainReaderLayout.displayTags(page.item.tags), id: \.self) { BrainTagChip(tag: $0) }
            }
        }
        .scrollClipDisabled()
    }

    /// Pages that link here, each with the words around its link.
    @ViewBuilder
    private var linkedFrom: some View {
        if !backlinks.isEmpty {
            BrainMentionSection(
                title: BrainReaderLayout.linkedFromTitle(page.item.module),
                count: backlinks.count,
                refs: BrainReaderLayout.visibleBacklinks(backlinks, expanded: showsAllBacklinks),
                paper: page.item.module.paper,
                showAllTitle: BrainReaderLayout.hasMoreBacklinks(backlinks, expanded: showsAllBacklinks)
                    ? BrainReaderLayout.showAllTitle(backlinks.count) : nil,
                onShowAll: { showsAllBacklinks = true }
            )
        }
    }

    /// Pages that name this one without linking to it (the server sends the first few).
    @ViewBuilder
    private var unlinked: some View {
        if !unlinkedRefs.isEmpty {
            BrainMentionSection(
                title: "Unlinked mentions",
                count: unlinkedTotal,
                refs: unlinkedRefs,
                paper: page.item.module.paper,
                footer: BrainConnectionsLayout.cappedFooter(shown: unlinkedRefs.count, total: unlinkedTotal)
            )
        }
    }

    /// A hub's own pages, in pager order: the first few, then "Show all N". Each opens in this
    /// hub, so its trail and pager stay here.
    private var hubPagesSection: some View {
        let shown = showsAllHubPages ? hubPages : Array(hubPages.prefix(BrainConnectionsLayout.hubPreviewCount))
        return BrainReaderRefSection(
            title: "In this hub",
            count: hubPages.count,
            rows: shown.map { BrainReaderRefSection.Row(ref: $0, subtitle: $0.snippet) },
            showAllTitle: hubPages.count > shown.count ? BrainReaderLayout.showAllTitle(hubPages.count) : nil,
            onShowAll: { showsAllHubPages = true },
            route: { .pageInHub($0.module, $0.id, hub: page.item.id) }
        )
    }

    @ViewBuilder
    private var furtherReading: some View {
        if !page.further.isEmpty {
            BrainReaderRefSection(
                title: "Further reading",
                count: page.further.count,
                rows: page.further.map { BrainReaderRefSection.Row(ref: $0, subtitle: $0.reason) }
            )
        }
    }

    @ViewBuilder
    private var journalPaging: some View {
        if page.item.module == .journal, page.prev != nil || page.next != nil {
            HStack(alignment: .firstTextBaseline, spacing: BrainStyle.m) {
                if let prev = page.prev {
                    pagingLink(prev, text: "‹ \(title(of: prev))", label: "Previous day, \(title(of: prev))")
                }
                Spacer(minLength: 0)
                if let next = page.next {
                    pagingLink(next, text: "\(title(of: next)) ›", label: "Next day, \(title(of: next))")
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private func title(of ref: BrainRef) -> String {
        ref.title.isEmpty ? ref.id : ref.title
    }

    private func pagingLink(_ ref: BrainRef, text: String, label: String) -> some View {
        NavigationLink(value: ShellPushDestination.brainRoute(.page(ref.module, ref.id))) {
            Text(verbatim: text)
                .font(BrainStyle.rowSubtitle)
                .foregroundStyle(Color.accentColor)
                .lineLimit(2)
                .frame(minHeight: BrainStyle.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: label))
    }
}

/// A captioned group of reference rows on one surface card, with hairline separators
/// matched to the Brain lists, and an optional inline "Show all N" row.
struct BrainReaderRefSection: View {
    struct Row {
        let ref: BrainRef
        let subtitle: String
    }

    let title: String
    let count: Int
    let rows: [Row]
    var showAllTitle: String?
    var onShowAll: () -> Void = {}
    /// Where a row goes; a plain page unless the section says otherwise.
    var route: (BrainRef) -> BrainRoute = { .page($0.module, $0.id) }
    /// The separator starts where the row's text does (thumbnail plus spacing).
    @ScaledMetric(relativeTo: .body) private var separatorInset = BrainStyle.searchThumbnailSize + BrainStyle.m

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: title, count: count)
            VStack(spacing: 0) {
                // A section's rows never reorder ("Show all" only appends), so position is a stable id.
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { separator }
                    NavigationLink(value: ShellPushDestination.brainRoute(route(row.ref))) {
                        HStack(spacing: BrainStyle.s) {
                            BrainSearchResultRow(ref: row.ref, subtitle: row.subtitle)
                            Image(systemName: "chevron.right")
                                .font(BrainStyle.meta.weight(.semibold))
                                .foregroundStyle(Color.hxTextSecondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if let showAllTitle {
                    separator
                    Button(action: onShowAll) {
                        Text(verbatim: showAllTitle)
                            .font(BrainStyle.rowSubtitle)
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, BrainStyle.cardHorizontalPadding)
            .brainCardSurface()
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.hxSeparator)
            .frame(height: 0.5)
            .padding(.leading, separatorInset)
            .accessibilityHidden(true)
    }
}

/// The Brain reader's Rate control: whose labels, and which page.
struct BrainPageRating {
    let labels: LabelsViewModel
    let key: LabelKey
}
