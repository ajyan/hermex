import SwiftUI

/// Goals' landing screen: the show-up streak, active personal goals with this week's
/// progress, and the goals Atlas works on. Pushed from the drawer as `.goals`.
struct GoalsHomeView: View {
    @State private var viewModel: GoalsHomeViewModel

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        _viewModel = State(initialValue: GoalsHomeViewModel(
            client: APIClientGoalsAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
    }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: "Goals"))
            .background(Color.hxCanvas.ignoresSafeArea())
            // Every appear refreshes, so check-ins made in a goal show on the way back.
            .task { await viewModel.load() }
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
                    if !home.goals.isEmpty || !home.errors.isEmpty { activeSection(home) }
                    streakLine(home.streak)
                    if !home.agentGoals.isEmpty { agentSection(home.agentGoals) }
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
        }
    }

    private func streakLine(_ streak: GoalStreak) -> some View {
        HStack(spacing: BrainStyle.s) {
            if streak.atRisk {
                Circle().fill(Color.hxWarning).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            Text(verbatim: streak.atRisk
                 ? "\(GoalsCopy.streakTitle(streak.days)) · show up today to keep it"
                 : GoalsCopy.streakTitle(streak.days))
                .brainText(.meta)
        }
        .padding(.horizontal, BrainStyle.xs)
    }

    private func activeSection(_ home: GoalsHome) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.m) {
            ForEach(home.goals) { goal in
                NavigationLink(value: ShellPushDestination.goal(goal.slug)) {
                    VStack(alignment: .leading, spacing: BrainStyle.s) {
                        GoalHeroCard(goal: goal, isCompact: true, today: home.today)
                        if GoalsCopy.needsAttention(goal) {
                            Text(verbatim: "Needs attention: open to check in")
                                .font(BrainStyle.meta)
                                .foregroundStyle(Color.hxWarning)
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
                    ForEach(Array(goals.enumerated()), id: \.element.id) { offset, goal in
                        if offset > 0 { PrepRowDivider() }
                        BrainRow(
                            leading: { BrainModuleIcon(systemName: "sparkles") },
                            title: goal.title,
                            subtitle: goal.status.capitalized
                        )
                    }
                }
            }
        }
    }
}

/// Goals copy and small derivations shared by Goals home and goal detail.
enum GoalsCopy {
    static func streakTitle(_ days: Int) -> String {
        days == 1 ? "1-day show-up streak" : "\(days)-day show-up streak"
    }

    static func needsAttention(_ goal: GoalSummary) -> Bool {
        !goal.flags.missTwice.isEmpty || !goal.flags.escalations.isEmpty
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

    static func weekLine(_ commitments: [GoalCommitmentProgress]) -> String {
        commitments.map { "\(shortName($0.action)) \($0.done + $0.min)/\($0.target)" }.joined(separator: " · ")
    }

    /// "today", "tomorrow", "in 6 days", "yesterday", "3 days ago", from ISO days.
    static func relativeDay(_ day: String, today: String) -> String {
        guard let a = isoDay(day), let b = isoDay(today) else { return day }
        let n = Calendar(identifier: .gregorian).dateComponents([.day], from: b, to: a).day ?? 0
        switch n {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case let n where n > 1: return "in \(n) days"
        default: return "\(-n) days ago"
        }
    }

    static func isoDay(_ s: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }
}
