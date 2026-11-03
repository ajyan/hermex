import SwiftUI

/// One-tap check-ins on a goal's hero card: today's dot on a day commitment, yesterday's while it
/// waits for one (on Monday, last week's Sunday), and + on an item commitment. Goals home wires it to
/// `GoalsHomeViewModel` (`init(slug:home:model:)`); goal detail passes its own closures.
@MainActor
struct GoalHeroCheckIn {
    /// The server's today and yesterday.
    let today: String
    let yesterday: String
    private let pending: (GoalCommitmentProgress) -> Bool
    private let onCheckIn: (GoalCommitmentProgress, GoalDay, GoalStatus) -> Void
    /// Nil leaves item rows' pips without a +.
    private let onAddOne: ((GoalCommitmentProgress) -> Void)?

    init(today: String, yesterday: String, isPending: @escaping (GoalCommitmentProgress) -> Bool,
         checkIn: @escaping (GoalCommitmentProgress, GoalDay, GoalStatus) -> Void,
         addOne: ((GoalCommitmentProgress) -> Void)?) {
        self.today = today
        self.yesterday = yesterday
        pending = isPending
        onCheckIn = checkIn
        onAddOne = addOne
    }

    /// Goals home's check-ins, through its model.
    init(slug: String, home: GoalsHome, model: GoalsHomeViewModel) {
        self.init(today: home.today, yesterday: home.yesterday,
                  isPending: { model.isPending(slug, .commitment($0.id)) },
                  checkIn: { row, day, status in
                      Task { await model.checkIn(slug: slug, commitment: row.id, status: status, day: day) }
                  },
                  addOne: { row in Task { await model.addItem(slug: slug, commitment: row.id, note: nil) } })
    }

    /// The days whose dot checks `row` in on a tap: today's while it's due or holds a check-in, and
    /// yesterday's while it waits for one (the Brief's ringed +) or holds one, so a tap there can be
    /// cleared too. Yesterday is in this week's days, or on Monday last week's Sunday. Only a day row
    /// with its seven days has dots to tap.
    nonisolated static func tappableDays(_ row: GoalCommitmentProgress, today: String, yesterday: String) -> Set<GoalDay> {
        guard !row.isItem, row.weekDays.count == 7 else { return [] }
        var days: Set<GoalDay> = []
        if row.weekDays.contains(where: { $0.date == today }), row.dueToday || row.today != nil {
            days.insert(.today)
        }
        let lastWeek = row.lastWeek?.days ?? []
        if let day = row.weekDays.first(where: { $0.date == yesterday }) ?? lastWeek.first(where: { $0.date == yesterday }) {
            let status = row.effectiveStatus(yesterday, today: today, yesterday: yesterday)
            if row.yesterday != nil || DeckRowCheckIn.liveState(status, isToday: false, deckState: day.state) == "ask" {
                days.insert(.yesterday)
            }
        }
        return days
    }

    func tappableDays(_ row: GoalCommitmentProgress) -> Set<GoalDay> {
        Self.tappableDays(row, today: today, yesterday: yesterday)
    }

    func isPending(_ row: GoalCommitmentProgress) -> Bool { pending(row) }

    func checkIn(_ row: GoalCommitmentProgress, _ day: GoalDay, _ status: GoalStatus) { onCheckIn(row, day, status) }

    var addsOne: Bool { onAddOne != nil }

    func addOne(_ row: GoalCommitmentProgress) { onAddOne?(row) }

    /// One VoiceOver action on the goal's card, for a check-in its dots offer.
    struct Action: Identifiable {
        let id: String
        let label: String
        let run: () -> Void
    }

    /// The card's check-ins as VoiceOver actions, since the card itself opens the goal.
    func actions(for goal: GoalSummary) -> [Action] {
        goal.week.commitments.flatMap { row -> [Action] in
            let name = GoalsCopy.shortName(row.action)
            if row.isItem {
                return addsOne ? [Action(id: "\(row.id)/add", label: "Add one \(name.lowercased())") { addOne(row) }] : []
            }
            let days = tappableDays(row)
            return [GoalDay.today, .yesterday].filter(days.contains).map { day in
                let word = day == .today ? "today" : "yesterday"
                let explicit = day == .today ? row.today : row.yesterday
                return explicit == nil
                    ? Action(id: "\(row.id)/\(word)", label: "\(name) done \(word)") { checkIn(row, day, .done) }
                    : Action(id: "\(row.id)/\(word)", label: "Clear \(name) \(word)") { checkIn(row, day, .clear) }
            }
        }
    }
}

/// A commitment's dots on a hero card, in the week grid's fixed columns: today's and yesterday's
/// check in where `GoalHeroCheckIn` allows. An item row's pips pack against the trailing edge
/// (`GoalDotMetrics.packedPitch`), never under the weekdays, and end on a + that counts one (`addsOne`).
/// `dates` is each dot's day, left to right. Each control is as tall as a 44 pt row; VoiceOver reaches
/// them as the card's actions.
struct GoalCheckInPipRow: View {
    let row: GoalCommitmentProgress
    let pips: GoalPips
    var dates: [String] = []
    let ink: Color
    let checkIn: GoalHeroCheckIn
    var addsOne = true
    var metrics: GoalDotMetrics = .standard

    var body: some View {
        Group {
            if row.isItem {
                let plus = addsOne && checkIn.addsOne
                let pitch = metrics.packedPitch(pips: pips.states.count, addsOne: plus)
                HStack(spacing: 0) {
                    ForEach(Array(pips.states.enumerated()), id: \.offset) { _, state in
                        DeckDot(state: state, ink: ink, column: pitch, size: metrics.dot(in: pitch))
                    }
                    if plus {
                        GoalAddOneButton(ink: ink, column: metrics.column, hitHeight: BrainStyle.minTapTarget,
                                         isPending: checkIn.isPending(row), label: "Add one \(GoalsCopy.shortName(row.action).lowercased())") {
                            checkIn.addOne(row)
                        }
                    }
                }
            } else {
                let days = checkIn.tappableDays(row)
                let column = metrics.pipColumn(pips: pips.states.count, addsOne: false)
                HStack(spacing: 0) {
                    ForEach(Array(pips.states.enumerated()), id: \.offset) { index, state in
                        if let day = tappableDay(index, in: days) {
                            dot(state, day: day, column: column)
                        } else {
                            DeckDot(state: state, ink: ink, column: column, size: metrics.dot(in: column))
                        }
                    }
                }
            }
        }
        .frame(width: metrics.trailingWidth, alignment: row.isItem ? .trailing : .leading)
        .accessibilityHidden(true)
    }

    private func tappableDay(_ index: Int, in days: Set<GoalDay>) -> GoalDay? {
        guard dates.indices.contains(index) else { return nil }
        let date = dates[index]
        if date == checkIn.today, days.contains(.today) { return .today }
        if date == checkIn.yesterday, days.contains(.yesterday) { return .yesterday }
        return nil
    }

    private func dot(_ state: String, day: GoalDay, column: CGFloat) -> some View {
        let date = day == .today ? checkIn.today : checkIn.yesterday
        let explicit = day == .today ? row.today : row.yesterday
        return GoalCheckInDot(state: state, ink: ink, column: column, size: metrics.dot(in: column), explicit: explicit,
                              tapOpensMenu: explicit == nil && row.sourceDays.contains(date),
                              hitHeight: BrainStyle.minTapTarget, isPending: checkIn.isPending(row)) { status in
            checkIn.checkIn(row, day, status)
        }
    }
}

/// A day's dot as a check-in, the Brief's way: tap for Done (or to clear the day's check-in), hold for
/// Done, 2-min, Skip, Missed and Clear. A day only its source (Prep) counted opens the menu on tap, so a
/// tap never quietly overrides it. Shared by Goals home and the Brief's front rows (`DeckRowCheckIn`).
struct GoalCheckInDot: View {
    let state: String
    let ink: Color
    var column: CGFloat = DeckDots.column
    var size: CGFloat = DeckDots.dot
    /// The day's own check-in; nil when there is none.
    let explicit: GoalStatus?
    var tapOpensMenu = false
    /// How tall the tappable area is around the dot.
    var hitHeight: CGFloat = DeckDots.dot
    let isPending: Bool
    let onSelect: (GoalStatus) -> Void

    var body: some View {
        Group {
            if tapOpensMenu {
                Menu { items } label: { label }
            } else {
                Menu { items } label: { label } primaryAction: {
                    onSelect(explicit == nil ? .done : .clear)
                }
            }
        }
        .disabled(isPending)
    }

    private var label: some View {
        DeckDot(state: state, ink: ink, column: column, size: size)
            .frame(height: hitHeight)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var items: some View {
        ForEach(GoalDetailCopy.statusOptions, id: \.value) { option in
            Button(option.label) { onSelect(GoalStatus(rawValue: option.value) ?? .done) }
        }
        if explicit != nil { Button("Clear", role: .destructive) { onSelect(.clear) } }
    }
}

/// + to count one more on an item row, in a pip column `column` wide. Shared by Goals home and the
/// Brief's counted rows.
struct GoalAddOneButton: View {
    let ink: Color
    let column: CGFloat
    var hitHeight: CGFloat = DeckDots.dot
    let isPending: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(AppFont.caption(weight: .semibold))
                // Grows with large text only as far as its column holds it.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .foregroundStyle(ink)
                .frame(width: column, height: hitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .accessibilityLabel(Text(verbatim: label))
    }
}
