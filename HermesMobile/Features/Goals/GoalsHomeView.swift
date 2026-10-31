import SwiftUI

/// Goals' landing screen: the show-up streak, active personal goals with this week's
/// progress, and the goals Atlas works on. Pushed from the drawer as `.goals`.
/// New goal opens a chat drafted to start Atlas's goal interview (`onNewGoal`).
struct GoalsHomeView: View {
    @State private var viewModel: GoalsHomeViewModel
    private let server: URL
    private let onNewGoal: () -> Void

    init(server: URL, onAPIError: @escaping (Error) -> Void, onNewGoal: @escaping () -> Void) {
        self.server = server
        self.onNewGoal = onNewGoal
        _viewModel = State(initialValue: GoalsHomeViewModel(
            client: APIClientGoalsAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
    }

    var body: some View {
        content
            .hxNavigationTitle("Goals")
            .background(Color.hxCanvas.ignoresSafeArea())
            .toolbar {
                if viewModel.offersNewGoal {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onNewGoal) { Image(systemName: "plus") }
                            .accessibilityLabel(Text(verbatim: "New goal"))
                    }
                }
            }
            // Every appear refreshes, so check-ins made in a goal show on the way back.
            .task {
                await viewModel.load()
                // The Goals widget shows the same day, so hand it what just loaded.
                if case .loaded(let home) = viewModel.state {
                    AtlasWidgetGoalsStore().save(AtlasWidgetGoals(server: server, home: home))
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
                Label { Text(verbatim: "No goals on this server") } icon: { Image(systemName: "flag.checkered") }
            } description: {
                Text(verbatim: "This server doesn't serve goals. It needs the goals API from your hermes-webui fork.")
            }
        case .failed(let message):
            PrepFailedView(title: "Couldn't load goals", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let home):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.l) {
                    if viewModel.refreshFailed {
                        Text(verbatim: GoalDetailViewModel.refreshFailed)
                            .font(BrainStyle.meta)
                            .foregroundStyle(Color.hxDanger)
                    }
                    if home.goals.isEmpty && home.errors.isEmpty {
                        emptyState
                    } else {
                        streakLine(home.streak)
                        activeSection(home)
                    }
                    if !home.finished.isEmpty { GoalsFinishedShelf(goals: home.finished) }
                    if !home.agentGoals.isEmpty { agentSection(home.agentGoals) }
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
        }
    }

    /// No open goals yet: what Goals is for, and New goal.
    private var emptyState: some View {
        ContentUnavailableView {
            Label { Text(verbatim: "No goals yet") } icon: { Image(systemName: "flag.checkered") }
        } description: {
            Text(verbatim: "Tell Atlas what you're working toward. It sets up the weekly commitments you check in here.")
        } actions: {
            Button(action: onNewGoal) { Text(verbatim: "New goal") }
        }
    }

    /// The show-up streak with Prep's reward flame (DESIGN.md § Reward gold), above the goals.
    private func streakLine(_ streak: GoalStreak) -> some View {
        Label {
            Text(verbatim: GoalsCopy.streakLine(streak))
        } icon: {
            Image(systemName: "flame").foregroundStyle(HermexPaper.opener.glow)
        }
        .font(BrainStyle.meta)
        .foregroundStyle(Color.hxTextPrimary)
        .padding(.horizontal, BrainStyle.xs)
    }

    private func activeSection(_ home: GoalsHome) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.m) {
            ForEach(home.goals) { goal in
                NavigationLink(value: ShellPushDestination.goal(goal.slug)) {
                    VStack(alignment: .leading, spacing: BrainStyle.s) {
                        GoalHeroCard(goal: goal, isCompact: true, today: home.today)
                            .zoomSource(for: .goal(goal.slug), cornerRadius: HXRadius.xl)
                        if goal.finishDue {
                            Text(verbatim: "Did you finish? Open to close it")
                                .font(BrainStyle.meta)
                                .foregroundStyle(GoalPaper.palette(for: goal).ink)
                                .padding(.horizontal, BrainStyle.xs)
                        } else if !goal.flags.escalations.isEmpty {
                            Text(verbatim: "Needs attention: open to check in")
                                .font(BrainStyle.meta)
                                .foregroundStyle(GoalPaper.palette(for: goal).ink)
                                .padding(.horizontal, BrainStyle.xs)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(verbatim: "Opens the goal"))
            }
            if !home.errors.isEmpty {
                SectionCard {
                    VStack(spacing: 0) {
                        ForEach(Array(home.errors.enumerated()), id: \.element.id) { offset, error in
                            if offset > 0 { PrepRowDivider() }
                            BrainRow(title: error.slug, subtitle: "Can't read this goal — fix in chat")
                        }
                    }
                }
            }
        }
    }

    private func agentSection(_ goals: [AgentGoalSummary]) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Atlas is working on")
            SectionCard {
                VStack(spacing: 0) {
                    // Plain rows: these goals live in chat, so nothing here opens.
                    ForEach(Array(goals.enumerated()), id: \.element.id) { offset, goal in
                        if offset > 0 { PrepRowDivider() }
                        BrainRow(title: goal.title, trailing: goal.status.capitalized)
                            .accessibilityAddTraits(.isStaticText)
                    }
                }
            }
        }
    }
}

/// Goals copy and small derivations shared by Goals home and goal detail.
enum GoalsCopy {
    /// New goal's chat draft: he types the wish after it and sends. Naming the skill makes
    /// Atlas load it rather than guess from the wording.
    static let newGoalDraft = "New goal (goal-interview skill): "

    static func streakTitle(_ days: Int) -> String {
        days == 1 ? "1-day show-up streak" : "\(days)-day show-up streak"
    }

    /// "12-day show-up streak", with "show up today to keep it" while it's at risk.
    static func streakLine(_ streak: GoalStreak) -> String {
        streak.atRisk ? "\(streakTitle(streak.days)) · show up today to keep it" : streakTitle(streak.days)
    }

    /// A commitment's short name: the last word of its action before any parenthesis
    /// ("Nightly stretch (knee hugs…)" → "Stretch", "Saturday taper run (~12 mi)" → "Run").
    static func shortName(_ action: String) -> String {
        let head = action.split(separator: "(").first.map(String.init) ?? action
        let word = head.split(separator: " ").last.map(String.init) ?? head
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// An action without its parenthetical: "Nightly stretch (knee hugs…)" → "Nightly stretch".
    static func shortTitle(_ action: String) -> String {
        (action.split(separator: "(").first.map(String.init) ?? action).trimmingCharacters(in: .whitespaces)
    }

    /// "today", "tomorrow", "in 6 days", "yesterday", "3 days ago", from ISO days.
    static func relativeDay(_ day: String, today: String) -> String {
        guard let n = GoalCalendar.days(from: today, to: day) else { return day }
        switch n {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case let n where n > 1: return "in \(n) days"
        default: return "\(-n) days ago"
        }
    }
}
