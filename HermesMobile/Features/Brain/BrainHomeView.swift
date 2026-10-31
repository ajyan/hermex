import SwiftData
import SwiftUI

/// The Brain home's pure decisions, kept out of the view so they can be tested.
enum BrainHomeLayout {
    /// Browse's order. Modules the server adds later follow in its order.
    static let order: [BrainModuleID] = [.people, .wiki, .articles, .highlights, .journal, .letters]

    static func ordered(_ modules: [BrainModule]) -> [BrainModule] {
        modules.enumerated().sorted { lhs, rhs in
            let l = order.firstIndex(of: lhs.element.id) ?? order.count
            let r = order.firstIndex(of: rhs.element.id) ?? order.count
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }

    /// The review row's trailing progress: nothing before the first swipe, "4 of 10" partway,
    /// "Done" on the summary card.
    static func reviewProgress(index: Int, bites: Int) -> String? {
        guard bites > 0, index > 0 else { return nil }
        return index >= bites ? "Done" : "\(index + 1) of \(bites)"
    }

    /// The People home's due catch-ups, for Today.
    static func dueCatchUps(_ sections: [BrainPeopleLayout.Section], limit: Int = 2) -> [BrainPeopleLayout.Row] {
        Array(sections.flatMap(\.rows).filter(\.isDue).prefix(limit))
    }

    /// What "Ask Atlas" puts in the new chat's composer: the typed words, trimmed.
    static func askDraft(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A question the home suggests asking Atlas, in the paper of the module it draws on.
struct BrainAskSuggestion: Identifiable {
    let module: BrainModuleID
    let question: String
    var id: String { question }

    static let all: [BrainAskSuggestion] = [
        BrainAskSuggestion(module: .people, question: "Who should I catch up with?"),
        BrainAskSuggestion(module: .articles, question: "What did I save this week?"),
        BrainAskSuggestion(module: .journal, question: "What was on my mind a year ago?"),
        BrainAskSuggestion(module: .highlights, question: "Pick a highlight for today"),
        BrainAskSuggestion(module: .wiki, question: "What did I learn this month?"),
    ]
}

/// The Brain's front door: one field that finds pages and asks Atlas, suggested questions, a
/// Today list (the review, due catch-ups) and every module to browse (DESIGN.md § Components).
/// Pushed onto the shell's navigation stack, so it must not own a `NavigationStack`;
/// every Brain screen is pushed as `ShellPushDestination.brainRoute(_:)`.
/// Copy is English-only (personal fork).
struct BrainHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: BrainHomeViewModel
    @State private var searchViewModel: BrainSearchViewModel
    /// Due catch-ups for Today.
    @State private var peopleHome: BrainPeopleHomeViewModel
    /// Prep's summary; its Browse row shows only once it loads.
    @State private var prepViewModel: PrepHomeViewModel
    /// Today's Daily Ask (the shell's): while it locks Prep, Prep's row says so.
    @Environment(DailyAskModel.self) private var dailyAsk: DailyAskModel?
    /// Starts a new chat with Atlas, the question in its composer.
    private let ask: (String) -> Void

    init(
        server: URL,
        modelContext: ModelContext,
        onAPIError: @escaping (Error) -> Void,
        ask: @escaping (String) -> Void
    ) {
        let client = APIClientBrainAdapter(apiClient: APIClient(baseURL: server))
        let cache = BrainCacheHandle(server: server, context: modelContext)
        _viewModel = State(initialValue: BrainHomeViewModel(client: client, cache: cache, onAPIError: onAPIError))
        _searchViewModel = State(initialValue: BrainSearchViewModel(client: client, onAPIError: onAPIError))
        _peopleHome = State(initialValue: BrainPeopleHomeViewModel(client: client, cache: cache))
        _prepViewModel = State(initialValue: PrepHomeViewModel(
            client: APIClientPrepAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
        self.ask = ask
    }

    var body: some View {
        content
            .hxNavigationTitle("Brain")
            .background(Color.hxCanvas.ignoresSafeArea())
            .task {
                // Every appear refreshes quietly: shown rows stay until the response lands, and
                // the review row catches up with swipes made on the Review screen.
                searchViewModel.resume()
                await viewModel.load()
            }
            // Alongside the modules; a server without Prep or People just never shows those rows.
            .task { await prepViewModel.load() }
            .task { await dailyAsk?.load() }
            .task { await peopleHome.load() }
            .onChange(of: scenePhase) { _, phase in
                // Left open overnight, the review row moves on to the new day's ten.
                if phase == .active, viewModel.needsNewDay { Task { await viewModel.load() } }
                if phase == .active { Task { await dailyAsk?.load() } }  // a new day's Ask, or one acted on elsewhere
                if phase == .active { Task { await peopleHome.load() } }  // who is due moves on with the day
            }
            .onDisappear { searchViewModel.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.state == .unavailable {
            ContentUnavailableView {
                Label { Text(verbatim: "No Brain on this server") } icon: { Image(systemName: "brain") }
            } description: {
                Text(verbatim: "This server doesn't serve the Second Brain. It needs the Brain API from your hermes-webui fork.")
            }
        } else {
            searchableBody
                .searchable(
                    text: $searchViewModel.query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(verbatim: "Ask or find anything")
                )
                .autocorrectionDisabled()
        }
    }

    @ViewBuilder
    private var searchableBody: some View {
        if BrainSearchResults.isActive(searchViewModel.query) {
            List {
                Section {
                    BrainAskRow(question: BrainHomeLayout.askDraft(searchViewModel.query)) {
                        ask(BrainHomeLayout.askDraft(searchViewModel.query))
                    }
                    .brainListRow()
                }
                BrainSearchResults(
                    query: searchViewModel.query,
                    result: searchViewModel.result,
                    isSearching: searchViewModel.isSearching,
                    didFail: searchViewModel.didFail,
                    moduleTitles: moduleTitles,
                    showsSeeAll: true
                )
            }
            .brainListStyle()
        } else {
            switch viewModel.state {
            case .loading, .unavailable:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label { Text(verbatim: "Couldn't load the Brain") } icon: { Image(systemName: "exclamationmark.triangle") }
                } description: {
                    Text(verbatim: message)
                } actions: {
                    Button { Task { await viewModel.load() } } label: { Text(verbatim: "Try again") }
                }
            case .loaded:
                home
            }
        }
    }

    private var moduleTitles: [BrainModuleID: String] {
        Dictionary(
            viewModel.modules.filter { !$0.title.isEmpty }.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var isShowingPrep: Bool {
        if case .loaded = prepViewModel.state { return true }
        return false
    }

    private var dueCatchUps: [BrainPeopleLayout.Row] {
        BrainHomeLayout.dueCatchUps(peopleHome.sections)
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.l) {
                suggestions
                if !viewModel.home.bites.isEmpty || !dueCatchUps.isEmpty {
                    today
                }
                if !viewModel.modules.isEmpty || isShowingPrep {
                    browse
                }
                if viewModel.isShowingCachedCopy {
                    Text(verbatim: "Offline, showing saved copy")
                        .brainText(.meta)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, BrainStyle.s)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, BrainStyle.m)
        }
        .refreshable {
            async let prep: Void = prepViewModel.load()
            async let people: Void = peopleHome.load()
            await viewModel.load()
            await prep
            await people
        }
    }

    /// "Try" over the suggested questions; each starts a chat with Atlas.
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            HXSectionHeader(title: "Ask Atlas")
                .padding(.horizontal, 4)
            // One row that slides sideways, running to the screen's edges.
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(BrainAskSuggestion.all) { suggestion in
                        Button { ask(suggestion.question) } label: {
                            HXChip(paper: suggestion.module.paper, symbol: suggestion.module.symbolName,
                                   label: suggestion.question)
                                .frame(minHeight: BrainStyle.minTapTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text(verbatim: "Starts a chat with Atlas"))
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -16)
        }
    }

    /// Today's review and anyone due for a catch-up.
    private var today: some View {
        let bites = viewModel.home.bites.count
        return VStack(alignment: .leading, spacing: BrainStyle.s) {
            HXSectionHeader(title: "Today")
                .padding(.horizontal, 4)
            BrainHomeCard {
                if bites > 0 {
                    link(.review) {
                        BrainRow(
                            leading: { BrainModuleIcon(systemName: "rectangle.stack",
                                                       paper: viewModel.home.bites.first?.paper ?? .reading) },
                            title: "Review",
                            subtitle: "\(bites) bites from what you've saved",
                            trailing: BrainHomeLayout.reviewProgress(index: viewModel.reviewIndex, bites: bites),
                            subtitleLineLimit: 1
                        )
                    }
                }
                ForEach(dueCatchUps) { row in
                    if bites > 0 || row.id != dueCatchUps.first?.id { BrainHomeDivider() }
                    link(.page(.people, row.id)) { BrainPeopleSectionRow(row: row) }
                }
            }
        }
    }

    /// Every module, then Interview prep.
    private var browse: some View {
        let modules = BrainHomeLayout.ordered(viewModel.modules)
        return VStack(alignment: .leading, spacing: BrainStyle.s) {
            HXSectionHeader(title: "Browse")
                .padding(.horizontal, 4)
            BrainHomeCard {
                ForEach(modules, id: \.id) { module in
                    if module.id != modules.first?.id { BrainHomeDivider() }
                    link(.module(module.id)) {
                        BrainRow(
                            leading: { BrainModuleIcon(systemName: module.id.symbolName, paper: module.id.paper) },
                            title: module.title.isEmpty ? module.id.defaultTitle : module.title,
                            subtitle: module.subtitle,
                            trailing: module.count > 0 ? "\(module.count)" : nil,
                            subtitleLineLimit: 1
                        )
                    }
                }
                if isShowingPrep {
                    if !modules.isEmpty { BrainHomeDivider() }
                    link(.prep(.home)) {
                        BrainRow(
                            leading: { BrainModuleIcon(systemName: dailyAsk?.isLocked == true ? "lock.fill" : "target", paper: .knowledge) },
                            title: "Interview prep",
                            subtitle: dailyAsk?.isLocked == true ? "After today's Ask" : "Today's run and your tracks",
                            subtitleLineLimit: 1
                        )
                    }
                }
            }
        }
    }

    private func link<Label: View>(_ route: BrainRoute, @ViewBuilder label: () -> Label) -> some View {
        NavigationLink(value: ShellPushDestination.brainRoute(route)) {
            label()
                .padding(.horizontal, BrainStyle.cardHorizontalPadding)
                .zoomSource(for: .brainRoute(route), cornerRadius: HXRadius.sm)
        }
        .buttonStyle(.plain)
    }
}

/// The Brain home's rows on one neutral card, with hairlines between them.
private struct BrainHomeCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.vertical, BrainStyle.xs)
            .hxCard()
    }
}

/// The hairline between two rows on a `BrainHomeCard`.
private struct BrainHomeDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.hxSeparator)
            .frame(height: 0.5)
            .padding(.leading, BrainStyle.cardHorizontalPadding)
    }
}

/// The first search row: hands the typed words to Atlas in a new chat.
struct BrainAskRow: View {
    let question: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BrainRow(
                leading: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(BrainStyle.rowSubtitle.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: BrainStyle.iconSize, height: BrainStyle.iconSize)
                        .accessibilityHidden(true)
                },
                title: "Ask Atlas \u{201C}\(question)\u{201D}",
                subtitle: "Starts a chat that answers from your Brain",
                subtitleLineLimit: 1,
                titleLineLimit: 2
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(verbatim: "Starts a chat with Atlas"))
    }
}
