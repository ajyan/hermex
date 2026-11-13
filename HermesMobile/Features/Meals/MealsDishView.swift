import SwiftUI

/// A dish's page, pushed from Meals or the recipe book: the dish card with servings to scale to,
/// Atlas's proposed fix from his last note, Goes with, the ingredients scaled, the steps, and his
/// notes. A dish with no recipe yet offers a link, writing it, or telling Atlas.
struct MealsDishView: View {
    @State private var viewModel: MealsDishViewModel
    @State private var editing = false
    @State private var linking = false
    @ScaledMetric(relativeTo: .subheadline) private var amountWidth: CGFloat = 76

    private let client: MealsRecipeClient
    private let onAPIError: (Error) -> Void
    private let onOpen: (ShellPushDestination) -> Void
    private let ask: (String) -> Void

    init(route: MealsDishRoute, server: URL, onAPIError: @escaping (Error) -> Void,
         onOpen: @escaping (ShellPushDestination) -> Void, ask: @escaping (String) -> Void) {
        let client = APIClientMealsScreenAdapter(apiClient: APIClient(baseURL: server))
        self.client = client
        self.onAPIError = onAPIError
        self.onOpen = onOpen
        self.ask = ask
        _viewModel = State(initialValue: MealsDishViewModel(route: route, client: client, onAPIError: onAPIError))
    }

    private var paper: HermexPaper { .meal }

    var body: some View {
        content
            .hxNavigationTitle("Recipe")
            .background(Color.hxCanvas.ignoresSafeArea())
            .toolbar {
                if case .loaded(let recipe) = viewModel.state {
                    ToolbarItem(placement: .topBarTrailing) { menu(recipe) }
                }
            }
            .task { await viewModel.load() }
            .sheet(isPresented: $editing) {
                if case .loaded(let recipe) = viewModel.state {
                    MealsRecipeEditor(recipe: recipe, viewModel: viewModel)
                }
            }
            .sheet(isPresented: $linking) {
                if case .loaded(let recipe) = viewModel.state {
                    MealsAddLinkSheet(
                        model: MealsLinkModel(fillsIn: MealsSeasonPick(slug: recipe.slug, name: recipe.name),
                                              side: recipe.isSide, client: client, onAPIError: onAPIError)
                    ) { saved in
                        linking = false
                        viewModel.linked(saved)
                    }
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
                Label { Text(verbatim: "No recipe here") } icon: { Image(systemName: "fork.knife") }
            } description: {
                Text(verbatim: "This server doesn't have that dish, or doesn't serve Recipes.")
            }
        case .failed(let message):
            HXFailedView(title: "Couldn't load the recipe", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let recipe):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.l) {
                    if let error = viewModel.saveError {
                        Text(verbatim: error)
                            .font(AppFont.footnote())
                            .foregroundStyle(Color.hxDanger)
                    }
                    dishCard(recipe)
                    if let fix = recipe.fix, !fix.changes.isEmpty { fixCard(fix) }
                    if !recipe.goesWith.isEmpty { goesWith(recipe) }
                    if !recipe.ingredients.isEmpty { ingredients(recipe) }
                    if recipe.steps.isEmpty {
                        noRecipe(recipe)
                    } else {
                        steps(recipe)
                        footer(recipe)
                    }
                    if !recipe.notes.isEmpty { notes(recipe) }
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
            .disabled(viewModel.isSaving)
        }
    }

    // MARK: The dish

    private func dishCard(_ recipe: MealsRecipe) -> some View {
        HXCard(.glow(paper), title: recipe.name, titleStyle: .title2, spacing: 8) {
            Text(verbatim: [recipe.isSide ? "Side" : "Main", recipe.isWant ? "Want to try" : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(paper.glow)
        } content: {
            Text(verbatim: MealsCopy.madeLine(recipe))
                .font(AppFont.footnote())
                .foregroundStyle(paper.secondaryInk)
            if !recipe.ingredients.isEmpty { servings(recipe) }
        } footer: {
            EmptyView()
        }
    }

    private func servings(_ recipe: MealsRecipe) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Serves \(viewModel.servings)")
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .contentTransition(.numericText())
                Text(verbatim: MealsScale.caption(servings: viewModel.servings, serves: recipe.serves,
                                                  day: viewModel.route.day))
                    .font(AppFont.caption())
                    .foregroundStyle(paper.secondaryInk)
            }
            Spacer(minLength: 8)
            stepButton("minus", label: "Fewer servings", disabled: viewModel.servings <= 1) {
                viewModel.setServings(viewModel.servings - 1)
            }
            stepButton("plus", label: "More servings", disabled: viewModel.servings >= 48) {
                viewModel.setServings(viewModel.servings + 1)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glowSurface(paper, cornerRadius: HXRadius.md)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
    }

    private func stepButton(_ symbol: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(paper.glow)
                .frame(width: 44, height: 44)
                .background(paper.wash, in: Capsule())
                .overlay(Capsule().strokeBorder(paper.edge, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(Text(verbatim: label))
    }

    // MARK: Atlas's fix

    private func fixCard(_ fix: MealsFix) -> some View {
        let atlas = HermexPaper.request
        return HXCard(.wash(atlas), spacing: 8) {
            Text(verbatim: "Atlas suggests a change")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(atlas.glow)
        } content: {
            Text(verbatim: fix.day.map { "From your note on \(MealsCopy.monthDay($0)):" } ?? "From your note:")
                .font(AppFont.footnote())
                .foregroundStyle(atlas.secondaryInk)
            Text(verbatim: "\u{201C}\(fix.note)\u{201D}")
                .font(AppFont.serif())
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(fix.changes.enumerated()), id: \.offset) { _, change in
                    fixChange(change, paper: atlas)
                }
            }
            .padding(.top, 8)
            .overlay(alignment: .top) { Rectangle().fill(atlas.edge).frame(height: 0.5) }
        } footer: {
            HStack(spacing: 8) {
                Button { Task { await viewModel.answerFix(use: true) } } label: {
                    Text(verbatim: "Use this")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(atlas.onGlow)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(atlas.glow, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(verbatim: "Changes the recipe"))
                Button { Task { await viewModel.answerFix(use: false) } } label: {
                    Text(verbatim: "Keep as is")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(atlas.glow)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(atlas.wash, in: Capsule())
                        .overlay(Capsule().strokeBorder(atlas.edge, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func fixChange(_ change: MealsFixChange, paper: HermexPaper) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !change.was.isEmpty {
                Text(verbatim: (change.now.isEmpty ? "Remove: " : "Was: ") + change.was)
                    .font(AppFont.subheadline())
                    .foregroundStyle(paper.secondaryInk)
            }
            if !change.now.isEmpty {
                Text(verbatim: (change.was.isEmpty ? "Add: " : "Now: ") + change.now)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    // MARK: Goes with, ingredients, steps

    private func goesWith(_ recipe: MealsRecipe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Goes with")
            FlowRow(spacing: 8) {
                ForEach(recipe.goesWith) { pairing in
                    Button { onOpen(.mealsDish(MealsDishRoute(slug: pairing.slug))) } label: {
                        HXChip(paper: paper, label: "\(pairing.name) · \(pairing.count)×")
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "\(pairing.name), eaten together \(pairing.count) times"))
                }
            }
        }
    }

    private func ingredients(_ recipe: MealsRecipe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Ingredients", trailing: "for \(viewModel.servings)")
            VStack(spacing: 0) {
                ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { index, ingredient in
                    if index > 0 { Divider().padding(.leading, 16) }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: MealsScale.amount(ingredient, factor: viewModel.factor) ?? "")
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                            .frame(width: amountWidth, alignment: .leading)
                        Text(verbatim: ingredient.item)
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
            }
            .hxCard()
        }
    }

    private func steps(_ recipe: MealsRecipe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Steps")
            VStack(spacing: 0) {
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                    if index > 0 { Divider().padding(.leading, 16) }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: "\(index + 1)")
                            .font(AppFont.display(style: .subheadline, weight: .semibold))
                            .foregroundStyle(paper.glow)
                            .monospacedDigit()
                        Text(verbatim: step)
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .accessibilityElement(children: .combine)
                }
            }
            .hxCard()
        }
    }

    @ViewBuilder
    private func footer(_ recipe: MealsRecipe) -> some View {
        if let line = MealsCopy.recipeFooter(recipe) {
            if recipe.fixes.isEmpty, let link = recipe.source.flatMap(URL.init(string:)) {
                Link(destination: link) {
                    Text(verbatim: line).font(AppFont.caption())
                }
                .padding(.horizontal, 4)
            } else {
                Text(verbatim: line)
                    .font(AppFont.caption())
                    .foregroundStyle(Color.hxTextSecondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func noRecipe(_ recipe: MealsRecipe) -> some View {
        HXCard(.neutral, title: recipe.ingredients.isEmpty ? "No recipe yet" : "No steps yet", spacing: 10) {
            Text(verbatim: "Recipes come in as you cook: save the link you cook from, write it down, or tell Atlas how you make it.")
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                actionRow("link", "Add from a link") { linking = true }
                actionRow("square.and.pencil", "Write it") { editing = true }
                actionRow("bubble.left", "Tell Atlas how you make it") { ask(MealsCopy.howIMake(recipe)) }
            }
        }
    }

    private func actionRow(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(verbatim: title) } icon: { Image(systemName: symbol) }
                .font(AppFont.subheadline(weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    private func notes(_ recipe: MealsRecipe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Your notes")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(recipe.notes.reversed().enumerated()), id: \.offset) { index, note in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 2) {
                        if let day = note.day {
                            Text(verbatim: MealsCopy.monthDay(day))
                                .font(AppFont.caption())
                                .foregroundStyle(Color.hxTextSecondary)
                        }
                        Text(verbatim: note.text)
                            .font(AppFont.serif(style: .subheadline))
                            .foregroundStyle(Color.hxTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 16)
            .hxCard()
        }
    }

    // MARK: Menu

    private func menu(_ recipe: MealsRecipe) -> some View {
        Menu {
            Button { editing = true } label: {
                Label { Text(verbatim: recipe.hasRecipe ? "Edit recipe" : "Write it") } icon: {
                    Image(systemName: "square.and.pencil")
                }
            }
            Button { linking = true } label: {
                Label { Text(verbatim: recipe.hasRecipe ? "Replace from a link" : "Add from a link") } icon: {
                    Image(systemName: "link")
                }
            }
            Button { ask(MealsCopy.howIMake(recipe)) } label: {
                Label { Text(verbatim: "Tell Atlas how you make it") } icon: { Image(systemName: "bubble.left") }
            }
            if let link = recipe.source.flatMap(URL.init(string:)) {
                Link(destination: link) {
                    Label { Text(verbatim: "Open the original") } icon: { Image(systemName: "safari") }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .accessibilityLabel(Text(verbatim: "More"))
        }
    }
}

extension MealsCopy {
    /// The chat draft for telling Atlas how he makes a dish; he finishes the sentence.
    static func howIMake(_ recipe: MealsRecipe) -> String {
        "Here's how I make \(recipe.name) (save it as its recipe): "
    }
}
