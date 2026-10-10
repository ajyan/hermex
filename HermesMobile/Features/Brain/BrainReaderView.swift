import SwiftData
import SwiftUI

/// The reader's pure layout decisions, kept out of the views so they can be tested.
enum BrainReaderLayout {
    /// Backlinks shown before "Show all N".
    static let backlinkPreviewCount = 5
    /// The header's height: the graph's, and the cover that stands in for it.
    static let headerHeight: CGFloat = BrainGraphView.height

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

    /// The page's one cover recipe. The graph header takes its ramp, so a page keeps
    /// one hue whether it shows the graph or the cover.
    static func cover(for item: BrainItem) -> BrainCoverSpec {
        BrainCoverSpec.make(id: item.id, tag: item.tags.first)
    }

    /// The graph replaces the cover only when it has a neighbour besides the page.
    static func showsGraph(_ graph: BrainGraph?, centerID: String) -> Bool {
        guard let graph, graph.nodes.count >= 2 else { return false }
        return !BrainGraphLayout.visibleNodes(of: graph, centerID: centerID).isEmpty
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

    /// Journal backlinks show the sentence that mentions the page; others show nothing.
    static func backlinkSubtitle(_ ref: BrainRef) -> String? {
        ref.module == .journal && !ref.snippet.isEmpty ? ref.snippet : nil
    }

    static func linkedFromTitle(_ module: BrainModuleID) -> String {
        module == .people ? "Mentioned in" : "Linked from"
    }
}

/// One page of the Brain (wiki, article, journal day, video note or person), pushed
/// as `.brainRoute(.page(module, id))` for every id that isn't a book. Owns no
/// `NavigationStack`: `push` and the rows' `NavigationLink`s go onto the shell's.
struct BrainReaderView: View {
    @State private var viewModel: BrainPageViewModel
    @State private var didLoad = false
    private let push: (BrainRoute) -> Void

    init(module: BrainModuleID, id: String, server: URL, modelContext: ModelContext,
         onAPIError: @escaping (Error) -> Void, push: @escaping (BrainRoute) -> Void) {
        let client = APIClientBrainAdapter(apiClient: APIClient(baseURL: server))
        let cache = BrainCacheHandle(server: server, context: modelContext)
        _viewModel = State(initialValue: BrainPageViewModel(
            module: module, id: id, client: client, cache: cache, onAPIError: onAPIError))
        self.push = push
    }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: viewModel.page?.item.title ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.hxCanvas.ignoresSafeArea())
            .task {
                guard didLoad else {
                    didLoad = true
                    await viewModel.load()
                    return
                }
                // Back on screen after an earlier task was cancelled: finish what it dropped.
                if viewModel.state == .loading {
                    await viewModel.load()
                } else {
                    await viewModel.loadGraphIfNeeded()
                }
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
                graph: viewModel.graph,
                isShowingCachedCopy: viewModel.isShowingCachedCopy,
                isMissing: viewModel.isMissing,
                push: push
            )
            .refreshable { await viewModel.load() }
        }
    }
}

/// A loaded page, top to bottom (spec §3): header, title block (or person card),
/// tags, body, Linked from, Further reading, and journal paging.
struct BrainReaderContent: View {
    let page: BrainPage
    let graph: BrainGraph?
    let isShowingCachedCopy: Bool
    let isMissing: Bool
    let push: (BrainRoute) -> Void
    /// Built once per page, never in `body`.
    private let cover: BrainCoverSpec
    /// Articles and video notes in the summary outline read as a digest.
    private let digest: BrainArticleDigest?
    @State private var showsAllBacklinks = false

    init(page: BrainPage, graph: BrainGraph?, isShowingCachedCopy: Bool, isMissing: Bool = false,
         push: @escaping (BrainRoute) -> Void) {
        self.page = page
        self.graph = graph
        self.isShowingCachedCopy = isShowingCachedCopy
        self.isMissing = isMissing
        self.push = push
        self.cover = BrainReaderLayout.cover(for: page.item)
        self.digest = BrainReaderLayout.digest(for: page)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.xl) {
                VStack(alignment: .leading, spacing: BrainStyle.l) {
                    header
                    if page.item.module == .people {
                        BrainPersonCardView(item: page.item, facts: page.facts)
                    } else {
                        titleBlock
                    }
                    if !BrainReaderLayout.displayTags(page.item.tags).isEmpty {
                        tagRow
                    }
                }
                if !page.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Group {
                        if let digest {
                            BrainArticleDigestView(digest: digest)
                        } else {
                            MarkdownRenderer(content: page.content)
                        }
                    }
                    .environment(\.openURL, OpenURLAction { url in
                        switch BrainReaderLayout.linkAction(for: url) {
                        case .push(let route):
                            push(route)
                            return .handled
                        case .discard:
                            return .discarded
                        case .system:
                            return .systemAction
                        }
                    })
                }
                linkedFrom
                furtherReading
                journalPaging
                if isShowingCachedCopy {
                    Text(verbatim: BrainReaderLayout.cachedCopyFooter(isMissing: isMissing))
                        .brainText(.meta)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(BrainStyle.l)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        }
    }

    @ViewBuilder
    private var header: some View {
        if let graph, BrainReaderLayout.showsGraph(graph, centerID: page.item.id) {
            BrainGraphView(graph: graph, centerID: page.item.id, ramp: cover.ramp) { module, id in
                push(.page(module, id))
            }
            .clipShape(BrainStyle.cardShape())
        } else {
            BrainCoverView(spec: cover)
                .frame(height: BrainReaderLayout.headerHeight)
                .frame(maxWidth: .infinity)
                .clipShape(BrainStyle.cardShape())
        }
    }

    private var titleBlock: some View {
        let meta = BrainReaderLayout.metaLine(kind: page.item.kind, date: page.item.date)
        return VStack(alignment: .leading, spacing: BrainStyle.xs) {
            if !meta.isEmpty {
                Text(verbatim: meta)
                    .brainText(.meta)
            }
            Text(verbatim: page.item.title)
                .brainText(.readerTitle)
                .accessibilityAddTraits(.isHeader)
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

    @ViewBuilder
    private var linkedFrom: some View {
        let backlinks = page.backlinks
        if !backlinks.isEmpty {
            BrainReaderRefSection(
                title: BrainReaderLayout.linkedFromTitle(page.item.module),
                count: backlinks.count,
                rows: BrainReaderLayout.visibleBacklinks(backlinks, expanded: showsAllBacklinks).map {
                    BrainReaderRefSection.Row(ref: $0, subtitle: BrainReaderLayout.backlinkSubtitle($0) ?? "")
                },
                showAllTitle: BrainReaderLayout.hasMoreBacklinks(backlinks, expanded: showsAllBacklinks)
                    ? BrainReaderLayout.showAllTitle(backlinks.count) : nil,
                onShowAll: { showsAllBacklinks = true }
            )
        }
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
    /// The separator starts where the row's text does (thumbnail plus spacing).
    @ScaledMetric(relativeTo: .body) private var separatorInset = BrainStyle.searchThumbnailSize + BrainStyle.m

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: title, count: count)
            VStack(spacing: 0) {
                // A section's rows never reorder ("Show all" only appends), so position is a stable id.
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { separator }
                    NavigationLink(value: ShellPushDestination.brainRoute(.page(row.ref.module, row.ref.id))) {
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
