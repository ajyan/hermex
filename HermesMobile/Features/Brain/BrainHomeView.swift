import SwiftData
import SwiftUI

/// The Brain's front door: a search field over a directory of the five modules.
/// Pushed onto the shell's navigation stack, so it must not own a `NavigationStack`;
/// every Brain screen is pushed as `ShellPushDestination.brainRoute(_:)`.
/// Copy is English-only (personal fork).
struct BrainHomeView: View {
    @State private var viewModel: BrainHomeViewModel
    @State private var searchViewModel: BrainSearchViewModel
    /// Prep's summary for its row; the row shows only once it loads.
    @State private var prepViewModel: PrepHomeViewModel
    /// Goals' summary for its row; the row shows only once it loads.
    @State private var goalsViewModel: GoalsHomeViewModel
    /// Programmatic pushes (graph nodes, `brain://` links) for the screens below.
    private let push: (BrainRoute) -> Void

    init(
        server: URL,
        modelContext: ModelContext,
        onAPIError: @escaping (Error) -> Void,
        push: @escaping (BrainRoute) -> Void
    ) {
        let client = APIClientBrainAdapter(apiClient: APIClient(baseURL: server))
        let cache = BrainCacheHandle(server: server, context: modelContext)
        _viewModel = State(initialValue: BrainHomeViewModel(client: client, cache: cache, onAPIError: onAPIError))
        _searchViewModel = State(initialValue: BrainSearchViewModel(client: client, onAPIError: onAPIError))
        _prepViewModel = State(initialValue: PrepHomeViewModel(
            client: APIClientPrepAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
        _goalsViewModel = State(initialValue: GoalsHomeViewModel(
            client: APIClientGoalsAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
        self.push = push
    }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: "Brain"))
            .background(Color.hxCanvas.ignoresSafeArea())
            .task {
                // Every appear refreshes quietly: shown modules stay until the response lands.
                searchViewModel.resume()
                await viewModel.load()
            }
            // Alongside the modules; a server without Prep just never shows the row.
            .task { await prepViewModel.load() }
            .task { await goalsViewModel.load() }
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
                    prompt: Text(verbatim: "People, topics, anything")
                )
                .autocorrectionDisabled()
        }
    }

    @ViewBuilder
    private var searchableBody: some View {
        if BrainSearchResults.isActive(searchViewModel.query) {
            List {
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
                moduleList
            }
        }
    }

    private var moduleTitles: [BrainModuleID: String] {
        Dictionary(
            viewModel.modules.filter { !$0.title.isEmpty }.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var isShowingExtraRows: Bool {
        if case .loaded = prepViewModel.state { return true }
        if case .loaded = goalsViewModel.state { return true }
        return false
    }

    private var moduleList: some View {
        List {
            Section {
                ForEach(viewModel.modules, id: \.id) { module in
                    NavigationLink(value: ShellPushDestination.brainRoute(.module(module.id))) {
                        BrainRow(
                            leading: { BrainModuleIcon(module: module.id) },
                            title: module.title.isEmpty ? module.id.defaultTitle : module.title,
                            subtitle: module.subtitle,
                            trailing: "\(module.count)"
                        )
                    }
                    .brainListRow()
                }
                if case .loaded(let goals) = goalsViewModel.state {
                    NavigationLink(value: ShellPushDestination.brainRoute(.goals(.home))) {
                        BrainRow(
                            leading: { BrainModuleIcon(systemName: "flag.checkered") },
                            title: "Goals",
                            subtitle: GoalsCopy.brainRowSubtitle(goals)
                        )
                    }
                    .brainListRow()
                }
                if case .loaded(let home) = prepViewModel.state {
                    NavigationLink(value: ShellPushDestination.brainRoute(.prep(.home))) {
                        BrainRow(
                            leading: { BrainModuleIcon(systemName: "target") },
                            title: "Interview prep",
                            subtitle: PrepCopy.homeRowSubtitle(
                                streakDays: home.streak.days, remaining: home.run.remaining)
                        )
                    }
                    .brainListRow()
                }
            } footer: {
                if viewModel.isShowingCachedCopy {
                    Text(verbatim: "Offline, showing saved copy")
                        .brainText(.meta)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, BrainStyle.s)
                }
            }
        }
        .brainListStyle()
        .overlay {
            if viewModel.modules.isEmpty, !isShowingExtraRows {
                ContentUnavailableView {
                    Label { Text(verbatim: "Nothing in the Brain yet") } icon: { Image(systemName: "brain") }
                } description: {
                    Text(verbatim: "Modules appear here once the server has notes to show.")
                }
            }
        }
        .refreshable {
            async let prep: Void = prepViewModel.load()
            async let goals: Void = goalsViewModel.load()
            await viewModel.load()
            await prep
            await goals
        }
    }
}
