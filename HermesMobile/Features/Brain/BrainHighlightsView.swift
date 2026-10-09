import SwiftData
import SwiftUI

/// Highlights: a Books / YouTube switch over the one `highlights` list. Books are a
/// three-column grid of title tiles; videos are cover rows with the channel. Pushed
/// as `.brainRoute(.module(.highlights))`; owns no `NavigationStack`.
struct BrainHighlightsView: View {
    enum Segment: Hashable, CaseIterable {
        case books, videos

        var title: String {
            switch self {
            case .books: "Books"
            case .videos: "YouTube"
            }
        }
    }

    @State private var viewModel: BrainListViewModel
    @State private var segment: Segment = .books
    @State private var didLoad = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(server: URL, modelContext: ModelContext, onAPIError: @escaping (Error) -> Void) {
        let client = APIClientBrainAdapter(apiClient: APIClient(baseURL: server))
        let cache = BrainCacheHandle(server: server, context: modelContext)
        _viewModel = State(initialValue: BrainListViewModel(
            module: .highlights, client: client, cache: cache, onAPIError: onAPIError))
    }

    var body: some View {
        List {
            Section {
                Picker(selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { segment in
                        Text(verbatim: segment.title).tag(segment)
                    }
                } label: {
                    Text(verbatim: "Highlights")
                }
                .pickerStyle(.segmented)
                .brainListClearRow()
            }
            BrainListStateView(viewModel: viewModel, inline: true) { list in
                segmentSection(list)
                Section {
                    EmptyView()
                } footer: {
                    BrainListFooter(viewModel: viewModel)
                }
            }
        }
        .brainListStyle()
        .refreshable { await viewModel.load() }
        .navigationTitle(Text(verbatim: BrainModuleID.highlights.defaultTitle))
        .background(Color.hxCanvas.ignoresSafeArea())
        .task {
            // Load once; a pop back from a book keeps the pages already scrolled.
            guard !didLoad else { return }
            didLoad = true
            await viewModel.load()
        }
    }

    private func segmentSection(_ list: BrainList) -> some View {
        let split = BrainListLayout.splitHighlights(list)
        let items = segment == .books ? split.books : split.videos
        let lastID = items.last?.id
        return Section {
            if items.isEmpty {
                emptySegment(hasMore: list.nextCursor != nil)
                    // This segment may only start on a later page: keep paging until it
                    // fills or the list runs out, so the empty state is never a false one.
                    .task(id: list.items.count) {
                        if list.nextCursor != nil { await viewModel.loadMore() }
                    }
            } else if segment == .books {
                BrainCardRows(
                    items: items,
                    columns: BrainListLayout.columnCount(3, dynamicType: dynamicTypeSize),
                    style: .tile,
                    destination: { .brainRoute(.page(.highlights, $0)) },
                    onLastAppear: loadMore
                )
            } else {
                ForEach(items, id: \.id) { item in
                    NavigationLink(value: ShellPushDestination.brainRoute(.page(.highlights, item.id))) {
                        BrainCoverRow(item: item)
                    }
                    .brainListRow()
                    .onAppear { if item.id == lastID { loadMore() } }
                }
            }
        }
    }

    @ViewBuilder
    private func emptySegment(hasMore: Bool) -> some View {
        Group {
            if hasMore {
                ProgressView()
            } else {
                Text(verbatim: segment == .books ? "No book highlights yet" : "No videos yet")
                    .brainText(.rowSubtitle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, BrainStyle.xl)
        .brainListClearRow()
    }

    private func loadMore() {
        Task { await viewModel.loadMore() }
    }
}

/// One book's highlights as quote cards in the serif `quote` voice, each with its
/// note in `meta`. Long-press copies a highlight. Pushed as
/// `.brainRoute(.page(.highlights, "book:…"))`; owns no `NavigationStack`.
struct BrainHighlightsBookView: View {
    @State private var viewModel: BrainPageViewModel
    @State private var didLoad = false

    /// Whether a highlights page id names a book (and so gets this view).
    static func isBook(module: BrainModuleID, id: String) -> Bool {
        module == .highlights && id.hasPrefix("book:")
    }

    init(id: String, server: URL, modelContext: ModelContext, onAPIError: @escaping (Error) -> Void) {
        let client = APIClientBrainAdapter(apiClient: APIClient(baseURL: server))
        let cache = BrainCacheHandle(server: server, context: modelContext)
        _viewModel = State(initialValue: BrainPageViewModel(
            module: .highlights, id: id, client: client, cache: cache, onAPIError: onAPIError))
    }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: viewModel.page?.item.title ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.hxCanvas.ignoresSafeArea())
            .task {
                guard !didLoad else { return }
                didLoad = true
                await viewModel.load()
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
        case .failed(let message):
            ContentUnavailableView {
                Label { Text(verbatim: "Couldn't load this book") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(verbatim: message)
            } actions: {
                Button { Task { await viewModel.load() } } label: { Text(verbatim: "Try again") }
            }
        case .loaded(let page):
            BrainHighlightsBookContent(page: page, isShowingCachedCopy: viewModel.isShowingCachedCopy)
                .refreshable { await viewModel.load() }
        }
    }
}

/// The loaded book: a header (title, author, count) over its quote cards.
struct BrainHighlightsBookContent: View {
    let page: BrainPage
    var isShowingCachedCopy = false

    static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 highlight" : "\(count) highlights"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BrainStyle.m) {
                header
                    .padding(.bottom, BrainStyle.s)
                if page.highlights.isEmpty {
                    Text(verbatim: "No highlights in this book yet")
                        .brainText(.rowSubtitle)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, BrainStyle.xl)
                }
                // A page's highlights never reorder, so their position is a stable id.
                ForEach(Array(page.highlights.enumerated()), id: \.offset) { _, highlight in
                    BrainQuoteCard(highlight: highlight)
                }
                if isShowingCachedCopy {
                    Text(verbatim: "Offline, showing saved copy")
                        .brainText(.meta)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, BrainStyle.s)
                }
            }
            .padding(BrainStyle.l)
        }
        .adaptiveReadableScrollContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            Text(verbatim: page.item.title)
                .brainText(.readerTitle)
                .accessibilityAddTraits(.isHeader)
            if !page.item.subtitle.isEmpty {
                Text(verbatim: page.item.subtitle)
                    .brainText(.rowSubtitle)
            }
            Text(verbatim: Self.countLabel(page.highlights.count))
                .brainText(.meta)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One highlight: the quote in the serif voice on a surface card, the note below in
/// `meta`. Long-press offers Copy.
struct BrainQuoteCard: View {
    let highlight: BrainHighlight

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            Text(verbatim: highlight.text)
                .brainText(.quote)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let note = highlight.note, !note.isEmpty {
                Text(verbatim: note)
                    .brainText(.meta)
            }
        }
        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
        .padding(.vertical, BrainStyle.cardVerticalPadding)
        .brainCardSurface()
        .contentShape(.contextMenuPreview, BrainStyle.cardShape())
        .contextMenu {
            Button(action: copy) {
                Label { Text(verbatim: "Copy") } icon: { Image(systemName: "doc.on.doc") }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(verbatim: "Copy"), copy)
    }

    private func copy() {
        UIPasteboard.general.string = highlight.text
    }
}
