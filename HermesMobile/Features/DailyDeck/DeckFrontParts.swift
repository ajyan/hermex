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

    var id: String { [goal, commitment, label].compactMap { $0 }.joined(separator: "/") }

    private enum CodingKeys: String, CodingKey { case label, kind, days, done, target, goal, commitment }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        kind = Kind(rawValue: (try? c.decode(String.self, forKey: .kind)) ?? "") ?? .days
        days = ((try? c.decodeIfPresent([Lossy<DeckDay>].self, forKey: .days)) ?? []).compactMap(\.value)
        done = (try? c.decodeIfPresent(Int.self, forKey: .done)) ?? 0
        target = (try? c.decodeIfPresent(Int.self, forKey: .target)) ?? 0
        goal = (try? c.decodeIfPresent(String.self, forKey: .goal)).flatMap { $0.isEmpty ? nil : $0 }
        commitment = (try? c.decodeIfPresent(String.self, forKey: .commitment)).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// One day of a front row: `done`, `today` (not yet), `ahead`, `missed`, `skip`, or `off` (not due).
struct DeckDay: Decodable, Equatable {
    let date: String
    let state: String
}

/// The headline's pick from yesterday's close card.
struct DeckYesterdayOne: Decodable, Equatable {
    let label: String
    let front: String?
}

/// The dot grid every front row shares, so day dots and pips line up in the same columns: one fixed
/// column per day (or pip), the dot centered in it, and every row starting at the same leading edge.
enum DeckDots {
    static let column: CGFloat = 26
    static let dot: CGFloat = 16
    static let weekdays = ["M", "T", "W", "T", "F", "S", "S"]
}

/// One dot. `ink` is the card's ink; a done day is filled, today ringed, a missed day a faint ring,
/// a skipped day half-filled, a day ahead dashed, a day it isn't due a small mark.
struct DeckDot: View {
    let state: String
    let ink: Color

    var body: some View {
        ZStack {
            switch state {
            case "done":
                Circle().fill(ink)
            case "skip":
                Circle().fill(ink.opacity(0.35))
            case "today":
                Circle().strokeBorder(ink, lineWidth: 1.75)
            case "ahead":
                Circle().strokeBorder(ink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            case "off":
                Circle().fill(ink.opacity(0.2)).frame(width: 4, height: 4)
            default:  // missed
                Circle().strokeBorder(ink.opacity(0.35), lineWidth: 1)
            }
        }
        .frame(width: DeckDots.dot, height: DeckDots.dot)
        .frame(width: DeckDots.column)
    }
}

/// A front row: its label and a quiet count over the dots. A goal commitment's yesterday dot checks in
/// live (tap for Done, hold for the 2-minute version, Skip or Missed), and a counted row's next pip adds
/// one; both only on today's deck, through the goal card's model.
struct DeckFrontRowView: View {
    let row: DeckFrontRow
    let palette: DeckPalette
    let deckDate: String

    @Environment(GoalCheckInCardViewModel.self) private var model: GoalCheckInCardViewModel?

    var body: some View {
        let live = liveCommitment
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: row.label)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: countText(live))
                    .font(AppFont.caption())
                    .foregroundStyle(Color.hxTextSecondary)
                    .monospacedDigit()
            }
            switch row.kind {
            case .days: days(live)
            case .pips: pips(live)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Live goal state

    /// The goal commitment as the server has it now, on today's deck; nil otherwise.
    private var liveCommitment: (slug: String, row: GoalCommitmentProgress, home: GoalsHome)? {
        guard let model, model.isLive(for: deckDate), case .loaded(let home) = model.state,
              let slug = row.goal, let id = row.commitment,
              let goal = home.goals.first(where: { $0.slug == slug }),
              let commitment = goal.week.commitments.first(where: { $0.id == id })
        else { return nil }
        return (slug, commitment, home)
    }

    private func countText(_ live: (slug: String, row: GoalCommitmentProgress, home: GoalsHome)?) -> String {
        let done = live.map { $0.row.done + $0.row.min } ?? row.done
        return row.target > 0 ? "\(done) of \(row.target)" : "\(done) this week"
    }

    private func state(_ day: DeckDay, _ live: (slug: String, row: GoalCommitmentProgress, home: GoalsHome)?) -> String {
        guard let live, day.date == live.home.yesterday || day.date == live.home.today else { return day.state }
        let status = live.row.effectiveStatus(day.date, today: live.home.today, yesterday: live.home.yesterday)
        switch status {
        case .done, .min: return "done"
        case .skip: return "skip"
        case .miss: return "missed"
        default: return day.date == live.home.today ? "today" : (day.state == "off" ? "off" : "missed")
        }
    }

    // MARK: Day dots

    private func days(_ live: (slug: String, row: GoalCommitmentProgress, home: GoalsHome)?) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(row.days.prefix(7).enumerated()), id: \.offset) { index, day in
                VStack(spacing: 3) {
                    dayDot(day, live)
                    Text(verbatim: DeckDots.weekdays[index])
                        .font(AppFont.caption2())
                        .foregroundStyle(Color.hxTextSecondary)
                        .frame(width: DeckDots.column)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spokenWeek(live)))
        .accessibilityActions { yesterdayActions(live) }
    }

    @ViewBuilder
    private func dayDot(_ day: DeckDay, _ live: (slug: String, row: GoalCommitmentProgress, home: GoalsHome)?) -> some View {
        let shown = state(day, live)
        if let live, day.date == live.home.yesterday {
            let key = GoalCheckInCardViewModel.key(live.slug, live.row.id)
            let explicit = live.row.yesterday
            Menu {
                ForEach(GoalDetailCopy.statusOptions, id: \.value) { option in
                    Button(option.label) { checkIn(live, GoalStatus(rawValue: option.value) ?? .done) }
                }
                if explicit != nil { Button("Clear", role: .destructive) { checkIn(live, .clear) } }
            } label: {
                DeckDot(state: shown, ink: palette.ink)
                    .contentShape(Rectangle())
            } primaryAction: {
                checkIn(live, explicit == nil ? .done : .clear)
            }
            .disabled(model?.pending.contains(key) == true)
        } else {
            DeckDot(state: shown, ink: palette.ink)
        }
    }

    private func checkIn(_ live: (slug: String, row: GoalCommitmentProgress, home: GoalsHome), _ status: GoalStatus) {
        guard let model else { return }
        Task { await model.checkIn(slug: live.slug, commitment: live.row.id, status: status) }
    }

    @ViewBuilder
    private func yesterdayActions(_ live: (slug: String, row: GoalCommitmentProgress, home: GoalsHome)?) -> some View {
        if let live {
            Button(live.row.yesterday == nil ? "Mark yesterday done" : "Clear yesterday") {
                checkIn(live, live.row.yesterday == nil ? .done : .clear)
            }
        }
    }

    private func spokenWeek(_ live: (slug: String, row: GoalCommitmentProgress, home: GoalsHome)?) -> String {
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        let done = row.days.prefix(7).enumerated().filter { state($0.element, live) == "done" }.map { names[$0.offset] }
        let head = "\(row.label), \(countText(live)) this week"
        return done.isEmpty ? "\(head), none yet" : "\(head), done \(done.joined(separator: ", "))"
    }

    // MARK: Pips

    private func pips(_ live: (slug: String, row: GoalCommitmentProgress, home: GoalsHome)?) -> some View {
        let done = live.map { $0.row.done } ?? row.done
        let count = max(row.target, done)
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                DeckDot(state: index < done ? "done" : "missed", ink: palette.ink)
            }
            if let live {
                let key = GoalCheckInCardViewModel.key(live.slug, live.row.id)
                Button {
                    guard let model else { return }
                    Task { await model.addItem(slug: live.slug, commitment: live.row.id, note: nil) }
                } label: {
                    Image(systemName: "plus")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .frame(width: DeckDots.column, height: DeckDots.dot)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model?.pending.contains(key) == true)
                .accessibilityLabel(Text(verbatim: "Add one \(row.label.lowercased())"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(row.label), \(done) of \(row.target) this week"))
    }
}

/// The rows and the one thing today a front divider (and the week's divider) ends on.
struct DeckFrontWeek: View {
    let card: DeckCard
    let palette: DeckPalette
    let deckDate: String

    var body: some View {
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
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { viewModel.pick(option.id, for: card) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isPicked ? "checkmark.circle.fill" : front.symbol)
                            .font(AppFont.body())
                            .foregroundStyle(isPicked ? palette.ink : Color.hxTextSecondary)
                            .frame(width: 24)
                        Text(verbatim: option.label)
                            .font(AppFont.body(weight: isPicked ? .semibold : .regular))
                            .foregroundStyle(Color.hxTextPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(verbatim: front.shortName)
                            .font(AppFont.caption())
                            .foregroundStyle(Color.hxTextSecondary)
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
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { viewModel.pick(option.id, for: card) }
                    }
                }
            }
        }
    }
}
