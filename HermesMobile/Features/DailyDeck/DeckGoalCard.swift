import SwiftUI

/// The goal card's body: per goal, yesterday's commitments to check in (tap for Done, hold for
/// the 2-minute version, Skip or Missed), today's daily checks and cues, the next milestone and any
/// nudge. It reads live from the Goals API (`GoalCheckInCardViewModel`), so it stays true after a
/// tap or a later reopen; the brief's `fallback` text stands in until then, or when the server
/// can't serve goals.
struct DeckGoalCard: View {
    let card: DeckCard
    let palette: DeckPalette
    /// The deck's day ("2026-10-15"): the card checks in only when it is the server's today.
    let deckDate: String

    @Environment(GoalCheckInCardViewModel.self) private var model: GoalCheckInCardViewModel?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let goals = model?.isLive(for: deckDate) == true ? model?.goals(for: card) ?? [] : []
        VStack(alignment: .leading, spacing: 0) {
            if goals.isEmpty {
                placeholder
            } else if let model, case .loaded(let home) = model.state {
                ForEach(Array(goals.enumerated()), id: \.element.id) { index, goal in
                    if index > 0 { divider.padding(.vertical, 22) }
                    GoalCheckInSection(goal: goal, home: home, model: model,
                                       tint: GoalTint(palette, scheme: colorScheme), palette: palette)
                }
                if let error = model.error {
                    Text(verbatim: error)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxDanger)
                        .padding(.top, 14)
                }
            }
        }
        .task(id: deckDate) {
            // Each time the card appears (and when the deck turns over to a new day), so a check-in
            // made elsewhere shows. A reload keeps the card's goals on screen until it lands.
            guard let model else { return }
            if case .unavailable = model.state { return }
            await model.load()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let model else { return }
            if case .unavailable = model.state { return }
            Task { await model.load() }
        }
    }

    /// The brief's own words while loading, or when this server can't serve the card's goals.
    @ViewBuilder
    private var placeholder: some View {
        Text(verbatim: card.title ?? "Your goals")
            .font(AppFont.display(style: .title2, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, 30)
        if let fallback = card.fallback {
            Text(verbatim: fallback)
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
        if let model, case .failed = model.state {
            Button {
                Task { await model.load() }
            } label: {
                Label { Text(verbatim: "Retry") } icon: { Image(systemName: "arrow.clockwise") }
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(palette.ink)
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
        }
    }

    private var divider: some View {
        Rectangle().fill(palette.ink.opacity(0.12)).frame(height: 0.5)
    }
}

/// One goal on the card.
private struct GoalCheckInSection: View {
    let goal: GoalSummary
    let home: GoalsHome
    let model: GoalCheckInCardViewModel
    let tint: GoalTint
    let palette: DeckPalette

    var body: some View {
        let yesterday = GoalCheckInCardViewModel.yesterdayRows(goal)
        let items = GoalCheckInCardViewModel.itemRows(goal)
        let cues = GoalCheckInCardViewModel.todayCues(goal)
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: goal.title)
                .font(AppFont.display(style: .title2, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 30)
            if let days = goal.daysLeft, days >= 0 {
                Text(verbatim: days == 1 ? "1 day to go" : "\(days) days to go")
                    .font(AppFont.subheadline(weight: .medium))
                    .padding(.top, 6)
            }
            if !yesterday.isEmpty {
                header("Yesterday")
                ForEach(Array(yesterday.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Rectangle().fill(palette.ink.opacity(0.12)).frame(height: 0.5) }
                    GoalCommitmentRow(row: row, day: .yesterday, date: home.yesterday, tint: tint,
                                      isPending: model.isPending(goal.slug, .commitment(row.id)),
                                      atRisk: goal.flags.missTwice.contains(row.id)) { status in
                        Task { await model.checkIn(slug: goal.slug, commitment: row.id, status: status) }
                    }
                }
            }
            if !items.isEmpty {
                header("This week")
                ForEach(Array(items.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Rectangle().fill(palette.ink.opacity(0.12)).frame(height: 0.5) }
                    GoalItemRow(
                        row: row, tint: tint,
                        isPending: model.isPending(goal.slug, .commitment(row.id)),
                        atRisk: goal.flags.missTwice.contains(row.id),
                        onAdd: { note in await model.addItem(slug: goal.slug, commitment: row.id, note: note) },
                        onRemoveLast: { Task { await model.removeLastItem(slug: goal.slug, commitment: row.id) } }
                    )
                }
            }
            if !goal.dailyChecks.isEmpty || !cues.isEmpty {
                header("Today")
                ForEach(goal.dailyChecks) { check in
                    Text(verbatim: check.question)
                        .font(AppFont.body())
                        .foregroundStyle(Color.hxTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    GoalChoiceRow(
                        options: check.options.map { ($0, $0.capitalized) },
                        selected: check.today,
                        tint: tint,
                        isDisabled: model.isPending(goal.slug, .check(check.id)),
                        accessibilityPrefix: check.question
                    ) { value in
                        Task { await model.checkIn(slug: goal.slug, check: check.id, value: value) }
                    }
                    .padding(.bottom, 14)
                }
                ForEach(cues) { row in
                    Text(verbatim: "\(GoalsCopy.shortTitle(row.action)): \(row.cue)")
                        .font(AppFont.subheadline())
                        .foregroundStyle(Color.hxTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 6)
                }
            }
            if let milestone = goal.nextMilestone {
                let when = GoalDetailCopy.milestoneSubtitle(milestone, today: home.today)
                Text(verbatim: when.isEmpty ? "Next: \(milestone.title)" : "Next: \(milestone.title) · \(when)")
                    .font(AppFont.subheadline(weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
            ForEach(GoalDetailCopy.missTwiceRows(goal)) { row in
                GoalNote(systemImage: "exclamationmark.circle", tint: tint.fill, text: GoalDetailCopy.missTwice(row))
                    .padding(.top, 12)
            }
            ForEach(goal.flags.escalations, id: \.check) { escalation in
                GoalNote(systemImage: "exclamationmark.triangle", tint: .hxWarning, text: escalation.say)
                    .padding(.top, 12)
            }
            ForEach(goal.flags.unlockReady, id: \.id) { unlock in
                GoalNote(systemImage: "sparkles", tint: tint.fill, text: GoalDetailCopy.unlockOffer(unlock, in: goal))
                    .padding(.top, 12)
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(verbatim: title)
            .font(AppFont.subheadline(weight: .semibold))
            .padding(.top, 22)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
