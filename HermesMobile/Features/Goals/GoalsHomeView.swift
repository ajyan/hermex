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
                VStack(alignment: .leading, spacing: BrainStyle.xl) {
                    streakCard(home.streak)
                    if !home.goals.isEmpty || !home.errors.isEmpty { activeSection(home) }
                    if !home.agentGoals.isEmpty { agentSection(home.agentGoals) }
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
        }
    }

    private func streakCard(_ streak: GoalStreak) -> some View {
        SectionCard {
            BrainRow(
                leading: { BrainModuleIcon(systemName: "flame") },
                title: GoalsCopy.streakTitle(streak.days),
                subtitle: streak.atRisk ? "Yesterday's empty — show up today to keep it" : nil
            )
        }
    }

    private func activeSection(_ home: GoalsHome) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Active")
            SectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(home.goals.enumerated()), id: \.element.id) { offset, goal in
                        if offset > 0 { PrepRowDivider() }
                        NavigationLink(value: ShellPushDestination.goal(goal.slug)) {
                            GoalHomeRow(goal: goal, today: home.today)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(home.errors) { error in
                        PrepRowDivider()
                        BrainRow(title: error.slug, subtitle: "Can't read this goal — fix in chat")
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
                        BrainRow(title: goal.title, subtitle: goal.status.capitalized)
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                }
            }
        }
    }
}

/// One active goal: title, next milestone, and this week's counts, with a warning dot
/// when a second miss or an escalation is pending.
private struct GoalHomeRow: View {
    let goal: GoalSummary
    let today: String

    var body: some View {
        HStack(alignment: .center, spacing: BrainStyle.m) {
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                HStack(spacing: BrainStyle.s) {
                    if GoalsCopy.needsAttention(goal) {
                        Circle().fill(Color.hxWarning).frame(width: 6, height: 6).accessibilityHidden(true)
                    }
                    Text(verbatim: goal.title).brainText(.rowTitle).lineLimit(2)
                }
                if let milestone = goal.nextMilestone {
                    Text(verbatim: GoalsCopy.milestoneLine(milestone, today: today))
                        .brainText(.rowSubtitle).lineLimit(2)
                }
                Text(verbatim: GoalsCopy.weekLine(goal.week.commitments))
                    .brainText(.meta).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let days = goal.daysLeft {
                Text(verbatim: "\(days)d").brainText(.meta).monospacedDigit()
            }
            Image(systemName: "chevron.right")
                .font(BrainStyle.meta)
                .foregroundStyle(Color.hxTextSecondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, BrainStyle.s)
        .frame(minHeight: BrainStyle.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(GoalsCopy.needsAttention(goal) ? Text(verbatim: "Needs attention") : Text(verbatim: ""))
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

    static func weekLine(_ commitments: [GoalCommitmentProgress]) -> String {
        commitments.map { "\(shortName($0.action)) \($0.done + $0.min)/\($0.target)" }.joined(separator: " · ")
    }

    static func milestoneLine(_ milestone: GoalMilestone, today: String) -> String {
        guard let due = milestone.due else { return milestone.title }
        return "\(milestone.title) · \(relativeDay(due, today: today))"
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
