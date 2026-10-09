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

    /// Grid columns, collapsing at accessibility text sizes so cards never squeeze.
    static func columns(_ count: Int, dynamicType: DynamicTypeSize) -> [GridItem] {
        let resolved = dynamicType.isAccessibilitySize ? max(count - 1, 1) : count
        return Array(repeating: GridItem(.flexible(), spacing: BrainStyle.m, alignment: .top), count: resolved)
    }
}

/// One module's browsable list (people, wiki, articles, journal), shaped per spec §2.
/// Pushed as `.brainRoute(.module(_:))`; owns no `NavigationStack`. Every cell pushes
/// `.brainRoute(.page(module, id))`.
struct BrainModuleListView: View {
    let module: BrainModuleID
    @State private var viewModel: BrainListViewModel
    @State private var didLoad = false
    /// The chip bar, frozen from the unfiltered list so filtering never reshuffles it.
    @State private var chipTags: [String] = []
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(module: BrainModuleID, server: URL, modelContext: ModelContext, onAPIError: @escaping (Error) -> Void) {
        self.module = module
        let client = APIClientBrainAdapter(apiClient: APIClient(baseURL: server))
        let cache = BrainCacheHandle(server: server, context: modelContext)
        _viewModel = State(initialValue: BrainListViewModel(
            module: module, client: client, cache: cache, onAPIError: onAPIError))
    }

    private var hasChipBar: Bool { module == .wiki || module == .articles }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: module.defaultTitle))
            .background(Color.hxCanvas.ignoresSafeArea())
            .task {
                // Load once; a pop back from a page keeps the pages already scrolled.
                guard !didLoad else { return }
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
        switch module {
        case .people, .journal:
            BrainListStateView(viewModel: viewModel) { list in
                if module == .people { peopleList(list) } else { journalList(list) }
            }
        case .wiki, .articles, .highlights:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: BrainStyle.l) {
                    if hasChipBar, !chipTags.isEmpty {
                        BrainTagChipBar(tags: chipTags, selected: $viewModel.selectedTag)
                    }
                    BrainListStateView(viewModel: viewModel, inline: true) { list in
                        if module == .wiki { wikiSections(list) } else { articleGrid(list) }
                    }
                }
                .padding(.vertical, BrainStyle.l)
            }
            .refreshable { await viewModel.load() }
        }
    }

    // MARK: People

    private func peopleList(_ list: BrainList) -> some View {
        let items = BrainListLayout.uniqueItems(list.items)
        let lastID = items.last?.id
        return List {
            Section {
                ForEach(items, id: \.id) { item in
                    NavigationLink(value: ShellPushDestination.brainRoute(.page(module, item.id))) {
                        BrainPeopleRow(item: item)
                    }
                    .brainListRow()
                    .onAppear { if item.id == lastID { loadMore() } }
                }
            } footer: {
                BrainListFooter(viewModel: viewModel)
            }
        }
        .brainListStyle()
        .refreshable { await viewModel.load() }
    }

    // MARK: Journal

    private func journalList(_ list: BrainList) -> some View {
        let sections = BrainListLayout.sections(list)
        let lastID = sections.last?.items.last?.id
        return List {
            ForEach(sections, id: \.title) { section in
                Section {
                    if !section.title.isEmpty {
                        BrainMonthBanner(title: section.title, count: section.items.count)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(section.items, id: \.id) { item in
                        NavigationLink(value: ShellPushDestination.brainRoute(.page(module, item.id))) {
                            BrainRow(title: item.title.isEmpty ? item.date : item.title,
                                     subtitle: item.preview, subtitleLineLimit: 1)
                        }
                        .brainListRow()
                        .onAppear { if item.id == lastID { loadMore() } }
                    }
                }
            }
            Section {
                EmptyView()
            } footer: {
                BrainListFooter(viewModel: viewModel)
            }
        }
        .brainListStyle()
        .refreshable { await viewModel.load() }
    }

    // MARK: Wiki

    @ViewBuilder
    private func wikiSections(_ list: BrainList) -> some View {
        let sections = BrainListLayout.sections(list)
        let lastID = sections.last?.items.last?.id
        ForEach(sections, id: \.title) { section in
            if !section.title.isEmpty {
                BrainSectionHeader(title: section.title, count: section.items.count)
                    .padding(.horizontal, BrainStyle.l)
            }
            if BrainListLayout.isGridSection(section.title) {
                cardGrid(section.items, columns: 2, lastID: lastID)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(section.items, id: \.id) { item in
                        NavigationLink(value: ShellPushDestination.brainRoute(.page(module, item.id))) {
                            BrainCoverRow(item: item)
                                .padding(.horizontal, BrainStyle.l)
                                .background(Color.hxSurface)
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) {
                            if item.id != section.items.last?.id {
                                Divider().padding(.leading, BrainStyle.l)
                            }
                        }
                        .onAppear { if item.id == lastID { loadMore() } }
                    }
                }
            }
        }
        BrainListFooter(viewModel: viewModel)
    }

    // MARK: Articles

    @ViewBuilder
    private func articleGrid(_ list: BrainList) -> some View {
        let items = BrainListLayout.uniqueItems(list.items)
        cardGrid(items, columns: 2, lastID: items.last?.id)
        BrainListFooter(viewModel: viewModel)
    }

    private func cardGrid(_ items: [BrainItem], columns: Int, lastID: String?) -> some View {
        LazyVGrid(columns: BrainListLayout.columns(columns, dynamicType: dynamicTypeSize), spacing: BrainStyle.m) {
            ForEach(items, id: \.id) { item in
                NavigationLink(value: ShellPushDestination.brainRoute(.page(module, item.id))) {
                    BrainCard(item: item)
                }
                .buttonStyle(.plain)
                .onAppear { if item.id == lastID { loadMore() } }
            }
        }
        .padding(.horizontal, BrainStyle.l)
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
        case .loaded(let list):
            if list.items.isEmpty {
                ContentUnavailableView {
                    Label { Text(verbatim: emptyTitle) } icon: { Image(systemName: viewModel.module.symbolName) }
                } description: {
                    Text(verbatim: emptyDescription)
                }
            } else {
                loaded(list)
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

/// Below a list: a spinner while the next page loads, and the offline note when the
/// list is a saved copy.
struct BrainListFooter: View {
    let viewModel: BrainListViewModel

    var body: some View {
        VStack(spacing: BrainStyle.s) {
            if viewModel.isLoadingMore {
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

/// A journal month's header: the month title and count over a 64pt cover banner
/// seeded by the title.
struct BrainMonthBanner: View {
    static let height: CGFloat = 64

    let title: String
    let count: Int
    private let cover: BrainCoverSpec

    init(title: String, count: Int) {
        self.title = title
        self.count = count
        self.cover = BrainCoverSpec.make(id: title, tag: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: title, count: count)
            BrainCoverView(spec: cover)
                .frame(height: Self.height)
                .frame(maxWidth: .infinity)
                .clipShape(BrainStyle.cardShape())
                .drawingGroup()
        }
        .padding(.top, BrainStyle.s)
    }
}
