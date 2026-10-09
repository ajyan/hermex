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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BrainStyle.l) {
                Picker(selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { segment in
                        Text(verbatim: segment.title).tag(segment)
                    }
                } label: {
                    Text(verbatim: "Highlights")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, BrainStyle.l)

                BrainListStateView(viewModel: viewModel, inline: true) { list in
                    segmentContent(list)
                }
            }
            .padding(.vertical, BrainStyle.l)
        }
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

    @ViewBuilder
    private func segmentContent(_ list: BrainList) -> some View {
        let split = BrainListLayout.splitHighlights(list)
        let items = segment == .books ? split.books : split.videos
        let lastID = items.last?.id
        if items.isEmpty {
            Text(verbatim: segment == .books ? "No book highlights yet" : "No videos yet")
                .brainText(.rowSubtitle)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, BrainStyle.xl)
        } else if segment == .books {
            LazyVGrid(columns: BrainListLayout.columns(3, dynamicType: dynamicTypeSize), spacing: BrainStyle.m) {
                ForEach(items, id: \.id) { item in
                    NavigationLink(value: ShellPushDestination.brainRoute(.page(.highlights, item.id))) {
                        BrainCard(item: item, style: .tile)
                    }
                    .buttonStyle(.plain)
                    .onAppear { if item.id == lastID { loadMore() } }
                }
            }
            .padding(.horizontal, BrainStyle.l)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(items, id: \.id) { item in
                    NavigationLink(value: ShellPushDestination.brainRoute(.page(.highlights, item.id))) {
                        BrainCoverRow(item: item, side: BrainStyle.searchThumbnailSize)
                            .padding(.horizontal, BrainStyle.l)
                            .background(Color.hxSurface)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if item.id != lastID {
                            Divider().padding(.leading, BrainStyle.l)
                        }
                    }
                    .onAppear { if item.id == lastID { loadMore() } }
                }
            }
        }
        BrainListFooter(viewModel: viewModel)
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
        let shape = BrainStyle.cardShape()
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
        .background(Color.hxSurface, in: shape)
        .contentShape(.contextMenuPreview, shape)
        .contextMenu {
            Button {
                UIPasteboard.general.string = highlight.text
            } label: {
                Label { Text(verbatim: "Copy") } icon: { Image(systemName: "doc.on.doc") }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
