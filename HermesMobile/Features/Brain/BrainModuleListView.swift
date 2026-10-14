import SwiftData
import SwiftUI

/// Pure list shaping shared by the module lists and highlights, kept out of the views
/// so it can be tested.
enum BrainListLayout {
    /// One titled run of items, from a server group (or the whole list when it has none).
    struct Section: Equatable {
        let title: String
        let items: [BrainItem]
    }

    /// How many tags the chip bar offers besides "All".
    static let chipLimit = 12

    /// `items` minus repeated ids, first occurrence kept (pages can overlap).
    static func uniqueItems(_ items: [BrainItem]) -> [BrainItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    /// Resolves a group's ids into items, in the group's order, skipping ids that are
    /// missing from `items` and ids already resolved.
    static func resolve(_ ids: [String], in items: [BrainItem]) -> [BrainItem] {
        let index = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return index[id]
        }
    }

    /// The list's groups as sections, dropping empty ones. A list without groups is
    /// one untitled section of all its items.
    static func sections(_ list: BrainList) -> [Section] {
        guard !list.groups.isEmpty else {
            return [Section(title: "", items: uniqueItems(list.items))]
        }
        return list.groups.compactMap { group in
            let items = resolve(group.ids, in: list.items)
            return items.isEmpty ? nil : Section(title: group.title, items: items)
        }
    }

    /// Highlights split into books (`kind == "book"`) and videos (the `YouTube` group,
    /// or every non-book item when the server sends no such group).
    static func splitHighlights(_ list: BrainList) -> (books: [BrainItem], videos: [BrainItem]) {
        let items = uniqueItems(list.items)
        let books = items.filter { $0.kind == "book" }
        let videos: [BrainItem]
        if let group = list.groups.first(where: { $0.title.caseInsensitiveCompare("YouTube") == .orderedSame }) {
            videos = resolve(group.ids, in: items).filter { $0.kind != "book" }
        } else {
            videos = items.filter { $0.kind != "book" }
        }
        return (books, videos)
    }

    /// The chip bar's tags: the `limit` most used (ties keep server order), without
    /// blanks or repeats, plus the selected tag if it fell outside them.
    static func topTags(_ tags: [BrainTagCount], selected: String? = nil, limit: Int = chipLimit) -> [String] {
        var seen = Set<String>()
        let ranked = tags.enumerated()
            .filter { !$0.element.tag.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .map(\.element.tag)
            .filter { seen.insert($0).inserted }
        var top = Array(ranked.prefix(limit))
        if let selected, !selected.isEmpty, !top.contains(selected) {
            top.append(selected)
        }
        return top
    }

    /// Wiki's concept group, shown as a cover grid; every other group is rows.
    static func isGridSection(_ title: String) -> Bool {
        title.caseInsensitiveCompare("Concepts") == .orderedSame
    }

    /// One grid row of cards, identified by its first item's id.
    struct Chunk: Equatable {
        let id: String
        let items: [BrainItem]
    }

    /// Splits `items` into rows of `size` cards, in order; the last row may be short.
    static func chunks(_ items: [BrainItem], size: Int) -> [Chunk] {
        let size = max(size, 1)
        return stride(from: 0, to: items.count, by: size).map { start in
            let row = Array(items[start..<min(start + size, items.count)])
            return Chunk(id: row[0].id, items: row)
        }
    }

    /// Cards per grid row, dropping to one at accessibility text sizes so cards never squeeze.
    static func columnCount(_ count: Int, dynamicType: DynamicTypeSize) -> Int {
        dynamicType.isAccessibilitySize ? 1 : max(count, 1)
    }
}

/// Name lookup for the People list: each typed word must start some word of the name,
/// ignoring case and accents. People whose first name matches come first; otherwise the
/// list keeps its order.
enum BrainPeopleSearch {
    static func matches(_ people: [BrainItem], query: String) -> [BrainItem] {
        let typed = words(query)
        guard !typed.isEmpty else { return people }
        var firstNameHits: [BrainItem] = []
        var otherHits: [BrainItem] = []
        for person in people {
            let name = words(person.title)
            guard typed.allSatisfy({ word in name.contains { $0.hasPrefix(word) } }) else { continue }
            if name.first?.hasPrefix(typed[0]) == true {
                firstNameHits.append(person)
            } else {
                otherHits.append(person)
            }
        }
        return firstNameHits + otherHits
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}

/// One module's browsable list (people, wiki, articles, journal), shaped per spec §2.
/// Every module screen is one `List` in the shared Brain style; grids are chunked
/// rows of cards. Pushed as `.brainRoute(.module(_:))`; owns no `NavigationStack`.
/// Every cell pushes `.brainRoute(.page(module, id))`.
struct BrainModuleListView: View {
    let module: BrainModuleID
    /// Pushes onto the shell's stack; grid cards push through this, not `NavigationLink`.
    private let push: (BrainRoute) -> Void
    @State private var viewModel: BrainListViewModel
    @State private var didLoad = false
    /// The chip bar, frozen from the unfiltered list so filtering never reshuffles it.
    @State private var chipTags: [String] = []
    /// People only: the name being looked up, and whether the field has taken focus once.
    @State private var peopleQuery = ""
    @State private var didFocusPeopleSearch = false
    @FocusState private var isPeopleSearchFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        module: BrainModuleID,
        server: URL,
        modelContext: ModelContext,
        onAPIError: @escaping (Error) -> Void,
        push: @escaping (BrainRoute) -> Void
    ) {
        self.module = module
        self.push = push
        let client = APIClientBrainAdapter(apiClient: APIClient(baseURL: server))
        let cache = BrainCacheHandle(server: server, context: modelContext)
        _viewModel = State(initialValue: BrainListViewModel(
            module: module, client: client, cache: cache, onAPIError: onAPIError))
    }

    private var hasChipBar: Bool { module == .wiki || module == .articles }

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if module == .people { peopleSearchField }
            }
            .task {
                // Keyboard up on first open only, not on the way back from a person. Focus set
                // during the push is dropped, so it waits for the push to finish.
                guard module == .people, !didFocusPeopleSearch else { return }
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                didFocusPeopleSearch = true
                isPeopleSearchFocused = true
            }
            .hxNavigationTitle(module.defaultTitle)
            .background(Color.hxCanvas.ignoresSafeArea())
            .task {
                // Load once; a pop back from a page keeps the pages already scrolled.
                // Re-run a first load that was cancelled before it finished, or it spins forever.
                guard !didLoad || viewModel.state == .loading else { return }
                didLoad = true
                await viewModel.load()
            }
            .onChange(of: viewModel.list) { _, list in
                guard hasChipBar, viewModel.selectedTag == nil, let list, !list.tags.isEmpty else { return }
                chipTags = BrainListLayout.topTags(list.tags)
            }
    }

    @ViewBuilder
    private var content: some View {
        if module == .journal {
            BrainListStateView(viewModel: viewModel) { list in
                BrainJournalCalendarView(
                    list: list,
                    isLoadingOlder: list.nextCursor != nil && !viewModel.loadMoreFailed,
                    loadOlderFailed: viewModel.loadMoreFailed,
                    onRetry: { loadMore() }
                )
                .refreshable { await viewModel.load() }
                // Older pages load one after another so earlier months fill in.
                .task(id: list.nextCursor) {
                    if list.nextCursor != nil { await viewModel.loadMore() }
                }
            }
        } else if hasChipBar, !chipTags.isEmpty {
            // The chip bar stays put while a tag reloads; the state shows beneath it.
            List {
                Section {
                    BrainTagChipBar(tags: chipTags, selected: $viewModel.selectedTag)
                        .brainListClearRow(edgeToEdge: true)
                }
                BrainListStateView(viewModel: viewModel, inline: true) { list in
                    loadedSections(list)
                }
            }
            .brainListStyle()
            .refreshable { await viewModel.load() }
        } else {
            BrainListStateView(viewModel: viewModel) { list in
                List { loadedSections(list) }
                    .brainListStyle()
                    .refreshable { await viewModel.load() }
            }
        }
    }

    @ViewBuilder
    private func loadedSections(_ list: BrainList) -> some View {
        switch module {
        case .people: peopleSection(list)
        // The journal is a calendar (`BrainJournalCalendarView`), never these sections.
        case .journal: EmptyView()
        case .wiki: wikiSections(list)
        // Highlights routes to `BrainHighlightsView`; it shares the article grid only to
        // keep the switch exhaustive.
        case .articles, .highlights: articleSection(list)
        }
        // A clear row, not a section footer: a plain list paints footers in the system background.
        Section {
            BrainListFooter(viewModel: viewModel)
                .brainListClearRow()
        }
    }

    private func link(_ id: String) -> ShellPushDestination {
        .brainRoute(.page(module, id))
    }

    // MARK: People

    private func peopleSection(_ list: BrainList) -> some View {
        let items = peopleMatches(list)
        let lastID = items.last?.id
        let query = peopleQuery.trimmingCharacters(in: .whitespaces)
        return Section {
            ForEach(items, id: \.id) { item in
                NavigationLink(value: link(item.id)) {
                    BrainPeopleRow(item: item)
                }
                .brainListRow()
                .onAppear { if item.id == lastID { loadMore() } }
            }
            if items.isEmpty, !query.isEmpty {
                Text("No one named \u{201C}\(query)\u{201D}")
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .brainListRow()
            }
        }
        // A search covers everyone, so pages past the first load while there's a query.
        .task(id: query.isEmpty ? nil : list.nextCursor) {
            if !query.isEmpty, list.nextCursor != nil { await viewModel.loadMore() }
        }
    }

    private func peopleMatches(_ list: BrainList) -> [BrainItem] {
        BrainPeopleSearch.matches(BrainListLayout.uniqueItems(list.items), query: peopleQuery)
    }

    /// Pinned above the People list. Return opens the top match.
    private var peopleSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search people", text: $peopleQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isPeopleSearchFocused)
                .submitLabel(.go)
                .onSubmit {
                    guard let list = viewModel.list,
                          !peopleQuery.trimmingCharacters(in: .whitespaces).isEmpty,
                          let top = peopleMatches(list).first
                    else { return }
                    push(.page(.people, top.id))
                }

            if !peopleQuery.isEmpty {
                Button {
                    peopleQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.hxCanvas)
    }

    // MARK: Wiki

    private func wikiSections(_ list: BrainList) -> some View {
        let sections = BrainListLayout.sections(list)
        let lastID = sections.last?.items.last?.id
        return ForEach(sections, id: \.title) { section in
            Section {
                if BrainListLayout.isGridSection(section.title) {
                    cardRows(section.items, columns: 2, lastID: lastID)
                } else {
                    ForEach(section.items, id: \.id) { item in
                        NavigationLink(value: link(item.id)) {
                            BrainCoverRow(item: item)
                        }
                        .brainListRow()
                        .onAppear { if item.id == lastID { loadMore() } }
                    }
                }
            } header: {
                if !section.title.isEmpty {
                    BrainSectionHeader(title: section.title, count: section.items.count)
                }
            }
        }
    }

    // MARK: Articles

    private func articleSection(_ list: BrainList) -> some View {
        let items = BrainListLayout.uniqueItems(list.items)
        return Section {
            cardRows(items, columns: 2, lastID: items.last?.id)
        }
    }

    private func cardRows(_ items: [BrainItem], columns: Int, lastID: String?) -> some View {
        BrainCardRows(
            items: items,
            columns: BrainListLayout.columnCount(columns, dynamicType: dynamicTypeSize),
            destination: link,
            open: { push(.page(module, $0)) },
            onLastAppear: { if items.last?.id == lastID { loadMore() } }
        )
    }

    private func loadMore() {
        Task { await viewModel.loadMore() }
    }
}

// MARK: - Shared pieces

/// The load-state switch every module list shares: a spinner, the unavailable and
/// failed states, an empty state, or the loaded list. `inline` lays the states out
/// for a slot inside a scroll view (under the chip bar) instead of filling the screen.
struct BrainListStateView<Loaded: View>: View {
    let viewModel: BrainListViewModel
    var inline = false
    @ViewBuilder let loaded: (BrainList) -> Loaded

    var body: some View {
        if case .loaded(let list) = viewModel.state, !list.items.isEmpty {
            loaded(list)
        } else if inline {
            placeholder.brainListClearRow()
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: inline ? nil : .infinity)
                .padding(.vertical, inline ? BrainStyle.xl : 0)
        case .unavailable:
            ContentUnavailableView {
                Label { Text(verbatim: "No Brain on this server") } icon: { Image(systemName: "brain") }
            } description: {
                Text(verbatim: "This server doesn't serve the Second Brain. It needs the Brain API from your hermes-webui fork.")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label { Text(verbatim: "Couldn't load this list") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(verbatim: message)
            } actions: {
                Button { Task { await viewModel.load() } } label: { Text(verbatim: "Try again") }
            }
        case .loaded:
            ContentUnavailableView {
                Label { Text(verbatim: emptyTitle) } icon: { Image(systemName: viewModel.module.symbolName) }
            } description: {
                Text(verbatim: emptyDescription)
            }
        }
    }

    private var emptyTitle: String {
        viewModel.selectedTag == nil ? "Nothing here yet" : "Nothing with this tag"
    }

    private var emptyDescription: String {
        viewModel.selectedTag == nil
            ? "Items appear here once the server has notes to show."
            : "Pick another tag, or All to see everything."
    }
}

/// A cover grid as `List` rows: each row is an `HStack` of up to `columns` cards with
/// equal widths (a short last row keeps its cards at grid width). Each card is its own
/// borderless `Button` calling `open`: a `List` row fires every `NavigationLink` it
/// holds on one tap, so links here would push the whole row.
struct BrainCardRows: View {
    let items: [BrainItem]
    let columns: Int
    var style: BrainCard.Style = .standard
    /// The screen a card's item id opens, so the screen zooms out of the card.
    var destination: ((String) -> ShellPushDestination)?
    /// Opens one card's item id.
    let open: (String) -> Void
    /// Called when the last row appears, for pagination.
    let onLastAppear: () -> Void

    var body: some View {
        // De-duped like every other list, so a repeated id never repeats a chunk or card id.
        let chunks = BrainListLayout.chunks(BrainListLayout.uniqueItems(items), size: columns)
        let lastChunkID = chunks.last?.id
        ForEach(chunks, id: \.id) { chunk in
            HStack(alignment: .top, spacing: BrainStyle.m) {
                ForEach(chunk.items, id: \.id) { item in
                    Button { open(item.id) } label: {
                        if let destination {
                            BrainCard(item: item, style: style)
                                .zoomSource(for: destination(item.id), cornerRadius: BrainStyle.cardCorner)
                        } else {
                            BrainCard(item: item, style: style)
                        }
                    }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .frame(maxWidth: .infinity)
                }
                ForEach(chunk.items.count..<columns, id: \.self) { _ in
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: 0)
                        .accessibilityHidden(true)
                }
            }
            // Half the card spacing above and below, so rows sit one card gap apart.
            .listRowInsets(EdgeInsets(top: BrainStyle.m / 2, leading: BrainStyle.l,
                                      bottom: BrainStyle.m / 2, trailing: BrainStyle.l))
            .brainListClearRow()
            .onAppear { if chunk.id == lastChunkID { onLastAppear() } }
        }
    }
}

/// Below a list: a spinner while the next page loads, and the offline note when the
/// list is a saved copy.
struct BrainListFooter: View {
    let viewModel: BrainListViewModel
    /// Off when another row already shows the page spinner.
    var showsPageSpinner = true

    var body: some View {
        VStack(spacing: BrainStyle.s) {
            if showsPageSpinner, viewModel.isLoadingMore {
                ProgressView()
            }
            if viewModel.isShowingCachedCopy {
                Text(verbatim: "Offline, showing saved copy")
                    .brainText(.meta)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, BrainStyle.s)
    }
}

/// "All" plus the top tags, as a horizontal row of chips. The selected chip takes
/// the accent; tapping sets the list's tag filter.
struct BrainTagChipBar: View {
    let tags: [String]
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BrainStyle.s) {
                chip(title: "All", tag: nil)
                ForEach(tags, id: \.self) { tag in
                    chip(title: tag, tag: tag)
                }
            }
            .padding(.horizontal, BrainStyle.l)
        }
    }

    private func chip(title: String, tag: String?) -> some View {
        Button {
            selected = tag
        } label: {
            BrainTagChip(tag: title, selected: selected == tag)
                .frame(minHeight: BrainStyle.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A person: monogram, the relationship as the subtitle, and the badge (an upcoming
/// birthday) as an accent capsule.
struct BrainPeopleRow: View {
    let item: BrainItem
    @ScaledMetric(relativeTo: .body) private var side = BrainStyle.thumbnailSize

    var body: some View {
        BrainRow(
            leading: { BrainMonogram(name: item.title, size: side) },
            title: item.title,
            subtitle: item.subtitle,
            badge: item.badge
        )
    }
}

/// A row led by a square cover thumbnail, its spec built once per row.
struct BrainCoverRow: View {
    let item: BrainItem
    private let cover: BrainCoverSpec
    private let baseSide: CGFloat
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    init(item: BrainItem, side: CGFloat = BrainStyle.thumbnailSize) {
        self.item = item
        self.baseSide = side
        self.cover = BrainCoverSpec.make(id: item.id, tag: item.tags.first)
    }

    var body: some View {
        BrainRow(
            leading: {
                BrainCoverView(spec: cover)
                    .frame(width: baseSide * scale, height: baseSide * scale)
                    .clipShape(RoundedRectangle(cornerRadius: BrainStyle.thumbnailCorner, style: .continuous))
                    .drawingGroup()
            },
            title: item.title,
            subtitle: item.subtitle
        )
    }
}

