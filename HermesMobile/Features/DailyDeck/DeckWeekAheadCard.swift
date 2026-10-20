import SwiftUI

/// A Sunday review's Week ahead card: one goal's proposed commitments for next week. Each row
/// has a stepper for its target and a remove toggle, and a changed row says what changed and
/// why. Keep confirms the rows as edited, Ease off confirms last week's plan one lighter, and
/// Edit in chat starts a chat with the proposal. It confirms through the deck's
/// `GoalCheckInCardViewModel`, which knows the server's today and which weeks are confirmed;
/// until that loads, or on a server without Goals, the brief's `fallback` text stands in.
struct DeckWeekAheadCard: View {
    let card: DeckCard
    let palette: DeckPalette

    @Environment(GoalCheckInCardViewModel.self) private var goals: GoalCheckInCardViewModel?
    @Environment(\.openDraftChat) private var openDraftChat
    @State private var model: WeekAheadViewModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: card.title ?? "Next week")
                .font(AppFont.display(style: .title2, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 30)
            if let start = card.start {
                Text(verbatim: "Week of \(DailyDeckPaths.label(start))")
                    .font(AppFont.subheadline(weight: .medium))
                    .padding(.top, 6)
            }
            if let model {
                WeekAheadRows(model: model, palette: palette) { await confirm(model, $0) }
            } else {
                placeholder
            }
            if openDraftChat.isAvailable, !card.weekCommitments.isEmpty {
                Button {
                    openDraftChat(WeekAheadViewModel.chatDraft(card: card, goalTitle: WeekAheadViewModel.goalTitle(card: card, home: home)))
                } label: {
                    Label { Text(verbatim: "Edit in chat") } icon: { Image(systemName: "bubble.left") }
                }
                .buttonStyle(.chatDecision(.secondary))
                .padding(.top, 10)
            }
        }
        .environment(\.hxPaper, palette.colors)
        .task { await prepare() }
        .onChange(of: home) { _, home in
            if let home { adopt(home) }
        }
    }

    private var home: GoalsHome? {
        guard let goals, case .loaded(let home) = goals.state else { return nil }
        return home
    }

    /// Loads the deck's goals when nothing has yet, then builds the rows.
    private func prepare() async {
        guard let goals, model == nil else { return }
        switch goals.state {
        case .loaded, .unavailable: break
        case .loading, .failed: await goals.load()
        }
        if let home { adopt(home) }
    }

    /// Builds the rows on the first load, then keeps the server's today and the confirmed
    /// state current with every reload.
    private func adopt(_ home: GoalsHome) {
        if model == nil, let goals {
            model = WeekAheadViewModel(card: card, client: goals.client, today: home.today)
        }
        model?.sync(home)
    }

    /// Runs Keep or Ease off, then hands the server's answer to the goal card so it agrees.
    private func confirm(_ model: WeekAheadViewModel, _ action: WeekAheadRows.Action) async {
        switch action {
        case .keep: await model.keep()
        case .easeOff: await model.easeOff()
        }
        if let result = model.result {
            goals?.apply(result)
        } else if model.today != home?.today {
            // A 409 reloaded a new day into the card; bring the deck's goal card along.
            await goals?.load()
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let fallback = card.fallback {
            Text(verbatim: fallback)
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
        if let goals, case .failed = goals.state {
            Button {
                Task { await prepare() }
            } label: {
                Label { Text(verbatim: "Retry") } icon: { Image(systemName: "arrow.clockwise") }
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(palette.ink)
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
        }
    }
}

/// The editable rows, the save state, and Keep and Ease off.
private struct WeekAheadRows: View {
    enum Action { case keep, easeOff }

    @Bindable var model: WeekAheadViewModel
    let palette: DeckPalette
    let run: (Action) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach($model.rows) { $row in
                Rectangle().fill(palette.ink.opacity(0.12)).frame(height: 0.5)
                WeekAheadRowView(row: $row, palette: palette, isEnabled: model.canEdit)
            }
            status.padding(.top, 14)
            if model.canEdit || model.phase == .saving {
                let isSaving = model.phase == .saving
                Button {
                    Task { await run(.keep) }
                } label: {
                    Text(verbatim: "Keep")
                }
                .buttonStyle(.chatDecision(.primary))
                .disabled(isSaving || model.rows.allSatisfy(\.removed))
                .padding(.top, 14)
                Button {
                    Task { await run(.easeOff) }
                } label: {
                    Text(verbatim: "Ease off")
                }
                .buttonStyle(.chatDecision(.secondary))
                .disabled(isSaving || model.card.lastWeek.isEmpty)
                .padding(.top, 10)
                .accessibilityHint(Text(verbatim: "Keeps last week's plan, one lighter each."))
            }
        }
        .padding(.top, 16)
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .editing:
            EmptyView()
        case .saving:
            ProgressView().tint(palette.ink)
        case .confirmed:
            Label { Text(verbatim: "Confirmed") } icon: { Image(systemName: "checkmark.seal.fill") }
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(palette.ink)
        case .failed(let message):
            Text(verbatim: message)
                .font(AppFont.footnote())
                .foregroundStyle(message == WeekAheadViewModel.conflictCopy ? Color.hxWarning : Color.hxDanger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One proposed commitment: its action and target, what changed and why, a stepper and a remove toggle.
private struct WeekAheadRowView: View {
    @Binding var row: WeekAheadRow
    let palette: DeckPalette
    let isEnabled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: row.commitment.action)
                    .font(AppFont.body(weight: .semibold))
                    .strikethrough(row.removed)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: row.removed ? "Left out" : amount)
                    .font(AppFont.subheadline())
                    .monospacedDigit()
                if !row.removed, let change = row.change {
                    Text(verbatim: change)
                        .font(AppFont.footnote(weight: .medium))
                        .monospacedDigit()
                }
                if let reason = row.commitment.reason {
                    Text(verbatim: reason)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Stepper(value: $row.target, in: row.range) {
                Text(verbatim: "\(row.commitment.action) target")
            }
            .labelsHidden()
            .disabled(!isEnabled || row.removed)
            .accessibilityValue(Text(verbatim: amount))
            Button {
                row.removed.toggle()
            } label: {
                Image(systemName: row.removed ? "plus.circle" : "minus.circle")
                    .font(AppFont.title3())
                    .frame(minWidth: BrainStyle.minTapTarget, minHeight: BrainStyle.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .accessibilityLabel(Text(verbatim: row.removed ? "Add \(row.commitment.action) back" : "Remove \(row.commitment.action)"))
        }
        .padding(.vertical, 10)
    }

    /// "5 days a week" or "6 this week".
    private var amount: String {
        if row.commitment.isItem { return "\(row.target) this week" }
        return row.target == 1 ? "1 day a week" : "\(row.target) days a week"
    }
}
