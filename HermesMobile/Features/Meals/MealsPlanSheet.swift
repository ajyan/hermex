import SwiftUI

/// The weekend planner, a sheet over Meals: 1 How was this week?, 2 What's left?, 3 Fill the
/// nights, 4 Groceries. Each step saves before the next opens; Back returns to the step before.
/// A waiting recipe fix opens the dish's page inside the sheet.
struct MealsPlanSheet: View {
    @State private var model: MealsPlanModel
    @State private var path: [MealsPlanModel.Step] = []
    @Environment(\.dismiss) private var dismiss

    private let server: URL
    private let onAPIError: (Error) -> Void
    private let ask: (String) -> Void
    private let title: String

    init(server: URL, onAPIError: @escaping (Error) -> Void, ask: @escaping (String) -> Void) {
        self.server = server
        self.onAPIError = onAPIError
        self.ask = ask
        title = MealsCopy.planTitle(Date())
        let client = APIClientMealsScreenAdapter(apiClient: APIClient(baseURL: server))
        _model = State(initialValue: MealsPlanModel(client: client, onAPIError: onAPIError))
    }

    var body: some View {
        NavigationStack(path: $path) {
            MealsPlanReviewStep(model: model, title: title, onNext: { path.append(.left) },
                                onOpen: { path.append(.dish($0)) })
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").accessibilityLabel(Text(verbatim: "Close"))
                        }
                    }
                }
                .navigationDestination(for: MealsPlanModel.Step.self) { step in
                    switch step {
                    case .left:
                        MealsPlanLeftStep(model: model, title: title) { path.append(.fill) }
                    case .fill:
                        MealsPlanFillStep(model: model, title: title,
                                          onOpen: { path.append(.dish($0)) }) { path.append(.groceries) }
                    case .groceries:
                        MealsPlanGroceriesStep(model: model, title: title) { dismiss() }
                    case .dish(let route):
                        MealsDishView(route: route, server: server, onAPIError: onAPIError,
                                      onOpen: { if case .mealsDish(let next) = $0 { path.append(.dish(next)) } },
                                      ask: { dismiss(); ask($0) })
                            .id(route)
                    }
                }
        }
        .interactiveDismissDisabled(model.isSaving)
    }
}

// MARK: - Shared pieces

private enum PlanStyle {
    static var paper: HermexPaper { .meal }
}

/// A step's heading: the question in the display voice and a line under it.
private struct PlanHeading: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(AppFont.display(style: .title2, weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(verbatim: detail)
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The full-width button pinned at a step's foot.
private struct PlanNextButton: View {
    let title: String
    var busy = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy { ProgressView().tint(Color.hxOnAccent) } else { Text(verbatim: title) }
            }
            .font(AppFont.headline(weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(busy || disabled)
        .padding(.horizontal, BrainStyle.l)
        .padding(.bottom, 8)
    }
}

/// A selectable capsule (Nous blue when on, since it's a control).
private struct PlanChoice: View {
    let title: String
    var symbol: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BrainTagChip(tag: symbol.map { "\($0) \(title)" } ?? title, selected: selected)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PlanError: View {
    let message: String?

    var body: some View {
        if let message {
            Text(verbatim: message)
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxDanger)
        }
    }
}

/// Loading, unavailable and failed states shared by the steps.
private struct PlanLoadState<Value: Equatable, Content: View>: View {
    let state: BrainLoadState<Value>
    let retry: () async -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        case .unavailable:
            ContentUnavailableView {
                Label { Text(verbatim: "No planner on this server") } icon: { Image(systemName: "calendar") }
            } description: {
                Text(verbatim: "This server doesn't serve the weekend planner. It needs the Meals API from your hermes-webui fork.")
            }
        case .failed(let message):
            PrepFailedView(title: "Couldn't load this step", message: message) { Task { await retry() } }
        case .loaded(let value):
            content(value)
        }
    }
}

// MARK: - 1. How was this week?

private struct MealsPlanReviewStep: View {
    let model: MealsPlanModel
    let title: String
    let onNext: () -> Void
    let onOpen: (MealsDishRoute) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.l) {
                PlanLoadState(state: model.review, retry: model.loadReview) { review in
                    VStack(alignment: .leading, spacing: BrainStyle.l) {
                        PlanHeading(title: model.reviewsLastWeek ? "How was last week?" : "How was this week?",
                                    detail: review.needs.isEmpty ? "Nothing needs a look."
                                        : "Nights you logged are filled in. Only the others need a look.")
                        if !review.needs.isEmpty { needs(review) }
                        dots(review)
                        if !review.fixes.isEmpty { fixes(review.fixes) }
                    }
                }
                PlanError(message: model.error)
            }
            .padding(BrainStyle.l)
        }
        .background(Color.hxCanvas.ignoresSafeArea())
        .hxNavigationTitle(title, subtitle: "1 of 4 · \(MealsCopy.short(model.today))")
        .safeAreaInset(edge: .bottom) {
            PlanNextButton(title: "Next: what's left", busy: model.isSaving, disabled: !isLoaded) {
                Task { if await model.finishReview() { onNext() } }
            }
        }
        .task { if case .loading = model.review { await model.loadReview() } }
    }

    private var isLoaded: Bool {
        if case .loaded = model.review { return true }
        return false
    }

    private func needs(_ review: MealsPlanReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Needs a look",
                            trailing: review.needs.count == 1 ? "1 night" : "\(review.needs.count) nights")
            VStack(spacing: 0) {
                ForEach(Array(review.needs.enumerated()), id: \.element.id) { index, night in
                    if index > 0 { Divider() }
                    needRow(night)
                }
            }
            .padding(.horizontal, 16)
            .hxCard()
        }
    }

    private func needRow(_ night: MealsReviewNight) -> some View {
        let answer = model.answer(for: night.day)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: MealsCopy.weekday(night.day))
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(Color.hxTextSecondary)
                    .frame(width: 34, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: night.dishes.map(\.name).joined(separator: " + "))
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                    Text(verbatim: night.reason)
                        .font(AppFont.caption())
                        .foregroundStyle(Color.hxTextSecondary)
                }
            }
            FlowRow(spacing: 8) {
                PlanChoice(title: "Ate it", selected: answer?.choice == "ate") { model.choose("ate", for: night.day) }
                PlanChoice(title: "Skipped", selected: answer?.choice == "skipped") {
                    model.choose("skipped", for: night.day)
                }
                PlanChoice(title: "Ate out", selected: answer?.choice == "out") { model.choose("out", for: night.day) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: MealsCopy.weekdayName(night.day)))
            if let answer, answer.choice != "ate" {
                PlanChoice(title: model.reviewsLastWeek ? "Carry to this week" : "Carry to next week",
                           symbol: answer.carry ? "✓" : nil, selected: answer.carry) {
                    model.toggleCarry(night.day)
                }
            }
        }
        .padding(.vertical, 12)
    }

    private func dots(_ review: MealsPlanReview) -> some View {
        let paper = PlanStyle.paper
        return VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: model.reviewsLastWeek ? "Logged last week" : "Logged this week")
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
            HStack(spacing: 0) {
                ForEach(review.days) { day in
                    VStack(spacing: 4) {
                        Text(verbatim: MealsCopy.weekday(day.day))
                            .font(AppFont.caption2())
                            .foregroundStyle(Color.hxTextSecondary)
                        MealsReviewDot(state: day.state, paper: paper)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: "\(MealsCopy.weekdayName(day.day)), \(MealsCopy.reviewLabel(day.state))"))
                }
            }
            if !review.logged.isEmpty {
                Text(verbatim: review.logged.joined(separator: " · "))
                    .font(AppFont.caption())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hxCard()
    }

    private func fixes(_ dishes: [MealsSeasonPick]) -> some View {
        let atlas = HermexPaper.request
        return HXCard(.wash(atlas), spacing: 4) {
            Text(verbatim: dishes.count == 1 ? "A recipe change is waiting for you"
                 : "\(dishes.count) recipe changes are waiting for you")
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
        } content: {
            ForEach(dishes) { dish in
                Button { onOpen(MealsDishRoute(slug: dish.slug)) } label: {
                    HStack {
                        Text(verbatim: "Review \(dish.name)")
                            .font(AppFont.subheadline(weight: .semibold))
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(AppFont.caption(weight: .semibold))
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        } footer: {
            EmptyView()
        }
    }
}

/// A day on the review's dots card: a filled check when logged, a heavy ring when it needs a look,
/// a minus when skipped, a faint ring when still ahead, a faint dash with nothing planned.
private struct MealsReviewDot: View {
    let state: String
    let paper: HermexPaper

    var body: some View {
        ZStack {
            switch state {
            case "logged":
                Circle().fill(paper.glow)
                Image(systemName: "checkmark").font(AppFont.caption2(weight: .bold)).foregroundStyle(paper.onGlow)
            case "open":
                Circle().strokeBorder(paper.glow, lineWidth: 2)
            case "skipped", "out":
                Circle().strokeBorder(Color.hxSeparator, lineWidth: 1.5)
                Image(systemName: state == "out" ? "fork.knife" : "minus")
                    .font(AppFont.caption2(weight: .bold)).foregroundStyle(Color.hxTextSecondary)
            case "ahead":
                Circle().strokeBorder(Color.hxSeparator, lineWidth: 1.5)
            default:
                Capsule().fill(Color.hxSeparator).frame(width: 10, height: 2)
            }
        }
        .frame(width: 24, height: 24)
    }
}

extension MealsCopy {
    static func reviewLabel(_ state: String) -> String {
        switch state {
        case "logged": "logged"
        case "open": "needs a look"
        case "skipped": "skipped"
        case "out": "ate out"
        case "ahead": "still ahead"
        default: "nothing planned"
        }
    }
}

// MARK: - 2. What's left?

private struct MealsPlanLeftStep: View {
    let model: MealsPlanModel
    let title: String
    let onNext: () -> Void
    @State private var adding = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.l) {
                PlanHeading(title: "What's left?",
                            detail: "What's on hand and what skipped nights bought should still be around. Tick what's really there.")
                PlanLoadState(state: model.leftovers, retry: model.loadLeftovers) { items in
                    VStack(alignment: .leading, spacing: BrainStyle.l) {
                        let fridge = items.filter { $0.where != "freezer" }
                        let freezer = items.filter { $0.where == "freezer" }
                        if items.isEmpty {
                            Text(verbatim: "Nothing on the list. Add what's in the fridge or freezer.")
                                .font(AppFont.footnote())
                                .foregroundStyle(Color.hxTextSecondary)
                        }
                        if !fridge.isEmpty { section("Fridge", fridge) }
                        if !freezer.isEmpty { section("Freezer", freezer) }
                        addField
                    }
                }
                PlanError(message: model.error)
            }
            .padding(BrainStyle.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.hxCanvas.ignoresSafeArea())
        .hxNavigationTitle(title, subtitle: "2 of 4")
        .hxKeyboardDoneButton()
        .safeAreaInset(edge: .bottom) {
            PlanNextButton(title: "Next: fill the nights", busy: model.isSaving) {
                Task { if await model.saveLeftovers() { onNext() } }
            }
        }
        .task { if case .loading = model.leftovers { await model.loadLeftovers() } }
    }

    private func section(_ title: String, _ items: [MealsLeftover]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: title)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.text) { index, item in
                    if index > 0 { Divider().padding(.leading, 52) }
                    Button { model.toggle(item.text) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: model.checked.contains(item.text) ? "checkmark.circle.fill" : "circle")
                                .font(AppFont.title3())
                                .foregroundStyle(model.checked.contains(item.text) ? Color.accentColor : Color.hxSeparator)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: item.text)
                                    .font(AppFont.subheadline())
                                    .foregroundStyle(Color.hxTextPrimary)
                                Text(verbatim: item.why)
                                    .font(AppFont.caption())
                                    .foregroundStyle(Color.hxTextSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.checked.contains(item.text) ? .isSelected : [])
                }
            }
            .hxCard()
        }
    }

    private var addField: some View {
        HStack(spacing: 8) {
            TextField(text: $adding) { Text(verbatim: "Add something, like half a napa cabbage") }
                .font(AppFont.subheadline())
                .submitLabel(.done)
                .onSubmit(add)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous)
                    .strokeBorder(Color.hxSeparator, lineWidth: 0.5))
            Button(action: add) {
                Image(systemName: "plus").font(AppFont.body(weight: .semibold)).frame(width: 44, height: 44)
            }
            .disabled(adding.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel(Text(verbatim: "Add"))
        }
    }

    private func add() {
        model.addLeftover(adding)
        adding = ""
    }
}

// MARK: - 3. Fill the nights

private struct MealsPlanFillStep: View {
    let model: MealsPlanModel
    let title: String
    let onOpen: (MealsDishRoute) -> Void
    let onNext: () -> Void
    @State private var pickingFor: MealsHomeView.PickerTarget?

    private var paper: HermexPaper { PlanStyle.paper }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.l) {
                PlanLoadState(state: model.week.state, retry: model.startFill) { home in
                    VStack(alignment: .leading, spacing: BrainStyle.l) {
                        HStack(alignment: .firstTextBaseline) {
                            PlanHeading(title: "Fill the nights")
                            Spacer(minLength: 8)
                            Text(verbatim: "\(model.filledCount(home)) of 7")
                                .font(AppFont.footnote())
                                .foregroundStyle(Color.hxTextSecondary)
                        }
                        if !model.suggestions.lastYear.isEmpty { lastYear }
                        nights(home)
                    }
                }
                PlanError(message: model.error ?? model.week.saveError)
            }
            .padding(BrainStyle.l)
        }
        .background(Color.hxCanvas.ignoresSafeArea())
        .hxNavigationTitle(title, subtitle: "3 of 4 · \(MealsCopy.weekRange(model.target))")
        .disabled(model.week.isSaving)
        .safeAreaInset(edge: .bottom) {
            PlanNextButton(title: "Next: groceries", disabled: !hasNights) { onNext() }
        }
        .task { if !model.suggestionsLoaded { await model.startFill() } }
        .sheet(item: $pickingFor) { target in
            MealsDishPicker(viewModel: model.week, dayLabel: MealsCopy.weekdayName(target.day)) { dish in
                pickingFor = nil
                Task { await model.week.add(dish, to: target.day) }
            }
        }
    }

    private var hasNights: Bool {
        if case .loaded(let home) = model.week.state { return model.filledCount(home) > 0 }
        return false
    }

    private var lastYear: some View {
        let past = HermexPaper.past
        return HXCard(.glow(past), spacing: 8) {
            Text(verbatim: "This time last year")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(past.glow)
        } content: {
            FlowRow(spacing: 8) {
                ForEach(model.suggestions.lastYear) { pick in
                    Button { Task { await model.addToFirstOpenNight(pick) } } label: {
                        HXChip(paper: past, symbol: "plus", label: pick.name)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(verbatim: "Adds it to the first open night"))
                }
            }
        } footer: {
            EmptyView()
        }
    }

    private func nights(_ home: MealsHome) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(home.days.enumerated()), id: \.element.id) { index, day in
                if index > 0 { Divider().padding(.leading, 58) }
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Text(verbatim: MealsCopy.weekday(day.day)).font(AppFont.caption2())
                        Text(verbatim: MealsCopy.dayNumber(day.day))
                            .font(AppFont.display(style: .subheadline, weight: .semibold))
                    }
                    .foregroundStyle(Color.hxTextSecondary)
                    .frame(width: 34)
                    .padding(.top, 2)
                    if let night = day.night {
                        planned(night, day: day.day)
                    } else {
                        open(day.day, home: home)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .hxCard()
    }

    @ViewBuilder
    private func planned(_ night: MealsNight, day: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { if let main = night.main { onOpen(MealsDishRoute(slug: main.slug, servings: night.servings, day: day)) } } label: {
                    Text(verbatim: night.main?.name ?? "")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                if let serves = MealsCopy.serves(night.servings) { HXChip(paper: paper, label: serves) }
                menu(night, day: day)
            }
            if let sides = MealsCopy.sidesLine(night) {
                Text(verbatim: sides).font(AppFont.caption()).foregroundStyle(Color.hxTextSecondary)
            }
            let prep = night.dishes.flatMap { model.suggestions.prep[$0.slug] ?? [] }
            if !prep.isEmpty {
                Text(verbatim: "Prep the day before · " + prep.joined(separator: "; "))
                    .font(AppFont.caption())
                    .foregroundStyle(paper.glow)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let pairs = model.pairedSides(for: night)
            if !pairs.isEmpty {
                Text(verbatim: "Sides you usually pair").font(AppFont.caption()).foregroundStyle(Color.hxTextSecondary)
                FlowRow(spacing: 8) {
                    ForEach(pairs) { side in
                        PlanChoice(title: side.name, symbol: "+", selected: false) {
                            Task { await model.week.add(MealsDish(slug: side.slug, name: side.name, kind: "side"), to: day) }
                        }
                    }
                }
            }
        }
    }

    private func menu(_ night: MealsNight, day: String) -> some View {
        Menu {
            Button { pickingFor = MealsHomeView.PickerTarget(day: day) } label: {
                Label { Text(verbatim: "Add a dish") } icon: { Image(systemName: "plus") }
            }
            Menu {
                ForEach(night.dishes) { dish in
                    Button(dish.name) { Task { await model.week.remove(dish.slug, from: day) } }
                }
            } label: {
                Label { Text(verbatim: "Remove a dish") } icon: { Image(systemName: "minus.circle") }
            }
            Menu {
                Picker(selection: Binding(get: { night.servings },
                                          set: { n in Task { await model.week.setServings(n, on: day) } })) {
                    ForEach(MealsCopy.servingsChoices(including: night.servings), id: \.self) { n in
                        Text(verbatim: "\(n)").tag(n)
                    }
                } label: { EmptyView() }
            } label: {
                Label { Text(verbatim: "Servings: \(night.servings)") } icon: { Image(systemName: "person.2") }
            }
            Button(role: .destructive) { Task { await model.week.clear(day) } } label: {
                Label { Text(verbatim: "Clear the night") } icon: { Image(systemName: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(AppFont.subheadline(weight: .semibold))
                .frame(width: 44, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(verbatim: "\(MealsCopy.weekdayName(day)) options"))
    }

    @ViewBuilder
    private func open(_ day: String, home: MealsHome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pick = model.suggestion(for: day, in: home) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Atlas suggests")
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(paper.glow)
                    Text(verbatim: pick.name)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                    if let why = pick.why, !why.isEmpty {
                        Text(verbatim: why.prefix(1).uppercased() + why.dropFirst())
                            .font(AppFont.caption())
                            .foregroundStyle(paper.secondaryInk)
                    }
                    HStack(spacing: 8) {
                        Button { Task { await model.week.add(pick.dish, to: day) } } label: {
                            Text(verbatim: "Add")
                                .font(AppFont.subheadline(weight: .semibold))
                                .foregroundStyle(paper.onGlow)
                                .padding(.horizontal, 18)
                                .frame(minHeight: 36)
                                .background(paper.glow, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: "Add \(pick.name) on \(MealsCopy.weekdayName(day))"))
                        Button { model.another(for: day, in: home) } label: {
                            Text(verbatim: "Another")
                                .font(AppFont.subheadline(weight: .semibold))
                                .foregroundStyle(paper.glow)
                                .padding(.horizontal, 18)
                                .frame(minHeight: 36)
                                .background(paper.wash, in: Capsule())
                                .overlay(Capsule().strokeBorder(paper.edge, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glowSurface(paper, cornerRadius: HXRadius.md)
            }
            Button { pickingFor = MealsHomeView.PickerTarget(day: day) } label: {
                Label { Text(verbatim: "Pick a dish") } icon: { Image(systemName: "plus") }
                    .font(AppFont.subheadline(weight: .semibold))
                    .frame(minHeight: 36)
            }
        }
    }
}

// MARK: - 4. Groceries

private struct MealsPlanGroceriesStep: View {
    let model: MealsPlanModel
    let title: String
    let onDone: () -> Void
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BrainStyle.l) {
                PlanLoadState(state: model.groceries, retry: model.loadGroceries) { groceries in
                    VStack(alignment: .leading, spacing: BrainStyle.l) {
                        PlanHeading(title: "Groceries", detail: MealsCopy.groceriesLine(groceries))
                        if groceries.stores.isEmpty {
                            Text(verbatim: "Nothing to buy: it's all on hand or in the pantry.")
                                .font(AppFont.footnote())
                                .foregroundStyle(Color.hxTextSecondary)
                        }
                        ForEach(groceries.stores) { store in storeList(store) }
                        if !groceries.have.isEmpty {
                            Text(verbatim: "Not buying, you have them: " + groceries.have.joined(separator: ", ") + ".")
                                .font(AppFont.footnote())
                                .foregroundStyle(Color.hxTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                PlanError(message: model.error)
                if let reminders = model.finished?.reminders, let error = reminders.error {
                    Text(verbatim: "The week is saved, but Reminders didn't take the list: \(error)")
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxDanger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(BrainStyle.l)
        }
        .background(Color.hxCanvas.ignoresSafeArea())
        .hxNavigationTitle(title, subtitle: "4 of 4")
        .safeAreaInset(edge: .bottom) { buttons }
        // The nights may have changed on the step before: read the list fresh each time.
        .task { await model.loadGroceries() }
    }

    private var buttons: some View {
        VStack(spacing: 4) {
            PlanNextButton(title: "Save week and send to Reminders", busy: model.isSaving, disabled: !hasList) {
                Task { if await model.finish(reminders: true), model.finished?.reminders?.error == nil { onDone() } }
            }
            Button {
                Task { if await model.finish(reminders: false) { onDone() } }
            } label: {
                Text(verbatim: model.finished?.reminders?.error == nil ? "Save without groceries" : "Done")
                    .font(AppFont.subheadline(weight: .semibold))
                    .frame(minHeight: 44)
            }
            .disabled(model.isSaving)
        }
        .padding(.bottom, 4)
        .background(Color.hxCanvas)
    }

    private var hasList: Bool {
        if case .loaded(let groceries) = model.groceries { return !groceries.stores.isEmpty }
        return false
    }

    private func storeList(_ store: MealsStoreList) -> some View {
        let open = expanded.contains(store.store)
        let shown = open ? store.items : Array(store.items.prefix(4))
        return VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: store.store,
                            trailing: store.items.count == 1 ? "1 item" : "\(store.items.count) items")
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Divider().padding(.leading, 16) }
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: item.item.prefix(1).uppercased() + item.item.dropFirst())
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextPrimary)
                        Spacer(minLength: 8)
                        Text(verbatim: MealsCopy.asciiAmount(item.amount))
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
                if store.items.count > 4, !open {
                    Divider().padding(.leading, 16)
                    Button { expanded.insert(store.store) } label: {
                        Text(verbatim: "\(store.items.count - 4) more")
                            .font(AppFont.subheadline(weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 16)
                    }
                }
            }
            .hxCard()
        }
    }
}

extension MealsCopy {
    /// "1 1/2 lb" → "1½ lb", "2 cup + 1 tbsp" kept as written otherwise.
    static func asciiAmount(_ amount: String) -> String {
        let glyphs = ["1/8": "⅛", "1/4": "¼", "1/3": "⅓", "3/8": "⅜", "1/2": "½", "5/8": "⅝", "2/3": "⅔",
                      "3/4": "¾", "7/8": "⅞"]
        var out = amount
        for (ascii, glyph) in glyphs {
            out = out.replacingOccurrences(of: " \(ascii)", with: glyph).replacingOccurrences(of: ascii, with: glyph)
        }
        return out
    }
}
