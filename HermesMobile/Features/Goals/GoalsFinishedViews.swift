import SwiftUI

/// Goals home's Finished shelf, newest first, each goal a glow card in its paper that opens its
/// record. One goal is one full-width card; two or more scroll sideways with See all.
struct GoalsFinishedShelf: View {
    let goals: [GoalFinishedSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            HStack(alignment: .firstTextBaseline) {
                BrainSectionHeader(title: "Finished", count: goals.count)
                if GoalsFinishedCopy.showsSeeAll(goals) {
                    NavigationLink(value: ShellPushDestination.finishedGoals) {
                        Text(verbatim: "See all").font(BrainStyle.meta)
                    }
                    .accessibilityHint(Text(verbatim: "Opens every finished goal"))
                }
            }
            if goals.count == 1, let goal = goals.first {
                link(goal) { GoalFinishedRow(goal: goal) }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: BrainStyle.s) {
                        ForEach(goals) { goal in
                            link(goal) { GoalFinishedCard(goal: goal) }
                        }
                    }
                    .padding(.vertical, BrainStyle.s)
                }
                .scrollClipDisabled()
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func link(_ goal: GoalFinishedSummary, @ViewBuilder _ card: () -> some View) -> some View {
        NavigationLink(value: ShellPushDestination.finishedGoal(goal.slug)) {
            card()
                .zoomSource(for: .finishedGoal(goal.slug), cornerRadius: HXRadius.xl)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: GoalsFinishedCopy.spoken(goal)))
                .accessibilityHint(Text(verbatim: "Opens the record"))
        }
        .buttonStyle(.plain)
    }
}

/// The only finished goal, full width: the medal, its name, then "Nov 1 · 261.4 miles run in 2026".
private struct GoalFinishedRow: View {
    let goal: GoalFinishedSummary

    var body: some View {
        let paper = GoalPaper.palette(named: goal.color, slug: goal.slug).colors
        HXCard(.glow(paper), spacing: BrainStyle.xs) {
            HStack(alignment: .firstTextBaseline, spacing: BrainStyle.s) {
                Image(systemName: "medal.fill").foregroundStyle(HermexPaper.opener.glow)
                Text(verbatim: GoalsFinishedCopy.name(goal))
                    .font(AppFont.display(style: .headline, weight: .semibold))
                    .foregroundStyle(paper.glow)
            }
            Text(verbatim: GoalsFinishedCopy.rowLine(goal))
                .font(BrainStyle.meta)
                .foregroundStyle(Color.hxTextPrimary)
                .monospacedDigit()
        }
    }
}

/// One of several finished goals on the sideways shelf: the date and medal, the name, the headline.
private struct GoalFinishedCard: View {
    let goal: GoalFinishedSummary
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 188

    var body: some View {
        let paper = GoalPaper.palette(named: goal.color, slug: goal.slug).colors
        HXCard(.glow(paper), spacing: BrainStyle.xs) {
            HStack {
                Text(verbatim: GoalFinishCopy.shortDate(goal.finished)).font(AppFont.caption(weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "medal.fill").foregroundStyle(HermexPaper.opener.glow)
            }
            .foregroundStyle(paper.glow)
            Text(verbatim: GoalsFinishedCopy.name(goal))
                .font(AppFont.display(style: .subheadline, weight: .semibold))
                .foregroundStyle(paper.glow)
                .lineLimit(2, reservesSpace: true)
            if let headline = goal.headline {
                Text(verbatim: headline.value)
                    .font(AppFont.display(style: .title2, weight: .bold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .monospacedDigit()
                Text(verbatim: headline.label)
                    .font(AppFont.caption2())
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineLimit(1)
            }
        }
        .frame(width: width)
    }
}

/// Every finished goal by year, with lifetime totals on top. Pushed as `.finishedGoals`.
struct GoalsFinishedListView: View {
    @State private var viewModel: GoalsHomeViewModel

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        _viewModel = State(initialValue: GoalsHomeViewModel(
            client: APIClientGoalsAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
    }

    var body: some View {
        content
            .hxNavigationTitle("Finished goals", subtitle: subtitle)
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
    }

    private var subtitle: String? {
        guard case .loaded(let home) = viewModel.state else { return nil }
        return home.finished.count == 1 ? "1 achieved" : "\(home.finished.count) achieved"
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView(label: { Text(verbatim: "No goals on this server") })
        case .failed(let message):
            PrepFailedView(title: "Couldn't load goals", message: message) { Task { await viewModel.load() } }
        case .loaded(let home) where home.finished.isEmpty:
            ContentUnavailableView {
                Label { Text(verbatim: "Nothing finished yet") } icon: { Image(systemName: "medal") }
            } description: {
                Text(verbatim: "When you finish a goal, its record lands here.")
            }
        case .loaded(let home):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.l) {
                    GoalStatGrid(tiles: GoalsFinishedCopy.lifetime(home.finished), paper: HermexPaper.opener)
                    ForEach(GoalsFinishedCopy.byYear(home.finished), id: \.year) { group in
                        VStack(alignment: .leading, spacing: BrainStyle.s) {
                            BrainSectionHeader(title: group.year)
                            SectionCard {
                                VStack(spacing: 0) {
                                    ForEach(Array(group.goals.enumerated()), id: \.element.id) { offset, goal in
                                        if offset > 0 { PrepRowDivider() }
                                        row(goal)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
        }
    }

    private func row(_ goal: GoalFinishedSummary) -> some View {
        let paper = GoalPaper.palette(named: goal.color, slug: goal.slug).colors
        return NavigationLink(value: ShellPushDestination.finishedGoal(goal.slug)) {
            BrainRow(
                leading: {
                    Image(systemName: GoalPaper.symbol(goal.icon))
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(paper.glow)
                        .frame(width: 34, height: 34)
                        .glowSurface(paper, cornerRadius: HXRadius.sm)
                },
                title: GoalsFinishedCopy.name(goal),
                subtitle: "\(GoalFinishCopy.shortDate(goal.finished)) · \(goal.days == 1 ? "1 day" : "\(goal.days) days")",
                trailing: goal.headline.map { "\($0.value) \($0.label)" }
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(verbatim: "Opens the record"))
    }
}

enum GoalsFinishedCopy {
    /// The goal by who he became ("NYC Marathon finisher" from "a New York City Marathon
    /// finisher"), else its title.
    static func name(_ goal: GoalFinishedSummary) -> String {
        guard !goal.identity.isEmpty else { return goal.title }
        var words = goal.identity.split(separator: " ").map(String.init)
        if let first = words.first, ["a", "an", "the"].contains(first.lowercased()) { words.removeFirst() }
        let name = words.joined(separator: " ")
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The full-width row's line: the race ("Nov 1 · 26.6 mi in 5:13:34"), else the headline
    /// ("Nov 1 · 261.4 miles run in 2026"), else "Nov 1 · 23 days".
    static func rowLine(_ goal: GoalFinishedSummary) -> String {
        let date = GoalFinishCopy.shortDate(goal.finished)
        if let race = goal.race, race.seconds > 0 {
            return "\(date) · \(race.miles.formatted(.number.precision(.fractionLength(0...1)))) mi in \(GoalFinishCopy.clock(race.seconds))"
        }
        if let h = goal.headline, !h.value.isEmpty { return "\(date) · \(h.value) \(h.label)" }
        return "\(date) · \(goal.days == 1 ? "1 day" : "\(goal.days) days")"
    }

    /// See all only when the shelf holds more than the one goal it already shows in full.
    static func showsSeeAll(_ goals: [GoalFinishedSummary]) -> Bool { goals.count > 1 }

    static func spoken(_ goal: GoalFinishedSummary) -> String {
        var parts = [name(goal), "finished \(GoalFinishCopy.longDate(goal.finished))"]
        if let h = goal.headline { parts.append("\(h.value) \(h.label)") }
        return parts.joined(separator: ", ")
    }

    static func byYear(_ goals: [GoalFinishedSummary]) -> [(year: String, goals: [GoalFinishedSummary])] {
        var order: [String] = []
        var groups: [String: [GoalFinishedSummary]] = [:]
        for goal in goals {
            let year = String(goal.finished.prefix(4))
            if groups[year] == nil { order.append(year) }
            groups[year, default: []].append(goal)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    static func lifetime(_ goals: [GoalFinishedSummary]) -> [GoalStatTile] {
        let shown = goals.reduce(0) { $0 + $1.shown }
        let onTime = goals.reduce(0) { $0 + $1.milestonesOnTime }
        let milestones = goals.reduce(0) { $0 + $1.milestones }
        return [
            GoalStatTile(label: "Achieved", value: "\(goals.count)"),
            GoalStatTile(label: "Days shown up", value: "\(shown)"),
            GoalStatTile(label: "Milestones on time", value: "\(onTime) / \(milestones)"),
        ]
    }
}
