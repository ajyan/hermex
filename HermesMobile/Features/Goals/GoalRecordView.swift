import SwiftUI

/// A finished goal's record, pushed as `.finishedGoal(slug)` from the Finished log.
/// `onReopened` takes over once Reopen has put the goal back among the open ones.
struct GoalRecordView: View {
    @State private var viewModel: GoalRecordViewModel
    private let onReopened: (GoalDetail) -> Void

    init(slug: String, server: URL, onAPIError: @escaping (Error) -> Void,
         onReopened: @escaping (GoalDetail) -> Void) {
        _viewModel = State(initialValue: GoalRecordViewModel(
            slug: slug, client: APIClientGoalsAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError,
            onChange: { GoalsWidgetSync.refreshAfterChange(server: server) }))
        self.onReopened = onReopened
    }

    var body: some View {
        GoalRecordContent(viewModel: viewModel, onReopened: onReopened)
            .hxNavigationTitle("Finished", subtitle: viewModel.subtitle)
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
    }
}

extension GoalRecordViewModel {
    /// "Achieved Nov 1" once loaded.
    var subtitle: String? {
        guard case .loaded(let record) = state else { return nil }
        return "Achieved \(GoalFinishCopy.shortDate(record.finished))"
    }

    /// "Reopen NYC Marathon?" once loaded: the header's More menu offers Reopen only then.
    var reopenQuestion: String? {
        guard case .loaded(let record) = state else { return nil }
        return "Reopen \(GoalsCopy.shortTitle(record.title))?"
    }
}

/// The record, top to bottom: the finisher card (who he became, the race, his first words),
/// race day and the running year (Garmin goals), the story, every day, the totals, then his
/// reflection and why. Reopen lives in the header's More menu, so the screen ends on his words.
struct GoalRecordContent: View {
    @Bindable var viewModel: GoalRecordViewModel
    let onReopened: (GoalDetail) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmingReopen = false

    var body: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label { Text(verbatim: "Record not found") } icon: { Image(systemName: "flag.checkered") }
            } description: {
                Text(verbatim: "This server has no record for this goal.")
            }
        case .failed(let message):
            PrepFailedView(title: "Couldn't load this record", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let record):
            let palette = GoalPaper.palette(named: record.color, slug: record.slug)
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.xl) {
                    if let error = viewModel.reopenError {
                        Text(verbatim: error).font(BrainStyle.meta).foregroundStyle(Color.hxDanger)
                    }
                    finisherCard(record, paper: palette.colors)
                    if let race = record.runs?.race { GoalRaceSection(race: race, paper: palette.colors) }
                    if let runs = record.runs, runs.months.count > 1 { GoalRunningYear(runs: runs, paper: palette.colors) }
                    let story = GoalRecordCopy.story(record)
                    if !story.isEmpty { GoalStorySection(record: record, story: story, ink: palette.ink) }
                    everyDay(record, tint: GoalTint(palette, scheme: colorScheme))
                    totals(record)
                    GoalReflectionSection(viewModel: viewModel, record: record, paper: palette.colors)
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { moreMenu }
            }
            .confirmationDialog(Text(verbatim: viewModel.reopenQuestion ?? ""), isPresented: $confirmingReopen,
                                titleVisibility: .visible) {
                Button(role: .destructive) {
                    Task { if let detail = await viewModel.reopen() { onReopened(detail) } }
                } label: { Text(verbatim: "Reopen Goal") }
                Button(role: .cancel) {} label: { Text(verbatim: "Cancel") }
            } message: {
                Text(verbatim: "Puts the goal back among your open goals and takes it out of Finished.")
            }
        }
    }

    /// The header's More menu: Reopen (after a confirmation that names what it undoes).
    @ViewBuilder
    private var moreMenu: some View {
        if viewModel.isReopening {
            ProgressView().accessibilityLabel(Text(verbatim: "Reopening"))
        } else if viewModel.reopenQuestion != nil {
            Menu {
                Button(role: .destructive) { confirmingReopen = true } label: {
                    Label { Text(verbatim: "Reopen Goal") } icon: { Image(systemName: "arrow.uturn.backward") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(Text(verbatim: "More"))
        }
    }

    /// Who he became, the race (else how he showed up), and the first sentence of his reflection.
    private func finisherCard(_ r: GoalRecord, paper: HermexPaper) -> some View {
        HXCard(.glow(paper), title: GoalFinishCopy.identityTitle(r), titleStyle: .title, spacing: BrainStyle.s) {
            HStack {
                Text(verbatim: "Achieved · \(GoalFinishCopy.range(r))").font(BrainStyle.meta)
                Spacer(minLength: 0)
                Image(systemName: "medal.fill").foregroundStyle(HermexPaper.opener.glow).accessibilityHidden(true)
            }
            .foregroundStyle(paper.glow)
        } content: {
            Text(verbatim: GoalRecordCopy.finisherLine(r))
                .font(AppFont.display(style: .subheadline, weight: .medium))
                .foregroundStyle(Color.hxTextPrimary)
            if let lead = GoalRecordCopy.firstSentence(r.reflection) {
                Text(verbatim: lead)
                    .font(AppFont.serif())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, BrainStyle.xs)
            }
        } footer: { EmptyView() }
    }

    private func everyDay(_ r: GoalRecord, tint: GoalTint) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Every day", trailing: "\(r.shown) of \(r.days)")
            SectionCard {
                VStack(alignment: .leading, spacing: BrainStyle.m) {
                    GoalCalendarGrid(
                        calendar: GoalCalendarModel(heatmap: r.heatmap, today: r.finished, deadline: r.finished),
                        tint: tint
                    )
                    Text(verbatim: GoalRecordCopy.daysLine(r)).brainText(.meta)
                }
                .padding(.vertical, BrainStyle.xs)
            }
        }
    }

    @ViewBuilder
    private func totals(_ r: GoalRecord) -> some View {
        let rows = GoalRecordCopy.totals(r)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "What you did")
                SectionCard {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { offset, row in
                            if offset > 0 { PrepRowDivider() }
                            HStack(alignment: .firstTextBaseline) {
                                Text(verbatim: row.label).brainText(.rowTitle)
                                Spacer(minLength: BrainStyle.s)
                                Text(verbatim: row.value).brainText(.meta).monospacedDigit()
                            }
                            .padding(.vertical, BrainStyle.s)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
    }
}

/// The race from Garmin: pace per mile (faster miles stand taller), then one line of pace,
/// heart rate, fastest mile and the halves.
private struct GoalRaceSection: View {
    let race: GoalRace
    let paper: HermexPaper

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Race day", trailing: GoalFinishCopy.longDate(race.date))
            SectionCard {
                VStack(alignment: .leading, spacing: BrainStyle.m) {
                    if race.splits.count > 1 { splits }
                    Text(verbatim: GoalRecordCopy.raceDayLine(race)).brainText(.meta)
                }
                .padding(.vertical, BrainStyle.s)
            }
        }
    }

    private var splits: some View {
        let slowest = race.splits.max() ?? 1, fastest = race.splits.min() ?? 0
        let range = Double(max(1, slowest - fastest))
        return VStack(alignment: .leading, spacing: BrainStyle.xs) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(race.splits.enumerated()), id: \.offset) { _, pace in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)  // design-drift: allow (26 thin chart bars)
                        .fill(pace == fastest ? paper.glow : paper.glow.opacity(0.45))
                        .frame(maxWidth: .infinity)
                        .frame(height: 16 + 48 * Double(slowest - pace) / range)
                }
            }
            .frame(height: 64, alignment: .bottom)
            HStack {
                Text(verbatim: "Mile 1")
                Spacer()
                Text(verbatim: GoalRecordCopy.splitsEnd(race))
            }
            .font(AppFont.caption2())
            .foregroundStyle(Color.hxTextSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: GoalRecordCopy.splitsSummary(race)))
    }
}

/// Every run this year as month dots: full for the biggest months, half for the middle, a ring
/// for the light ones (the monthly review's dots), with the month's letter under each.
private struct GoalRunningYear: View {
    let runs: GoalRuns
    let paper: HermexPaper

    var body: some View {
        let top = runs.months.map(\.miles).max() ?? 0
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Your running year", trailing: "\(GoalFinishCopy.miles(runs.miles)) mi")
            SectionCard {
                VStack(alignment: .leading, spacing: BrainStyle.m) {
                    HStack(spacing: 0) {
                        ForEach(runs.months, id: \.month) { m in
                            VStack(spacing: BrainStyle.xs) {
                                DeckDot(state: GoalMonthLevel(miles: m.miles, top: top).dotState, ink: paper.glow,
                                        column: DeckDots.dot)
                                Text(verbatim: String(GoalFinishCopy.month(m.month).prefix(1)))
                                    .font(AppFont.caption2(weight: .semibold))
                                    .foregroundStyle(Color.hxTextSecondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: GoalRecordCopy.yearSummary(runs)))
                    if top > 0 { legend(top) }
                    Text(verbatim: GoalRecordCopy.yearLine(runs)).brainText(.meta)
                }
                .padding(.vertical, BrainStyle.s)
            }
        }
    }

    private func legend(_ top: Double) -> some View {
        HStack(spacing: BrainStyle.m) {
            ForEach(GoalMonthLevel.legend(top: top), id: \.label) { item in
                HStack(spacing: BrainStyle.xs) {
                    DeckDot(state: item.level.dotState, ink: paper.glow, column: DeckDots.dot)
                        .scaleEffect(0.6)
                        .frame(width: DeckDots.dot * 0.6, height: DeckDots.dot * 0.6)
                    Text(verbatim: item.label)
                }
            }
        }
        .font(AppFont.caption(weight: .medium))
        .foregroundStyle(Color.hxTextSecondary)
        .accessibilityHidden(true)
    }
}

/// A month's miles against the biggest month: full from two thirds of it, half from a third,
/// a ring below that, and a faint ring for a month with no miles.
enum GoalMonthLevel: Equatable {
    case full, half, ring, none

    init(miles: Double, top: Double) {
        guard miles > 0, top > 0 else { self = .none; return }
        let share = miles / top
        self = share >= 2.0 / 3 ? .full : share >= 1.0 / 3 ? .half : .ring
    }

    /// The `DeckDot` look: filled, half-strength, a ring, a faint ring.
    var dotState: String {
        switch self {
        case .full: "done"
        case .half: "skip"
        case .ring: "today"
        case .none: "missed"
        }
    }

    /// "50+ mi", "25+", "under 25" for a 75 mi top month.
    static func legend(top: Double) -> [(level: GoalMonthLevel, label: String)] {
        let full = Int((top * 2 / 3).rounded()), half = Int((top / 3).rounded())
        return [(.full, "\(full)+ mi"), (.half, "\(half)+"), (.ring, "under \(half)")]
    }
}

/// The story: moments from setting the goal to the finish, on a dotted line.
private struct GoalStorySection: View {
    let record: GoalRecord
    let story: [GoalStoryMoment]
    let ink: Color

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "The story", trailing: record.days == 1 ? "1 day" : "\(record.days) days")
            SectionCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(story.enumerated()), id: \.offset) { offset, moment in
                        row(moment, isLast: offset == story.count - 1)
                    }
                }
                .padding(.vertical, BrainStyle.s)
            }
        }
    }

    private func row(_ m: GoalStoryMoment, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: BrainStyle.m) {
            VStack(spacing: 0) {
                Circle()
                    .fill(m.major ? ink : Color.clear)
                    .overlay(Circle().strokeBorder(ink, lineWidth: 2))
                    .frame(width: 12, height: 12)
                    .padding(.top, 4)
                if !isLast {
                    Rectangle().fill(ink.opacity(0.25)).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: GoalFinishCopy.shortDate(m.date))
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(ink)
                Text(verbatim: m.title).brainText(.rowTitle)
                if !m.detail.isEmpty { Text(verbatim: m.detail).brainText(.meta) }
            }
            .padding(.bottom, isLast ? 0 : BrainStyle.m)
        }
        .accessibilityElement(children: .combine)
    }
}

/// His why, then his reflection, which he can write, change or clear here.
private struct GoalReflectionSection: View {
    @Bindable var viewModel: GoalRecordViewModel
    let record: GoalRecord
    let paper: HermexPaper

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HXCard(.glow(paper), spacing: BrainStyle.s) {
            Text(verbatim: "Your reflection").font(AppFont.caption(weight: .semibold)).foregroundStyle(paper.glow)
        } content: {
            if editing {
                TextField(text: $draft, prompt: Text(verbatim: "What did it take?"), axis: .vertical) {
                    Text(verbatim: "Your reflection")
                }
                .font(AppFont.serif())
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(3...10)
                .focused($focused)
            } else if record.reflection.isEmpty {
                Text(verbatim: "What did it take? A few words here stay with the record.")
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxTextPrimary)
            } else {
                Text(verbatim: record.reflection).font(AppFont.serif()).foregroundStyle(Color.hxTextPrimary)
            }
            if !record.why.isEmpty {
                Text(verbatim: "Why: \(record.why)")
                    .font(AppFont.serif(style: .footnote))
                    .foregroundStyle(Color.hxTextPrimary)
                    .padding(.top, BrainStyle.xs)
            }
            if let error = viewModel.error {
                Text(verbatim: error).font(BrainStyle.meta).foregroundStyle(Color.hxWarning)
            }
        } footer: {
            HStack(spacing: BrainStyle.s) {
                if editing {
                    Button { editing = false } label: { Text(verbatim: "Cancel") }
                        .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
                    Button {
                        Task { if await viewModel.saveReflection(draft) { editing = false } }
                    } label: {
                        if viewModel.isSaving { ProgressView() } else { Text(verbatim: "Save") }
                    }
                    .buttonStyle(ChatDecisionButtonStyle(emphasis: .primary))
                    .disabled(viewModel.isSaving)
                } else {
                    Button {
                        draft = record.reflection
                        editing = true
                        focused = true
                    } label: {
                        Text(verbatim: record.reflection.isEmpty ? "Write a reflection" : "Edit")
                    }
                    .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
                }
            }
            .padding(.top, BrainStyle.xs)
        }
        .environment(\.hxPaper, paper)
    }
}

enum GoalRecordCopy {
    /// Under the calendar, counted honestly: "1 day not logged · 0 of 4 skips used", or
    /// "Showed up every day". A day with no check-in is "not logged", never "no missed days".
    static func daysLine(_ r: GoalRecord) -> String {
        var parts: [String] = []
        if r.missDays > 0 { parts.append(r.missDays == 1 ? "1 missed day" : "\(r.missDays) missed days") }
        let unlogged = r.unloggedDays
        if unlogged > 0 { parts.append(unlogged == 1 ? "1 day not logged" : "\(unlogged) days not logged") }
        if r.minDays > 0 { parts.append(r.minDays == 1 ? "1 minimum day" : "\(r.minDays) minimum days") }
        if r.skipsBudget > 0 || r.skipsUsed > 0 { parts.append("\(r.skipsUsed) of \(r.skipsBudget) skips used") }
        if r.days > 0, r.shown == r.days { parts.insert("Showed up every day", at: 0) }
        return parts.joined(separator: " · ")
    }

    /// The finisher card's one line: the race ("26.6 mi in 5:13:34"), else how he showed up
    /// ("Showed up 20 of 23 days · 3 of 3 weeks hit").
    static func finisherLine(_ r: GoalRecord) -> String {
        if let race = r.runs?.race { return GoalFinishCopy.raceLine(race) }
        return GoalFinishCopy.showedUpLine(r)
    }

    /// The first sentence (or line) of his words, for the finisher card; nil when he wrote none.
    static func firstSentence(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let line = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        var end = line.endIndex
        for mark in [". ", "! ", "? "] {
            if let r = line.range(of: mark), r.lowerBound < end { end = r.lowerBound }
        }
        return end == line.endIndex ? line : String(line[...end])
    }

    /// Race day in one line: "11:47/mi · 165 bpm avg · fastest mile 10:38 · second half 19:39 slower".
    static func raceDayLine(_ race: GoalRace) -> String {
        var parts = ["\(GoalFinishCopy.pace(race.paceSeconds))/mi"]
        if let hr = race.avgHR { parts.append("\(hr) bpm avg") }
        if let fastest = race.fastestMileSeconds { parts.append("fastest mile \(GoalFinishCopy.pace(fastest))") }
        if let halves = race.halvesSeconds { parts.append(GoalFinishCopy.halvesLine(halves)) }
        return parts.joined(separator: " · ")
    }

    /// The splits chart's right end: "Mile 26 of 26.6" when the race ran past its last full mile.
    static func splitsEnd(_ race: GoalRace) -> String {
        let n = race.splits.count
        if race.miles > Double(n) + 0.05 { return "Mile \(n) of \(GoalFinishCopy.miles(race.miles))" }
        if race.miles > 0, Double(n) > race.miles + 0.05 { return "\(GoalFinishCopy.miles(race.miles)) mi" }
        return "Mile \(n)"
    }

    /// The story without its streak line: the all-goals streak lives on Goals home, and this
    /// goal's days are counted under its calendar.
    static func story(_ r: GoalRecord) -> [GoalStoryMoment] {
        guard let streak = r.streak else { return r.story }
        return r.story.filter { m in
            !(!m.major && m.date == streak.start && m.title.hasSuffix("-day streak"))
        }
    }

    /// Each commitment's total, each daily check's answers, and the milestones on time.
    static func totals(_ r: GoalRecord) -> [(label: String, value: String)] {
        var rows: [(String, String)] = []
        for c in r.commitments where c.total > 0 {
            let value = c.unit == "item" ? "\(c.total)" : (c.total == 1 ? "1 day" : "\(c.total) days")
            rows.append((GoalsCopy.shortTitle(c.action), value))
        }
        for k in r.checks where k.counts.contains(where: { $0.count > 0 }) {
            rows.append((GoalDetailCopy.checkTitle(k.question),
                         k.counts.map { "\($0.count) \($0.value)" }.joined(separator: " · ")))
        }
        if !r.milestones.isEmpty {
            let onTime = r.milestones.filter(\.onTime).count
            rows.append(("Milestones", "\(onTime) of \(r.milestones.count) on time"))
        }
        return rows
    }

    /// "25 runs · 41 h 42 m since Apr 24 · PRs Aug 22, Oct 10".
    static func yearLine(_ runs: GoalRuns) -> String {
        var line = "\(runs.count) runs · \(GoalFinishCopy.hours(runs.seconds)) since \(GoalFinishCopy.shortDate(runs.first))"
        if !runs.prs.isEmpty {
            line += " · PR\(runs.prs.count == 1 ? "" : "s") \(runs.prs.map(GoalFinishCopy.shortDate).joined(separator: ", "))"
        }
        return line
    }

    static func yearSummary(_ runs: GoalRuns) -> String {
        let months = runs.months.map { "\(GoalFinishCopy.month($0.month)) \(GoalFinishCopy.miles($0.miles)) miles" }
        return "Miles a month: " + months.joined(separator: ", ")
    }

    static func splitsSummary(_ race: GoalRace) -> String {
        let fastest = race.splits.firstIndex(of: race.fastestMileSeconds ?? -1).map { " Fastest was mile \($0 + 1)." } ?? ""
        return "Pace per mile over \(race.splits.count) miles.\(fastest)"
    }
}
