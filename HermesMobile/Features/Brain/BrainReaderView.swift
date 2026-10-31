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
    /// A hub says so instead of its kind: "Hub · 8 pages · updated 3 wk ago". A hub inside
    /// another hub says "8 pages under this one", so its count isn't read as the pager's.
    static func metaLine(for item: BrainItem, hubPageCount: Int = 0, nested: Bool = false, today: Date = Date(),
                         calendar: Calendar = .current, locale: Locale = .current) -> String {
        let hubPart = nested ? "\(hubPageCount) pages under this one" : "Hub · \(hubPageCount) pages"
        let kind = hubPageCount > 0 ? hubPart : metaLine(kind: item.kind, date: "", locale: locale)
        guard !item.dateLabel.isEmpty, let age = BrainListLayout.age(item.date, today: today, calendar: calendar) else {
            return hubPageCount > 0 ? kind : metaLine(kind: item.kind, date: item.date, locale: locale)
        }
        let when = age == "today" ? "\(item.dateLabel) today" : "\(item.dateLabel) \(age) ago"
        return [kind, when].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Further reading split as the server sends it: the page's sources (reason "source"),
    /// then pages that share its tags (the reason names them, "#rome · #person").
    static func furtherGroups(_ refs: [BrainRef]) -> (sources: [BrainRef], tagged: [BrainRef]) {
        (refs.filter { $0.reason == "source" }, refs.filter { $0.reason != "source" })
    }

    /// Whether a page's tags open its module's list filtered to them: the lists with a tag bar.
    static func tagsFilter(_ module: BrainModuleID) -> Bool {
        module == .wiki || module == .articles
    }

    /// The reader's tags as one meta line, "#habits · #self".
    static func tagLine(_ tags: [String]) -> String {
        displayTags(tags).map { "#\($0)" }.joined(separator: " · ")
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
    /// The pager step in flight (-1 or +1), and whether the last one failed.
    @State private var pendingStep: Int?
    @State private var stepFailed = false
    /// The step that failed, so the pager can try it again.
    @State private var failedMove: (target: BrainRef, edge: Edge)?
    /// A person page's Log sheet, and the Messages sheet its Text button opens.
    @State private var showsLog = false
    @State private var texting: DeckMessage?
    /// A text Messages reported sent that couldn't be logged: its words, for Try again.
    @State private var unloggedText: String?
    /// Bumped by each logged catch-up; plays the success haptic.
    @State private var loggedCount = 0
    @Environment(\.openDraftChat) private var openDraftChat
    @Environment(\.openURL) private var openURL
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
                    BrainHubPager(hub: hub, onStep: step, onShowPages: { showsHubPages = true },
                                  pendingStep: pendingStep, stepFailed: stepFailed, onRetry: retry)
                        .padding(.horizontal, BrainStyle.l)
                        .padding(.bottom, BrainStyle.s)
                } else if let page = viewModel.page, let person = page.person {
                    personActions(page: page, person: person)
                        .padding(.horizontal, BrainStyle.l)
                        .padding(.bottom, BrainStyle.s)
                }
            }
            .sheet(isPresented: $showsLog) {
                BrainPersonLogSheet(name: viewModel.page?.item.title ?? "them") { text in
                    _ = try await viewModel.logCatchUp(text, kind: .note)
                    loggedCount += 1
                }
            }
            .sheet(item: $texting) { message in
                MessageComposer(message: message) { sent, body in
                    texting = nil
                    let words = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if sent, !words.isEmpty { Task { await logText(words) } }
                }
                .ignoresSafeArea()
            }
            .alert(Text(verbatim: "Sent, but not logged"), isPresented: Binding(
                get: { unloggedText != nil }, set: { if !$0 { unloggedText = nil } })) {
                Button { if let words = unloggedText { Task { await logText(words) } } } label: { Text(verbatim: "Try again") }
                Button(role: .cancel) { unloggedText = nil } label: { Text(verbatim: "Not now") }
            } message: {
                Text(verbatim: "Your text went out, but the server didn't record it on their page.")
            }
            .sensoryFeedback(.success, trigger: loggedCount)
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

    /// Text, Log and Ask Atlas for the person on this page.
    private func personActions(page: BrainPage, person: BrainPerson) -> some View {
        let name = page.item.title
        let first = name.split(separator: " ").first.map(String.init) ?? name
        return BrainPersonActionBar(
            firstName: first,
            canText: person.imessage != nil,
            canAsk: openDraftChat.isAvailable,
            onText: {
                guard let handle = person.imessage else { return }
                // He writes his own words; the note is logged only once Messages reports the text sent.
                let message = DeckMessage(to: handle, body: nil)
                if MessageComposer.canSend {
                    texting = message
                } else if let url = message.smsURL {
                    openURL(url)  // the simulator: Messages can't report back, so nothing is logged
                }
            },
            onLog: { showsLog = true },
            onAsk: { openDraftChat("About \(name) (\(page.item.id)): ") })
    }

    private func logText(_ words: String) async {
        do {
            _ = try await viewModel.logCatchUp(words, kind: .texted)
            unloggedText = nil
            loggedCount += 1
        } catch {
            unloggedText = words
        }
    }
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

    /// Tries the step that failed again.
    private func retry() {
        guard let failedMove, let hub = viewModel.page?.hub else { return }
        move(to: failedMove.target, in: hub, from: failedMove.edge)
    }

    private func move(to target: BrainRef, in hub: BrainHubContext, from edge: Edge) {
        let current = viewModel
        stepTask?.cancel()
        pendingStep = edge == .leading ? -1 : 1
        stepFailed = false
        failedMove = nil
        stepTask = Task {
            let next = await current.loadedSibling(module: target.module, id: target.id, hub: hub.ref.id)
            guard !Task.isCancelled else { return }
            pendingStep = nil
            guard let next else {
                failedSteps += 1
                stepFailed = true
                failedMove = (target, edge)
                return
            }
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
    /// Bumped by the hub's meta line; scrolls down to its pages.
    @State private var jumpsToHubPages = 0
    private static let hubPagesAnchor = "hub-pages"
    /// The page's diagram sheet, while open.
    @State private var showsDiagram = false

    init(page: BrainPage, person: BrainPersonPage?, isShowingCachedCopy: Bool, isMissing: Bool = false,
         push: @escaping (BrainRoute) -> Void, rating: BrainPageRating? = nil,
         focusIdea: Int? = nil) {
        self.page = page
        self.isShowingCachedCopy = isShowingCachedCopy
        self.isMissing = isMissing
        self.push = push
        self.rating = rating
        self.focusIdea = focusIdea
        self.hubPages = BrainConnectionsLayout.hubPages(page)
        self.meta = BrainReaderLayout.metaLine(for: page.item, hubPageCount: hubPages.count, nested: page.hub != nil)
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
                .onChange(of: jumpsToHubPages) { _, _ in
                    withAnimation(reduceMotion ? nil : .default) {
                        proxy.scrollTo(Self.hubPagesAnchor, anchor: .top)
                    }
                }
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
                    // Up top, where it changes how the page should be read, not after the mentions.
                    if isShowingCachedCopy {
                        Text(verbatim: BrainReaderLayout.cachedCopyFooter(isMissing: isMissing))
                            .brainText(.meta)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                if let person {
                    personSections(person)
                        .environment(\.openURL, brainLinks)
                }
                if !linkCards.isEmpty {
                    BrainLinkCardsRow(refs: linkCards)
                }
                // No sideways swipe here: code blocks and tables scroll sideways, and the pager
                // and its list already move through the hub.
                VStack(alignment: .leading, spacing: BrainStyle.xl) {
                    bodyAndMentions
                }
                // A hub's pages come after its own words: the first screen is the page.
                if !hubPages.isEmpty {
                    hubPagesSection
                }
                furtherReading
                journalPaging
                if let rating {
                    RateControl(label: "Rate this page", key: rating.key, title: page.item.title, labels: rating.labels)
                        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
                        .brainCardSurface()
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
                    BrainArticleDigestView(digest: digest, focusIdea: focusIdea, paper: page.item.module.paper)
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
            if !hubPages.isEmpty {
                // A hub's pages sit after its words; its meta line is the way down to them.
                Button { jumpsToHubPages += 1 } label: {
                    HStack(alignment: .firstTextBaseline, spacing: BrainStyle.xs) {
                        Text(verbatim: meta)
                        Image(systemName: "arrow.down")
                            .accessibilityHidden(true)
                    }
                    // The meta size in Nous blue: `brainText(.meta)` would set its own grey.
                    .font(BrainStyle.Role.meta.font)
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .contentShape(.interaction, Rectangle().inset(by: -11))
                .accessibilityHint(Text(verbatim: "Jumps to the hub's pages"))
            } else if !meta.isEmpty {
                Text(verbatim: meta)
                    .brainText(.meta)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The page's tags at meta size. On a page whose module filters by tag (wiki, articles)
    /// each is a link to that list filtered to it; elsewhere they're one line of text.
    @ViewBuilder
    private var tagRow: some View {
        let tags = BrainReaderLayout.displayTags(page.item.tags)
        if BrainReaderLayout.tagsFilter(page.item.module) {
            FlowRow(spacing: BrainStyle.m) {
                ForEach(tags, id: \.self) { tag in
                    Button { push(.moduleTagged(page.item.module, tag: tag)) } label: {
                        Text(verbatim: "#\(tag)")
                            .font(BrainStyle.Role.meta.font)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .contentShape(.interaction, Rectangle().inset(by: -8))
                    .accessibilityLabel(Text(verbatim: "Tag \(tag)"))
                    .accessibilityHint(Text(verbatim: "Shows the \(page.item.module.defaultTitle) list filtered to it"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(verbatim: BrainReaderLayout.tagLine(page.item.tags))
                .brainText(.meta)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            // A hub inside another hub: its pager walks the parent, so its own list says which.
            title: page.hub == nil ? "In this hub" : "Pages under this one",
            count: hubPages.count,
            rows: shown.map { BrainReaderRefSection.Row(ref: $0, subtitle: $0.snippet) },
            showAllTitle: hubPages.count > shown.count ? BrainReaderLayout.showAllTitle(hubPages.count) : nil,
            onShowAll: { showsAllHubPages = true },
            route: { .pageInHub($0.module, $0.id, hub: page.item.id) },
            // Every row is a wiki page, so a kind tile would only repeat itself.
            showsIcons: false
        )
        .id(Self.hubPagesAnchor)
    }

    /// Further reading as two sections: Sources, each with its gist, then Also tagged, each
    /// with the tags it shares, so every row says why it's here.
    @ViewBuilder
    private var furtherReading: some View {
        let groups = BrainReaderLayout.furtherGroups(page.further)
        if !groups.sources.isEmpty {
            BrainReaderRefSection(
                title: "Sources",
                count: groups.sources.count,
                rows: groups.sources.map { BrainReaderRefSection.Row(ref: $0, subtitle: $0.snippet) }
            )
        }
        if !groups.tagged.isEmpty {
            BrainReaderRefSection(
                title: "Also tagged",
                count: groups.tagged.count,
                rows: groups.tagged.map { BrainReaderRefSection.Row(ref: $0, subtitle: $0.reason) }
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
    /// A note at the header's trailing edge.
    var trailing: String?
    /// Where a row goes; a plain page unless the section says otherwise.
    var route: (BrainRef) -> BrainRoute = { .page($0.module, $0.id) }
    /// Off when every row is the same kind, so the tile would only repeat.
    var showsIcons = true
    /// The separator starts where the row's text does (thumbnail plus spacing).
    @ScaledMetric(relativeTo: .body) private var separatorInset = BrainStyle.searchThumbnailSize + BrainStyle.m

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: title, count: count, trailing: trailing)
            VStack(spacing: 0) {
                // A section's rows never reorder ("Show all" only appends), so position is a stable id.
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { separator }
                    NavigationLink(value: ShellPushDestination.brainRoute(route(row.ref))) {
                        HStack(spacing: BrainStyle.s) {
                            BrainSearchResultRow(ref: row.ref, subtitle: row.subtitle, showsLeading: showsIcons)
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
            .padding(.leading, showsIcons ? separatorInset : 0)
            .accessibilityHidden(true)
    }
}

/// The Brain reader's Rate control: whose labels, and which page.
struct BrainPageRating {
    let labels: LabelsViewModel
    let key: LabelKey
}
