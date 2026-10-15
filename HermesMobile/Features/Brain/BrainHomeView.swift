import SwiftData
import SwiftUI

/// The Brain's front door: a search field, the modules as a chip strip, then today's review
/// deck of ten bites from saved reading.
/// Pushed onto the shell's navigation stack, so it must not own a `NavigationStack`;
/// every Brain screen is pushed as `ShellPushDestination.brainRoute(_:)`.
/// Copy is English-only (personal fork).
struct BrainHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: BrainHomeViewModel
    @State private var searchViewModel: BrainSearchViewModel
    /// Prep's summary; its chip shows only once it loads.
    @State private var prepViewModel: PrepHomeViewModel
    /// Where the deck starts in the home's content: the strip and header above it.
    @State private var deckTop: CGFloat = 0
    /// Programmatic pushes (graph nodes, `brain://` links, review bites) for the screens below.
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
        self.push = push
    }

    var body: some View {
        content
            .hxNavigationTitle("Brain")
            .background(Color.hxCanvas.ignoresSafeArea())
            .task {
                // Every appear refreshes quietly: shown modules stay until the response lands.
                searchViewModel.resume()
                await viewModel.load()
            }
            // Alongside the modules; a server without Prep just never shows the chip.
            .task { await prepViewModel.load() }
            .onChange(of: scenePhase) { _, phase in
                // Left open overnight, the deck moves on to the new day's ten.
                if phase == .active, viewModel.needsNewDay { Task { await viewModel.load() } }
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

    private var isShowingPrepChip: Bool {
        if case .loaded = prepViewModel.state { return true }
        return false
    }

    /// The modules as a chip strip, then today's review deck (DESIGN.md § Components).
    private var moduleList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.l) {
                BrainModuleStrip(modules: viewModel.modules, showsPrep: isShowingPrepChip)
                if !viewModel.reviewPages.isEmpty {
                    review.padding(.horizontal, 16)
                }
                if viewModel.isShowingCachedCopy {
                    Text(verbatim: "Offline, showing saved copy")
                        .brainText(.meta)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, BrainStyle.s)
                }
            }
            .padding(.vertical, BrainStyle.m)
            .coordinateSpace(.named(Self.contentSpace))
        }
        .overlay {
            if viewModel.modules.isEmpty, !isShowingPrepChip, viewModel.reviewPages.isEmpty {
                ContentUnavailableView {
                    Label { Text(verbatim: "Nothing in the Brain yet") } icon: { Image(systemName: "brain") }
                } description: {
                    Text(verbatim: "Modules appear here once the server has notes to show.")
                }
            }
        }
        .refreshable {
            async let prep: Void = prepViewModel.load()
            await viewModel.load()
            await prep
        }
    }

    /// "Review · 3 of 10" over the day's deck of bites, ending on the summary card.
    private var review: some View {
        let bites = viewModel.home.bites
        return VStack(alignment: .leading, spacing: BrainStyle.xs) {
            HXSectionHeader(title: "Review", trailing: "\(min(viewModel.reviewIndex + 1, bites.count)) of \(bites.count)")
                .padding(.horizontal, 4)
            CardStack(
                pages: viewModel.reviewPages,
                index: $viewModel.reviewIndex,
                tilt: { DeckStackView.tilt(ofID: $0.id) }
            ) { page, contentOpacity in
                switch page {
                case .bite(let bite):
                    BrainBiteCard(bite: bite, open: { open(bite) }, contentOpacity: contentOpacity)
                case .summary:
                    BrainReviewSummaryCard(bites: bites, hasMore: viewModel.home.hasMore,
                                           onMore: { await viewModel.dealMore() }, contentOpacity: contentOpacity)
                }
            } edge: { page in
                // Far down the stack only the card's paper shows, peeking out askew.
                let role = Self.cardRole(page)
                role.shape
                    .fill(role.fill)
                    .hxShadow(.stacked)
                    .padding(.vertical, 12)
            }
            // Fills the visible height below the strip and header when the home is scrolled to
            // the top, like the Daily Brief; a card scrolls inside past that.
            .containerRelativeFrame(.vertical) { length, _ in
                max(length - deckTop - BrainStyle.m, BrainStyle.minimumDeckHeight)
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(Self.contentSpace)).minY
            } action: { top in
                deckTop = top
            }
        }
    }

    private static let contentSpace = "brainHomeContent"

    private func open(_ bite: BrainBite) {
        push(route(bite))
    }

    private func route(_ bite: BrainBite) -> BrainRoute {
        .bite(bite.ref.module, bite.ref.id, idea: bite.kind == .idea ? bite.index : nil)
    }

    private static func cardRole(_ page: BrainReviewPage) -> HXCardRole {
        switch page {
        case .bite(let bite): .glow(bite.paper)
        case .summary: .summary
        }
    }
}
