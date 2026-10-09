import SwiftUI

/// Every search result in one module ("See all" from the Brain home). Pushed onto
/// the shell's stack as `.brainRoute(.searchAll(_:query:))`; owns no `NavigationStack`.
struct BrainSearchView: View {
    let module: BrainModuleID
    private let initialQuery: String
    @State private var viewModel: BrainSearchViewModel
    @State private var didStart = false

    init(module: BrainModuleID, query: String, server: URL, onAPIError: @escaping (Error) -> Void) {
        self.module = module
        self.initialQuery = query
        let client = APIClientBrainAdapter(apiClient: APIClient(baseURL: server))
        // Inert until `query` is set in `.task`, so a discarded init never searches.
        _viewModel = State(initialValue: BrainSearchViewModel(client: client, onAPIError: onAPIError))
    }

    var body: some View {
        List {
            BrainSearchResults(
                query: viewModel.query,
                result: viewModel.result,
                isSearching: viewModel.isSearching,
                didFail: viewModel.didFail,
                moduleTitles: [:],
                showsSeeAll: false
            )
        }
        .brainListStyle()
        .navigationTitle(Text(verbatim: module.defaultTitle))
        .searchable(
            text: $viewModel.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(verbatim: "Search \(module.defaultTitle.lowercased())")
        )
        .autocorrectionDisabled()
        .task {
            guard !didStart else { return }
            didStart = true
            viewModel.moduleFilter = module
            viewModel.query = initialQuery
        }
    }
}

/// Grouped search results as `List` sections: a header per module, one row per hit,
/// and "See all N" when the server holds more. Also shows the inline searching,
/// failed and no-results states. Renders nothing below the 2-character minimum.
struct BrainSearchResults: View {
    let query: String
    let result: BrainSearchResult?
    let isSearching: Bool
    let didFail: Bool
    /// Server-provided module titles; a missing one falls back to `defaultTitle`.
    let moduleTitles: [BrainModuleID: String]
    let showsSeeAll: Bool

    /// The query the view model actually searches for.
    static func trimmed(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when a query is long enough to search (the view model's minimum).
    static func isActive(_ query: String) -> Bool {
        trimmed(query).count >= 2
    }

    var body: some View {
        if Self.isActive(query) {
            if didFail {
                Text(verbatim: "Couldn't search. Check your connection.")
                    .brainText(.rowSubtitle)
                    .frame(minHeight: BrainStyle.minTapTarget)
                    .brainListRow()
            } else if let result {
                let groups = result.groups.filter { !$0.items.isEmpty }
                if groups.isEmpty {
                    if isSearching {
                        progressRow
                    } else {
                        ContentUnavailableView.search(text: Self.trimmed(query))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(groups, id: \.module) { group in
                        section(for: group)
                    }
                }
            } else if isSearching {
                progressRow
            }
        }
    }

    /// A small inline spinner; search never takes over the screen.
    private var progressRow: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
            .accessibilityLabel(Text(verbatim: "Searching"))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func section(for group: BrainSearchGroup) -> some View {
        Section {
            ForEach(group.items, id: \.id) { ref in
                NavigationLink(value: ShellPushDestination.brainRoute(.page(ref.module, ref.id))) {
                    BrainSearchResultRow(ref: ref)
                }
                .brainListRow()
            }
            if showsSeeAll, group.total > group.items.count {
                NavigationLink(
                    value: ShellPushDestination.brainRoute(.searchAll(group.module, query: Self.trimmed(query)))
                ) {
                    Text(verbatim: "See all \(group.total)")
                        .font(BrainStyle.rowSubtitle)
                        .foregroundStyle(Color.accentColor)
                        .frame(minHeight: BrainStyle.minTapTarget)
                }
                .brainListRow()
            }
        } header: {
            BrainSectionHeader(
                title: moduleTitles[group.module] ?? group.module.defaultTitle,
                count: group.total
            )
            .textCase(nil)
        }
    }
}

/// One search hit: a monogram for people, a small cover for everything else, the
/// title, and the matching snippet as the subtitle.
struct BrainSearchResultRow: View {
    let ref: BrainRef
    /// Built once per row, never in `body`.
    private let cover: BrainCoverSpec?
    @ScaledMetric(relativeTo: .body) private var side = BrainStyle.searchThumbnailSize

    init(ref: BrainRef) {
        self.ref = ref
        self.cover = ref.module == .people ? nil : BrainCoverSpec.make(id: ref.id, tag: nil)
    }

    var body: some View {
        BrainRow(
            leading: { leading },
            title: ref.title.isEmpty ? ref.id : ref.title,
            subtitle: ref.snippet
        )
    }

    @ViewBuilder
    private var leading: some View {
        if let cover {
            BrainCoverView(spec: cover)
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: BrainStyle.thumbnailCorner, style: .continuous))
                .drawingGroup()
        } else {
            BrainMonogram(name: ref.title, size: side)
        }
    }
}
