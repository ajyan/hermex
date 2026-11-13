import SwiftUI

/// An occasion a dish is tagged for, on its date this year: New Year's Eve and Toshikoshi soba.
struct MealsOccasion: Decodable, Equatable, Identifiable {
    let occasion: String
    let date: String
    let dishes: [MealsSeasonPick]
    var id: String { date + occasion }

    init(occasion: String, date: String, dishes: [MealsSeasonPick]) {
        self.occasion = occasion
        self.date = date
        self.dishes = dishes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        occasion = try c.decode(String.self, forKey: .occasion)
        date = try c.decode(String.self, forKey: .date)
        dishes = (try? c.decode([PrepLossy<MealsSeasonPick>].self, forKey: .dishes))?.compactMap(\.value) ?? []
    }

    private enum CodingKeys: String, CodingKey { case occasion, date, dishes }
}

/// A season's page (`GET /api/meals/season?day=&today=`): every week as seven `DeckDot` states
/// (done: a dinner logged; skip: one from the Apple Note import, its date an estimate; missed;
/// ahead; off: outside the season), the mains and sides made most, what was new, what he loved,
/// its occasions, and a day in the season before and after (none after when it hasn't begun).
struct MealsSeasonRecord: Decodable, Equatable {
    let name: String
    let start: String
    let end: String
    let dinners: Int
    let weeks: [Week]
    let mains: [MealsSeasonPick]
    let sides: [MealsSeasonPick]
    let new: [MealsSeasonPick]
    let loved: [MealsSeasonPick]
    let occasions: [Occasion]
    let prev: String?
    let next: String?

    struct Week: Decodable, Equatable, Identifiable {
        let week: String
        let days: [String]
        var id: String { week }
    }

    struct Occasion: Decodable, Equatable, Identifiable {
        let occasion: String
        let date: String
        /// What he ate that night; empty before it.
        let ate: [String]
        /// The dishes tagged for it, when he hasn't eaten it yet.
        let tagged: [String]
        var id: String { date + occasion }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        start = (try? c.decodeIfPresent(String.self, forKey: .start)) ?? ""
        end = (try? c.decodeIfPresent(String.self, forKey: .end)) ?? ""
        dinners = (try? c.decodeIfPresent(Int.self, forKey: .dinners)) ?? 0
        weeks = (try? c.decode([PrepLossy<Week>].self, forKey: .weeks))?.compactMap(\.value).filter { $0.days.count == 7 } ?? []
        func picks(_ key: CodingKeys) -> [MealsSeasonPick] {
            (try? c.decode([PrepLossy<MealsSeasonPick>].self, forKey: key))?.compactMap(\.value) ?? []
        }
        mains = picks(.mains)
        sides = picks(.sides)
        new = picks(.new)
        loved = picks(.loved)
        occasions = (try? c.decode([PrepLossy<Occasion>].self, forKey: .occasions))?.compactMap(\.value) ?? []
        prev = try? c.decodeIfPresent(String.self, forKey: .prev)
        next = try? c.decodeIfPresent(String.self, forKey: .next)
    }

    private enum CodingKeys: String, CodingKey {
        case name, start, end, dinners, weeks, mains, sides, new, loved, occasions, prev, next
    }
}

protocol MealsSeasonClient: Sendable {
    func season(day: String, today: String) async throws -> MealsSeasonRecord
}

extension APIClientMealsScreenAdapter: MealsSeasonClient {
    func season(day: String, today: String) async throws -> MealsSeasonRecord {
        try PrepDecoding.decodeAPI(try await apiClient.sendData(endpoint: .mealsSeason(day: day, today: today),
                                                                method: "GET"))
    }
}

/// The season page's state; `day` moves to the season before or after.
@MainActor
@Observable
final class MealsSeasonModel {
    private(set) var state: BrainLoadState<MealsSeasonRecord> = .loading
    private(set) var day: String
    let today: String
    @ObservationIgnored private let client: MealsSeasonClient
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private var generation = 0

    init(day: String, client: MealsSeasonClient, onAPIError: @escaping (Error) -> Void = { _ in },
         now: Date = Date()) {
        self.day = day
        self.client = client
        self.onAPIError = onAPIError
        today = MealsCopy.localDay(now)
    }

    func load() async {
        generation += 1
        let token = generation
        do {
            let record = try await client.season(day: day, today: today)
            guard token == generation else { return }
            state = .loaded(record)
        } catch {
            guard token == generation, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            onAPIError(error)
            state = (error as? APIError)?.isNotFound == true ? .unavailable : .failed(error.localizedDescription)
        }
    }

    func go(to day: String) async {
        self.day = day
        state = .loading
        await load()
    }
}

/// A season of dinners, from the recipe book's season card: the weeks as day dots, then most made
/// and go-to sides as pips, new this season, loved, and its occasions. Chevrons move a season.
struct MealsSeasonView: View {
    @State private var model: MealsSeasonModel
    private let onOpen: (ShellPushDestination) -> Void
    @ScaledMetric(relativeTo: .caption) private var dot: CGFloat = 12

    init(day: String, server: URL, onAPIError: @escaping (Error) -> Void,
         onOpen: @escaping (ShellPushDestination) -> Void) {
        let client = APIClientMealsScreenAdapter(apiClient: APIClient(baseURL: server))
        _model = State(initialValue: MealsSeasonModel(day: day, client: client, onAPIError: onAPIError))
        self.onOpen = onOpen
    }

    private var paper: HermexPaper { .meal }

    var body: some View {
        content
            .hxNavigationTitle(title)
            .background(Color.hxCanvas.ignoresSafeArea())
            .toolbar {
                if case .loaded(let record) = model.state {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { if let prev = record.prev { Task { await model.go(to: prev) } } } label: {
                            Image(systemName: "chevron.left").accessibilityLabel(Text(verbatim: "Season before"))
                        }
                        .disabled(record.prev == nil)
                        Button { if let next = record.next { Task { await model.go(to: next) } } } label: {
                            Image(systemName: "chevron.right").accessibilityLabel(Text(verbatim: "Season after"))
                        }
                        .disabled(record.next == nil)
                    }
                }
            }
            .task { if case .loading = model.state { await model.load() } }
    }

    private var title: String {
        if case .loaded(let record) = model.state { return record.name }
        return "Season"
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label { Text(verbatim: "No season pages on this server") } icon: { Image(systemName: "leaf") }
            } description: {
                Text(verbatim: "This server doesn't serve the season record. It needs the Meals API from your hermes-webui fork.")
            }
        case .failed(let message):
            HXFailedView(title: "Couldn't load the season", message: message) { Task { await model.load() } }
        case .loaded(let record):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.l) {
                    weeks(record)
                    if !record.mains.isEmpty { counted("Most made", record.mains) }
                    if !record.sides.isEmpty { counted("Go-to sides", record.sides) }
                    if !record.new.isEmpty { chips("New this \(record.name.split(separator: " ").first?.lowercased() ?? "season")", record.new) }
                    if !record.loved.isEmpty { chips("You loved", record.loved) }
                    if !record.occasions.isEmpty { occasions(record.occasions) }
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await model.load() }
        }
    }

    private func weeks(_ record: MealsSeasonRecord) -> some View {
        HXCard(.glow(paper), title: record.name, titleStyle: .title2, spacing: 10) {
            Text(verbatim: "Your season")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(paper.glow)
        } content: {
            Text(verbatim: "\(MealsCopy.monthDay(record.start)) – \(MealsCopy.monthDay(record.end)) · "
                 + (record.dinners == 1 ? "1 dinner" : "\(record.dinners) dinners"))
                .font(AppFont.footnote())
                .foregroundStyle(paper.secondaryInk)
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 52, height: 1)
                    ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { i in
                        Text(verbatim: ["M", "T", "W", "T", "F", "S", "S"][i])
                            .font(AppFont.caption2())
                            .foregroundStyle(paper.secondaryInk)
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityHidden(true)
                ForEach(record.weeks) { week in
                    HStack(spacing: 0) {
                        Text(verbatim: MealsCopy.monthDay(week.week))
                            .font(AppFont.caption2())
                            .foregroundStyle(paper.secondaryInk)
                            .frame(width: 52, alignment: .leading)
                        ForEach(Array(week.days.enumerated()), id: \.offset) { _, state in
                            DeckDot(state: state, ink: paper.glow, column: dot, size: dot)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: MealsCopy.weekSpoken(week)))
                }
            }
            if record.weeks.contains(where: { $0.days.contains("skip") }) {
                Text(verbatim: "Lighter dots are dinners from your Apple Note; their dates are estimates.")
                    .font(AppFont.caption())
                    .foregroundStyle(paper.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            EmptyView()
        }
    }

    /// Dishes with how often, as pips (one per time, ten at most) and the count beside.
    private func counted(_ title: String, _ picks: [MealsSeasonPick]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: title)
            VStack(spacing: 0) {
                ForEach(Array(picks.enumerated()), id: \.element.id) { index, pick in
                    if index > 0 { Divider().padding(.leading, 16) }
                    Button { onOpen(.mealsDish(MealsDishRoute(slug: pick.slug))) } label: {
                        HStack(spacing: 8) {
                            Text(verbatim: pick.name)
                                .font(AppFont.subheadline())
                                .foregroundStyle(Color.hxTextPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 3) {
                                ForEach(0..<min(pick.count ?? 0, 10), id: \.self) { _ in
                                    DeckDot(state: "done", ink: paper.glow, column: 8, size: 8)
                                }
                            }
                            Text(verbatim: "\(pick.count ?? 0)×")
                                .font(AppFont.caption())
                                .foregroundStyle(Color.hxTextSecondary)
                                .monospacedDigit()
                                .frame(minWidth: 24, alignment: .trailing)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "\(pick.name), \(pick.count ?? 0) times"))
                }
            }
            .hxCard()
        }
    }

    private func chips(_ title: String, _ picks: [MealsSeasonPick]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: title)
            FlowRow(spacing: 8) {
                ForEach(picks) { pick in
                    Button { onOpen(.mealsDish(MealsDishRoute(slug: pick.slug))) } label: {
                        HXChip(paper: paper, label: pick.name)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func occasions(_ list: [MealsSeasonRecord.Occasion]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Occasions")
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, occasion in
                    if index > 0 { Divider().padding(.leading, 16) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(occasion.occasion) · \(MealsCopy.short(occasion.date))")
                            .font(AppFont.caption(weight: .semibold))
                            .foregroundStyle(paper.glow)
                        Text(verbatim: occasion.ate.isEmpty
                             ? "Planned: " + occasion.tagged.joined(separator: ", ")
                             : occasion.ate.joined(separator: " · "))
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextPrimary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
            }
            .hxCard()
        }
    }
}

extension MealsCopy {
    /// "Week of Oct 26: 3 dinners logged".
    static func weekSpoken(_ week: MealsSeasonRecord.Week) -> String {
        let logged = week.days.filter { $0 == "done" || $0 == "skip" }.count
        return "Week of \(monthDay(week.week)): " + (logged == 1 ? "1 dinner logged" : "\(logged) dinners logged")
    }

    /// "New Year's Eve is Thursday", "… is today", "… is tomorrow", "… is Thu, Dec 31".
    static func occasionLine(_ occasion: MealsOccasion, today: String) -> String {
        guard let day = date(occasion.date), let now = date(today) else { return occasion.occasion }
        let days = Calendar(identifier: .gregorian).dateComponents([.day], from: now, to: day).day ?? 0
        let when = days == 0 ? "today" : days == 1 ? "tomorrow" : days < 7 ? weekdayName(occasion.date)
            : short(occasion.date)
        return "\(occasion.occasion) is \(when)"
    }
}
