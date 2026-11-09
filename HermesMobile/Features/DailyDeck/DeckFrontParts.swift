import SwiftUI

/// One row of a front's week on its divider (the vault's `deck_fronts.front_rows`): a daily commitment as its
/// Monday–Sunday day states, or a counted one (outreach, applications) as `done` of `target` pips. `goal` and
/// `commitment` name a goal commitment, which checks in live from the divider.
struct DeckFrontRow: Decodable, Equatable, Identifiable {
    enum Kind: String { case days, pips }

    let label: String
    let kind: Kind
    let days: [DeckDay]
    let done: Int
    let target: Int
    let goal: String?
    let commitment: String?
    /// In a deck by job's close, the front the row serves ("ai") and its name ("Landing the AI role").
    let front: String?
    let frontName: String?
    /// The habit's paper by name ("notes"), when the vault says; `habitPaper` works one out otherwise.
    let paper: String?

    var id: String { [goal, commitment, label].compactMap { $0 }.joined(separator: "/") }

    /// The paper the habit's dots wear on the close's tracker, so color means the kind of habit: the vault's
    /// when it names one, else Sleep's and Mandarin's own, else its front's (the job search wears Prep's,
    /// a letter to her the Dad card's, lifting Body's, people the person paper).
    var habitPaper: HermexPaper {
        if let named = HermexPaper.named(paper) { return named }
        let name = label.lowercased()
        if name.contains("sleep") { return DeckPalette.sleep.colors }
        if name.contains("mandarin") { return DeckPalette.mandarin.colors }
        switch front {
        case "ai": return .prep
        case "fatherhood": return DeckPalette.letter.colors
        case "living-well": return .training
        case "relationships": return BrainModuleID.people.paper
        default: return .plain
        }
    }

    private enum CodingKeys: String, CodingKey { case label, kind, days, done, target, goal, commitment, front, frontName, paper }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        kind = Kind(rawValue: (try? c.decode(String.self, forKey: .kind)) ?? "") ?? .days
        days = ((try? c.decodeIfPresent([Lossy<DeckDay>].self, forKey: .days)) ?? []).compactMap(\.value)
        done = (try? c.decodeIfPresent(Int.self, forKey: .done)) ?? 0
        target = (try? c.decodeIfPresent(Int.self, forKey: .target)) ?? 0
        goal = (try? c.decodeIfPresent(String.self, forKey: .goal)).flatMap { $0.isEmpty ? nil : $0 }
        commitment = (try? c.decodeIfPresent(String.self, forKey: .commitment)).flatMap { $0.isEmpty ? nil : $0 }
        front = (try? c.decodeIfPresent(String.self, forKey: .front)).flatMap { $0.isEmpty ? nil : $0 }
        frontName = (try? c.decodeIfPresent(String.self, forKey: .frontName)).flatMap { $0.isEmpty ? nil : $0 }
        paper = (try? c.decodeIfPresent(String.self, forKey: .paper)).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// One day of a front row: `done`, `today` (not yet), `ask` (yesterday, not checked in yet), `ahead`, `missed`,
/// `skip`, or `off` (not due).
struct DeckDay: Decodable, Hashable, Sendable {
    let date: String
    let state: String
}

/// The headline's pick from yesterday's close card.
struct DeckYesterdayOne: Decodable, Equatable {
    let label: String
    let front: String?
}

/// A front row: its label and a quiet count over the dots. A goal commitment's yesterday dot checks in
/// live (tap for Done, hold for the 2-minute version, Skip or Missed), and a counted row's next pip adds
/// one; both only on today's deck, through the goal card's model (`DeckRowCheckIn`).
struct DeckFrontRowView: View {
    let row: DeckFrontRow
    let palette: DeckPalette
    let deckDate: String

    @Environment(GoalsHomeViewModel.self) private var model: GoalsHomeViewModel?

    var body: some View {
        let checkIn = DeckRowCheckIn(row: row, ink: palette.ink, deckDate: deckDate, model: model)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: row.label)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: checkIn.countText)
                    .font(AppFont.caption())
                    .foregroundStyle(palette.ink)
                    .monospacedDigit()
            }
            switch row.kind {
            case .days: days(checkIn)
            case .pips: pips(checkIn)
            }
        }
        .accessibilityElement(children: .contain)
    }

    static func liveState(_ status: GoalStatus?, isToday: Bool, deckState: String) -> String {
        DeckRowCheckIn.liveState(status, isToday: isToday, deckState: deckState)
    }

    private func days(_ checkIn: DeckRowCheckIn) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(row.days.prefix(7).enumerated()), id: \.offset) { index, day in
                VStack(spacing: 3) {
                    checkIn.dot(day)
                    Text(verbatim: DeckDots.weekdays[index])
                        .font(AppFont.caption2())
                        .foregroundStyle(palette.ink)
                        .frame(width: DeckDots.column)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: checkIn.spokenWeek))
        .accessibilityActions { checkIn.yesterdayActions }
    }

    private func pips(_ checkIn: DeckRowCheckIn) -> some View {
        let done = checkIn.pipsDone
        return HStack(spacing: 0) {
            ForEach(0..<max(row.target, done), id: \.self) { index in
                DeckDot(state: index < done ? "done" : "missed", ink: palette.ink)
            }
            checkIn.addButton()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: checkIn.spokenCount))
    }
}

/// A front row's live check-in on today's deck, shared by a divider's row (`DeckFrontRowView`) and the
/// close's week grid (`DeckWeekGrid`): the row's dots as the server has them now, today's and yesterday's dots
/// as check-ins (tap for Done, hold for the 2-minute version, Skip or Missed), and + to add one to a count.
/// Off today's deck, or without the goal card's model, it shows the deck's own states and checks nothing in.
@MainActor
struct DeckRowCheckIn {
    typealias Live = (slug: String, row: GoalCommitmentProgress, home: GoalsHome)

    let row: DeckFrontRow
    let ink: Color
    let model: GoalsHomeViewModel?
    /// The goal commitment as the server has it now, on today's deck; nil otherwise.
    let live: Live?

    /// How tall a check-in dot's tappable area is.
    var hitHeight: CGFloat = DeckDots.dot

    init(row: DeckFrontRow, ink: Color, deckDate: String, model: GoalsHomeViewModel?, hitHeight: CGFloat = DeckDots.dot) {
        self.row = row
        self.ink = ink
        self.model = model
        self.hitHeight = hitHeight
        live = Self.live(row: row, deckDate: deckDate, model: model)
    }

    private static func live(row: DeckFrontRow, deckDate: String, model: GoalsHomeViewModel?) -> Live? {
        guard let model, model.isLive(for: deckDate), case .loaded(let home) = model.state,
              let slug = row.goal, let id = row.commitment,
              let goal = home.goals.first(where: { $0.slug == slug }),
              let commitment = goal.week.commitments.first(where: { $0.id == id })
        else { return nil }
        return (slug, commitment, home)
    }

    /// How many are done this week, the 2-minute versions included.
    var done: Int { live.map { $0.row.done + $0.row.min } ?? row.done }

    /// "3 of 6", or "2 this week" when the row has no target.
    var countText: String { row.target > 0 ? "\(done) of \(row.target)" : "\(done) this week" }

    /// The grid's count column: "3 of 6", or "2" when the row has no target.
    var shortCountText: String { row.target > 0 ? "\(done) of \(row.target)" : "\(done)" }

    func state(_ day: DeckDay) -> String {
        guard let live, day.date == live.home.yesterday || day.date == live.home.today else { return day.state }
        let status = live.row.effectiveStatus(day.date, today: live.home.today, yesterday: live.home.yesterday)
        return Self.liveState(status, isToday: day.date == live.home.today, deckState: day.state)
    }

    /// Today's or yesterday's dot from the server's check-in: yesterday with none is still `ask` (he logs last
    /// night the next morning), never missed until he says so.
    nonisolated static func liveState(_ status: GoalStatus?, isToday: Bool, deckState: String) -> String {
        switch status {
        case .done, .min: return "done"
        case .skip: return "skip"
        case .miss: return "missed"
        default: return isToday ? "today" : (deckState == "off" ? "off" : "ask")
        }
    }

    // MARK: Day dots

    /// The day a dot logs, when it can: today or yesterday on a live row; nil for any other dot.
    nonisolated static func loggedDay(_ date: String, today: String, yesterday: String) -> GoalDay? {
        date == today ? .today : date == yesterday ? .yesterday : nil
    }

    /// One day's dot, in a fixed column; today's and yesterday's check in when the row is live.
    @ViewBuilder
    func dot(_ day: DeckDay) -> some View {
        let shown = state(day)
        if let live, let logged = Self.loggedDay(day.date, today: live.home.today, yesterday: live.home.yesterday) {
            let key = GoalsHomeViewModel.key(live.slug, .commitment(live.row.id))
            GoalCheckInDot(state: shown, ink: ink, explicit: logged == .today ? live.row.today : live.row.yesterday,
                           hitHeight: hitHeight, isPending: model?.pending.contains(key) == true) { checkIn(live, $0, logged) }
        } else {
            DeckDot(state: shown, ink: ink)
        }
    }

    private func checkIn(_ live: Live, _ status: GoalStatus, _ day: GoalDay = .yesterday) {
        guard let model else { return }
        Task { await model.checkIn(slug: live.slug, commitment: live.row.id, status: status, day: day) }
    }

    /// The row's VoiceOver action for yesterday's check-in.
    @ViewBuilder
    var yesterdayActions: some View {
        if let live {
            Button(live.row.today == nil ? "Mark today done" : "Clear today") {
                checkIn(live, live.row.today == nil ? .done : .clear, .today)
            }
            Button(live.row.yesterday == nil ? "Mark yesterday done" : "Clear yesterday") {
                checkIn(live, live.row.yesterday == nil ? .done : .clear)
            }
        }
    }

    var spokenWeek: String {
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        let done = row.days.prefix(7).enumerated().filter { state($0.element) == "done" }.map { names[$0.offset] }
        let head = "\(row.label), \(countText) this week"
        let week = done.isEmpty ? "\(head), none yet" : "\(head), done \(done.joined(separator: ", "))"
        let asking = row.days.prefix(7).contains { state($0) == "ask" }
        return asking ? "\(week), yesterday not logged yet" : week
    }

    // MARK: Pips

    /// A counted row's pips filled so far (the 2-minute versions don't count here).
    var pipsDone: Int { live.map { $0.row.done } ?? row.done }

    var spokenCount: String { "\(row.label), \(pipsDone) of \(row.target) this week" }

    /// + to add one to a counted row, in a dot column `column` wide; nothing when the row isn't live.
    @ViewBuilder
    func addButton(column: CGFloat = DeckDots.column) -> some View {
        if let live {
            let key = GoalsHomeViewModel.key(live.slug, .commitment(live.row.id))
            GoalAddOneButton(ink: ink, column: column, isPending: model?.pending.contains(key) == true,
                             label: "Add one \(row.label.lowercased())") {
                guard let model else { return }
                Task { await model.addItem(slug: live.slug, commitment: live.row.id, note: nil) }
            }
        }
    }
}

/// The rows and the one thing today a front divider (and the week's divider) ends on.
struct DeckFrontWeek: View {
    let card: DeckCard
    let palette: DeckPalette
    let deckDate: String

    @Environment(GoalsHomeViewModel.self) private var model: GoalsHomeViewModel?

    var body: some View {
        // One stack, so the landing haptic plays once rather than once per part.
        VStack(alignment: .leading, spacing: 0) { parts }
            .sensoryFeedback(.success, trigger: model?.landedCheckIns ?? 0)
    }

    @ViewBuilder
    private var parts: some View {
        if !card.weekRows.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(card.weekRows) { row in
                    DeckFrontRowView(row: row, palette: palette, deckDate: deckDate)
                }
            }
            .padding(.top, 22)
        }
        if let today = card.todayAction {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Today")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink)
                Text(verbatim: today)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 18)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The close card's three actions for today, as rows with their front: tap one to make it today's one thing.
struct DeckTodaysOne: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let picked = viewModel.answer(for: card)?.action
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: card.question ?? "Your one thing today")
                .font(AppFont.subheadline(weight: .semibold))
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(card.options) { option in
                let front = DeckPalette.front(option.front)
                let isPicked = picked == option.id
                Button {
                    withAnimation(HXMotion.quickState(reduceMotion: reduceMotion)) { viewModel.pick(option.id, for: card) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isPicked ? "checkmark.circle.fill" : front.symbol)
                            .font(AppFont.body())
                            .foregroundStyle(palette.ink)
                            .frame(width: 24)
                        Text(verbatim: option.label)
                            .font(AppFont.body(weight: isPicked ? .semibold : .regular))
                            .foregroundStyle(Color.hxTextPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(verbatim: front.shortName)
                            .font(AppFont.caption())
                            .foregroundStyle(palette.ink)
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { Rectangle().fill(palette.ink.opacity(0.12)).frame(height: 0.5) }
                .accessibilityLabel(Text(verbatim: "\(option.label), \(front.name)"))
                .accessibilityAddTraits(isPicked ? .isSelected : [])
            }
        }
    }
}

/// The opener's line for yesterday's one thing, with Done, Partly and Not today.
struct DeckYesterdayLine: View {
    let card: DeckCard
    let one: DeckYesterdayOne
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let picked = viewModel.answer(for: card)?.action
        VStack(alignment: .leading, spacing: 10) {
            (Text(verbatim: "Yesterday's one · ").font(AppFont.display(style: .subheadline, weight: .semibold))
                + Text(verbatim: one.label).font(AppFont.subheadline()).foregroundStyle(Color.hxTextPrimary))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(card.options) { option in
                    ChoiceButton(title: option.label, isSelected: picked == option.id) {
                        withAnimation(HXMotion.quickState(reduceMotion: reduceMotion)) { viewModel.pick(option.id, for: card) }
                    }
                }
            }
        }
    }
}
