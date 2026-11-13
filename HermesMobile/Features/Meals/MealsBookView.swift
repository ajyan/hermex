import SwiftUI

/// The recipe book, pushed from Meals: search, filter chips, this season's card (most made, go-to
/// side, new this season), then Good right now, Want to try, and every recipe A to Z. A search or
/// a filter shows one list. The plus adds a recipe from a link.
struct MealsBookView: View {
    @State private var viewModel: MealsBookViewModel
    @State private var adding = false

    private let client: MealsRecipeClient
    private let onAPIError: (Error) -> Void
    private let onOpen: (ShellPushDestination) -> Void

    init(server: URL, onAPIError: @escaping (Error) -> Void, onOpen: @escaping (ShellPushDestination) -> Void) {
        let client = APIClientMealsScreenAdapter(apiClient: APIClient(baseURL: server))
        self.client = client
        self.onAPIError = onAPIError
        self.onOpen = onOpen
        _viewModel = State(initialValue: MealsBookViewModel(client: client, onAPIError: onAPIError))
    }

    private var paper: HermexPaper { .meal }

    var body: some View {
        content
            .hxNavigationTitle("Recipes", subtitle: subtitle)
            .background(Color.hxCanvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: {
                        Image(systemName: "plus").accessibilityLabel(Text(verbatim: "Add a recipe"))
                    }
                }
            }
            // Every appear refreshes, so a dish made or edited shows on the way back.
            .task { await viewModel.load() }
            .sheet(isPresented: $adding) {
                MealsAddLinkSheet(model: MealsLinkModel(client: client, onAPIError: onAPIError)) { saved in
                    adding = false
                    Task { await viewModel.load() }
                    onOpen(.mealsDish(MealsDishRoute(slug: saved.slug)))
                }
            }
    }

    private var subtitle: String? {
        guard case .loaded(let book) = viewModel.state else { return nil }
        return book.dishes.count == 1 ? "1 dish" : "\(book.dishes.count) dishes"
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label { Text(verbatim: "No Recipes on this server") } icon: { Image(systemName: "book.closed") }
            } description: {
                Text(verbatim: "This server doesn't serve Recipes. It needs the Meals API from your hermes-webui fork.")
            }
        case .failed(let message):
            HXFailedView(title: "Couldn't load Recipes", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let book):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.l) {
                    searchField
                    filters
                    if viewModel.isBrowsing {
                        browse(book)
                    } else {
                        results(book)
                    }
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await viewModel.load() }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.hxTextSecondary)
                .accessibilityHidden(true)
            TextField(text: $viewModel.query) { Text(verbatim: "Search recipes") }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !viewModel.query.isEmpty {
                Button { viewModel.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.hxTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "Clear search"))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MealsBookViewModel.Filter.allCases) { filter in
                    Button { viewModel.filter = filter } label: {
                        BrainTagChip(tag: filter.rawValue, selected: viewModel.filter == filter)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollClipDisabled()
    }

    // MARK: Browsing

    @ViewBuilder
    private func browse(_ book: MealsBook) -> some View {
        seasonCard(book.season)
        let inSeason = MealsBookViewModel.inSeason(book)
        if !inSeason.isEmpty {
            section("Good right now", trailing: book.season.seasonWord.capitalized, dishes: Array(inSeason.prefix(6)))
        }
        let want = MealsBookViewModel.wantToTry(book)
        if !want.isEmpty {
            section("Want to try", trailing: "Saved, not cooked yet", dishes: want)
        }
        section("All recipes", trailing: nil, dishes: book.dishes.filter { !$0.isWant })
    }

    @ViewBuilder
    private func seasonCard(_ season: MealsSeason) -> some View {
        if !season.name.isEmpty {
            HXCard(.glow(paper), title: season.name, titleStyle: .title2, spacing: 8) {
                Text(verbatim: "Your season")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(paper.glow)
            } content: {
                VStack(alignment: .leading, spacing: 0) {
                    if let most = season.mostMade { seasonRow("Most made", pick: most) }
                    if let side = season.goToSide { seasonRow("Go-to side", pick: side) }
                    if !season.new.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: "New this \(season.seasonWord)")
                                .font(AppFont.caption())
                                .foregroundStyle(paper.secondaryInk)
                            FlowRow(spacing: 8) {
                                ForEach(season.new) { pick in
                                    Button { open(pick.slug) } label: {
                                        HXChip(paper: paper, label: pick.name)
                                            .frame(minHeight: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .top) { Rectangle().fill(paper.edge).frame(height: 0.5) }
                    }
                }
            } footer: {
                Button { if case .loaded(let book) = viewModel.state { onOpen(.mealsSeason(book.day)) } } label: {
                    Text(verbatim: "Open the season")
                        .font(AppFont.subheadline(weight: .semibold))
                        .frame(minHeight: 44)
                }
            }
        }
    }

    private func seasonRow(_ label: String, pick: MealsSeasonPick) -> some View {
        Button { open(pick.slug) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: label)
                    .font(AppFont.caption())
                    .foregroundStyle(paper.secondaryInk)
                Text(verbatim: pick.count.map { "\(pick.name) · \($0)×" } ?? pick.name)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(paper.edge).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
    }

    // MARK: Lists

    @ViewBuilder
    private func results(_ book: MealsBook) -> some View {
        let dishes = viewModel.matches(in: book)
        if dishes.isEmpty {
            Text(verbatim: viewModel.filter == .occasions && viewModel.query.isEmpty
                 ? "No recipes for occasions yet. Mark one when you save or edit it."
                 : "No recipes match.")
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
                .padding(.horizontal, 4)
        } else {
            rows(dishes)
        }
    }

    private func section(_ title: String, trailing: String?, dishes: [MealsBookDish]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: title, trailing: trailing)
            rows(dishes)
        }
    }

    private func rows(_ dishes: [MealsBookDish]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(dishes.enumerated()), id: \.element.id) { index, dish in
                if index > 0 { Divider().padding(.leading, 60) }
                Button { open(dish.slug) } label: {
                    BrainRow(
                        leading: {
                            BrainModuleIcon(systemName: dish.isSide ? "leaf" : "fork.knife",
                                            paper: dish.isWant ? nil : paper)
                        },
                        title: dish.name,
                        subtitle: MealsCopy.bookLine(dish)
                    )
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
            }
        }
        .hxCard()
    }

    private func open(_ slug: String) {
        onOpen(.mealsDish(MealsDishRoute(slug: slug)))
    }
}
