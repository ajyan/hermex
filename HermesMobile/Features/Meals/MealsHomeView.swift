import SwiftUI

/// The Meals screen: tonight's meal on top, with Eating it and tomorrow's prep, then the week
/// Monday to Sunday. A day's menu adds or removes dishes, sets servings, moves the meal to another
/// day, or clears it. A dish opens its recipe at the night's servings, and the book button opens
/// the recipe book. Pushed from the drawer as `.meals` and opened by the Tonight widget.
struct MealsHomeView: View {
    @State private var viewModel: MealsHomeViewModel
    /// The day the dish picker adds to.
    @State private var pickingFor: PickerTarget?
    @State private var planning = false
    private let server: URL
    private let onAPIError: (Error) -> Void
    private let onOpen: (ShellPushDestination) -> Void
    private let ask: (String) -> Void

    init(server: URL, onAPIError: @escaping (Error) -> Void, onOpen: @escaping (ShellPushDestination) -> Void,
         ask: @escaping (String) -> Void) {
        self.server = server
        self.onAPIError = onAPIError
        self.onOpen = onOpen
        self.ask = ask
        let client = APIClientMealsScreenAdapter(apiClient: APIClient(baseURL: server))
        _viewModel = State(initialValue: MealsHomeViewModel(client: client, onAPIError: onAPIError, onHome: { home in
            MealsWidgetSync.update(server: server, home: home)
        }))
    }

    private var paper: HermexPaper { .meal }

    var body: some View {
        content
            .hxNavigationTitle("Meals", subtitle: MealsCopy.short(viewModel.today))
            .background(Color.hxCanvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { onOpen(.mealsBook) } label: {
                        Image(systemName: "book.closed").accessibilityLabel(Text(verbatim: "Recipes"))
                    }
                }
            }
            // Every appear refreshes, so a night logged from the widget shows on the way back.
            .task { await viewModel.load() }
            .sheet(item: $viewModel.logDraft) { draft in
                MealsLogSheet(draft: draft, viewModel: viewModel)
            }
            .sheet(isPresented: $planning, onDismiss: { Task { await viewModel.load() } }) {
                MealsPlanSheet(server: server, onAPIError: onAPIError, ask: ask)
            }
            .sheet(item: $pickingFor) { target in
                MealsDishPicker(viewModel: viewModel, dayLabel: MealsCopy.weekdayName(target.day)) { dish in
                    pickingFor = nil
                    Task { await viewModel.add(dish, to: target.day) }
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
                Label { Text(verbatim: "No Meals on this server") } icon: { Image(systemName: "fork.knife") }
            } description: {
                Text(verbatim: "This server doesn't serve Meals. It needs the Meals API from your hermes-webui fork.")
            }
        case .failed(let message):
            PrepFailedView(title: "Couldn't load Meals", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let home):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.l) {
                    if let error = viewModel.saveError {
                        Text(verbatim: error)
                            .font(AppFont.footnote())
                            .foregroundStyle(Color.hxDanger)
                    }
                    tonightCard(home)
                    week(home)
                    planButton
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
            .disabled(viewModel.isSaving)
        }
    }

    // MARK: Tonight

    private func tonightCard(_ home: MealsHome) -> some View {
        HXCard(.glow(paper), title: home.tonight?.main?.name ?? "Nothing planned tonight",
               titleStyle: home.tonight == nil ? .title3 : .title2, spacing: 10) {
            HStack {
                Text(verbatim: "Tonight · \(MealsCopy.weekdayName(home.day))")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(paper.glow)
                Spacer(minLength: 8)
                if let serves = home.tonight.flatMap({ MealsCopy.serves($0.servings) }) {
                    HXChip(paper: paper, label: serves)
                }
            }
        } content: {
            if let tonight = home.tonight {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tonight.sides) { side in
                        Button { open(side, night: tonight) } label: {
                            Text(verbatim: side.name)
                                .font(AppFont.subheadline())
                                .foregroundStyle(Color.hxTextPrimary)
                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text(verbatim: "Opens the recipe"))
                    }
                }
                if let main = tonight.main {
                    Button { open(main, night: tonight) } label: {
                        Label { Text(verbatim: "Recipe") } icon: { Image(systemName: "book.closed") }
                            .font(AppFont.footnote(weight: .semibold))
                            .frame(minHeight: 32)
                    }
                    .accessibilityLabel(Text(verbatim: "\(main.name) recipe"))
                }
                if !home.tomorrowPrep.isEmpty { tomorrowPrep(home.tomorrowPrep) }
            } else if !home.tomorrowPrep.isEmpty {
                tomorrowPrep(home.tomorrowPrep)
            }
        } footer: {
            tonightButtons(home)
                .padding(.top, 4)
        }
    }

    private func tomorrowPrep(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "For tomorrow")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(paper.glow)
            ForEach(lines, id: \.self) { line in
                Text(verbatim: line)
                    .font(AppFont.footnote())
                    .foregroundStyle(paper.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glowSurface(paper, cornerRadius: HXRadius.md)
    }

    @ViewBuilder
    private func tonightButtons(_ home: MealsHome) -> some View {
        if home.tonight == nil {
            Button { pickingFor = PickerTarget(day: home.day) } label: {
                Label { Text(verbatim: "Add dinner") } icon: { Image(systemName: "plus") }
                    .font(AppFont.subheadline(weight: .semibold))
                    .frame(minHeight: 44)
            }
            .tint(paper.glow)
        } else if home.tonightLogged {
            HStack(spacing: 10) {
                Label { Text(verbatim: "Logged") } icon: { Image(systemName: "checkmark.circle.fill") }
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(paper.glow)
                Spacer(minLength: 8)
                Button { viewModel.rateTonight() } label: {
                    Text(verbatim: "Rate and notes")
                        .font(AppFont.subheadline(weight: .semibold))
                        .frame(minHeight: 44)
                }
                .tint(paper.glow)
            }
        } else {
            let others = home.days.filter { $0.day != home.day && $0.logged == nil }
            HStack(spacing: 10) {
                Button { Task { await viewModel.eatTonight() } } label: {
                    Text(verbatim: "Eating it")
                        .font(AppFont.display(style: .headline, weight: .semibold))
                        .foregroundStyle(paper.onGlow)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(paper.glow)
                .accessibilityHint(Text(verbatim: "Logs tonight's dinner"))
                if !others.isEmpty {
                    Menu {
                        ForEach(others) { day in
                            Button(MealsCopy.swapLabel(day)) {
                                Task { await viewModel.move(from: home.day, to: day.day) }
                            }
                        }
                    } label: {
                        Text(verbatim: "Swap night")
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(paper.glow)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 44)
                            .background(paper.wash, in: Capsule())
                            .overlay(Capsule().strokeBorder(paper.edge, lineWidth: 0.5))
                    }
                    .accessibilityHint(Text(verbatim: "Trades tonight's meal with another night"))
                }
            }
        }
    }

    // MARK: The week

    /// Opens the weekend planner: next week from Friday on, else the rest of this week.
    private var planButton: some View {
        Button { planning = true } label: {
            Label { Text(verbatim: MealsCopy.planTitle(Date())) } icon: { Image(systemName: "calendar.badge.plus") }
                .font(AppFont.subheadline(weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityHint(Text(verbatim: "Review this week, what's left, fill the nights and send groceries"))
    }

    private func week(_ home: MealsHome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "This week")
            VStack(spacing: 0) {
                ForEach(Array(home.days.enumerated()), id: \.element.id) { index, day in
                    if index > 0 { Divider().padding(.leading, 58) }
                    MealsDayRow(day: day, isToday: day.day == home.day, paper: paper) {
                        pickingFor = PickerTarget(day: day.day)
                    }
                    .onTapGesture {
                        if let night = day.night, let main = night.main { open(main, night: night) }
                    }
                    .accessibilityAction(named: Text(verbatim: "Open the recipe")) {
                        if let night = day.night, let main = night.main { open(main, night: night) }
                    }
                    .contextMenu { dayMenu(day, home: home) }
                }
            }
            .hxCard()
        }
    }

    private func open(_ dish: MealsDish, night: MealsNight) {
        onOpen(.mealsDish(MealsDishRoute(slug: dish.slug, servings: night.servings, day: night.day)))
    }

    @ViewBuilder
    private func dayMenu(_ day: MealsDay, home: MealsHome) -> some View {
        Button { pickingFor = PickerTarget(day: day.day) } label: {
            Label { Text(verbatim: "Add a dish") } icon: { Image(systemName: "plus") }
        }
        if let night = day.night {
            Menu {
                ForEach(night.dishes) { dish in
                    Button(dish.name) { open(dish, night: night) }
                }
            } label: {
                Label { Text(verbatim: "Recipes") } icon: { Image(systemName: "book.closed") }
            }
            Menu {
                ForEach(night.dishes) { dish in
                    Button(dish.name) { Task { await viewModel.remove(dish.slug, from: day.day) } }
                }
            } label: {
                Label { Text(verbatim: "Remove a dish") } icon: { Image(systemName: "minus.circle") }
            }
            Menu {
                Picker(selection: Binding(
                    get: { night.servings },
                    set: { servings in Task { await viewModel.setServings(servings, on: day.day) } }
                )) {
                    ForEach(MealsCopy.servingsChoices(including: night.servings), id: \.self) { n in
                        Text(verbatim: "\(n)").tag(n)
                    }
                } label: { EmptyView() }
            } label: {
                Label { Text(verbatim: "Servings: \(night.servings)") } icon: { Image(systemName: "person.2") }
            }
            Menu {
                ForEach(home.days.filter { $0.day != day.day }) { other in
                    Button(MealsCopy.moveLabel(other)) {
                        Task { await viewModel.move(from: day.day, to: other.day) }
                    }
                }
            } label: {
                Label { Text(verbatim: "Move to") } icon: { Image(systemName: "arrow.left.arrow.right") }
            }
            Button(role: .destructive) { Task { await viewModel.clear(day.day) } } label: {
                Label { Text(verbatim: "Clear the night") } icon: { Image(systemName: "trash") }
            }
        }
    }

    struct PickerTarget: Identifiable {
        let day: String
        var id: String { day }
    }
}

/// One day of the week: its date, the meal (main, then sides), and a day circle: a filled check
/// once logged, a ring for tonight, a faint ring for a planned night. An open night offers a plus.
private struct MealsDayRow: View {
    let day: MealsDay
    let isToday: Bool
    let paper: HermexPaper
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(verbatim: MealsCopy.weekday(day.day))
                    .font(AppFont.caption2(weight: isToday ? .semibold : nil))
                Text(verbatim: MealsCopy.dayNumber(day.day))
                    .font(AppFont.display(style: .subheadline, weight: .semibold))
            }
            .foregroundStyle(isToday ? paper.glow : Color.hxTextSecondary)
            .frame(width: 34)
            meal
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var meal: some View {
        if let logged = day.logged, day.night == nil || logged.out {
            Text(verbatim: logged.out ? "Ate out" : logged.dishes.map(\.name).joined(separator: " · "))
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextSecondary)
        } else if let night = day.night, let main = night.main {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: main.name)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(day.logged == nil ? Color.hxTextPrimary : Color.hxTextSecondary)
                if let sides = MealsCopy.sidesLine(night) {
                    Text(verbatim: sides)
                        .font(AppFont.caption())
                        .foregroundStyle(Color.hxTextSecondary)
                }
            }
        } else {
            Text(verbatim: "Nothing planned")
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextSecondary)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let serves = day.night.flatMap({ MealsCopy.serves($0.servings) }), day.logged == nil {
            HXChip(paper: paper, label: serves)
        }
        if day.logged != nil {
            Image(systemName: "checkmark")
                .font(AppFont.caption(weight: .bold))
                .foregroundStyle(paper.onGlow)
                .frame(width: 22, height: 22)
                .background(paper.glow, in: Circle())
                .accessibilityLabel(Text(verbatim: "Logged"))
        } else if day.night != nil {
            Circle()
                .strokeBorder(isToday ? paper.glow : Color.hxSeparator, lineWidth: isToday ? 2 : 1.5)
                .frame(width: 22, height: 22)
                .accessibilityLabel(Text(verbatim: isToday ? "Tonight" : "Planned"))
        } else {
            Button(action: onAdd) {
                Image(systemName: "plus.circle")
                    .font(AppFont.title3())
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel(Text(verbatim: "Plan \(MealsCopy.weekdayName(day.day))"))
        }
    }
}

extension MealsCopy {
    /// "Wed · Kabocha with pork riblets", or "Sun · nothing planned".
    static func swapLabel(_ day: MealsDay) -> String {
        "\(weekday(day.day)) · \(day.night?.main?.name ?? "nothing planned")"
    }

    /// "Wed (swaps with Kabocha with pork riblets)", or "Sun".
    static func moveLabel(_ day: MealsDay) -> String {
        guard let main = day.night?.main?.name else { return weekdayName(day.day) }
        return "\(weekdayName(day.day)) (swaps with \(main))"
    }

    static func servingsChoices(including current: Int) -> [Int] {
        Array(Set(servingsChoices + [current])).sorted()
    }
}
