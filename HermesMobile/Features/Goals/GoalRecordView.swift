import SwiftUI

/// A finished goal's record, pushed as `.finishedGoal(slug)` from the Finished log.
struct GoalRecordView: View {
    @State private var viewModel: GoalRecordViewModel

    init(slug: String, server: URL, onAPIError: @escaping (Error) -> Void) {
        _viewModel = State(initialValue: GoalRecordViewModel(
            slug: slug, client: APIClientGoalsAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
    }

    var body: some View {
        GoalRecordContent(viewModel: viewModel)
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
}

/// The record, top to bottom: the finisher card, race day and the running year (Garmin goals),
/// the story, every day, the totals, then his why and reflection.
struct GoalRecordContent: View {
    @Bindable var viewModel: GoalRecordViewModel
    @Environment(\.colorScheme) private var colorScheme

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
                    finisherCard(record, paper: palette.colors)
                    if let race = record.runs?.race { GoalRaceSection(race: race, paper: palette.colors) }
                    if let runs = record.runs, runs.months.count > 1 { GoalRunningYear(runs: runs, paper: palette.colors) }
                    if !record.story.isEmpty { GoalStorySection(record: record, ink: palette.ink) }
                    everyDay(record, tint: GoalTint(palette, scheme: colorScheme))
                    totals(record)
                    GoalReflectionSection(viewModel: viewModel, record: record, paper: palette.colors)
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
        }
    }

    private func finisherCard(_ r: GoalRecord, paper: HermexPaper) -> some View {
        HXCard(.glow(paper), title: GoalFinishCopy.identityTitle(r), titleStyle: .title, spacing: BrainStyle.s) {
            HStack {
                Text(verbatim: "Achieved · \(GoalFinishCopy.range(r))").font(BrainStyle.meta)
                Spacer(minLength: 0)
                Image(systemName: "medal.fill").foregroundStyle(HermexPaper.opener.glow).accessibilityHidden(true)
            }
            .foregroundStyle(paper.glow)
        } content: {
            Text(verbatim: r.runs?.race.map(GoalFinishCopy.raceLine) ?? r.title)
                .font(AppFont.display(style: .subheadline, weight: .medium))
                .foregroundStyle(Color.hxTextPrimary)
            GoalStatGrid(tiles: GoalFinishCopy.recordTiles(r), paper: paper)
                .padding(.top, BrainStyle.xs)
        } footer: { EmptyView() }
    }

    private func everyDay(_ r: GoalRecord, tint: GoalTint) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Every day", trailing: "\(r.shown) of \(r.days)")
            SectionCard {
                VStack(alignment: .leading, spacing: BrainStyle.m) {
                    GoalCalendarGrid(
                        weeks: GoalCalendar.weeks(heatmap: r.heatmap, today: r.finished, deadline: r.finished),
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

/// The race from Garmin: pace per mile (faster miles stand taller), heart rate, fastest mile
/// and the halves.
private struct GoalRaceSection: View {
    let race: GoalRace
    let paper: HermexPaper

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Race day", trailing: GoalFinishCopy.longDate(race.date))
            SectionCard {
                VStack(alignment: .leading, spacing: BrainStyle.m) {
                    if race.splits.count > 1 { splits }
                    GoalStatGrid(tiles: tiles, paper: paper)
                }
                .padding(.vertical, BrainStyle.s)
            }
        }
    }

    private var tiles: [GoalStatTile] {
        var out = [GoalStatTile(label: "Pace", value: "\(GoalFinishCopy.pace(race.paceSeconds))/mi")]
        if let hr = race.avgHR { out.append(GoalStatTile(label: "Avg heart rate", value: "\(hr) bpm")) }
        if let fastest = race.fastestMileSeconds {
            out.append(GoalStatTile(label: "Fastest mile", value: GoalFinishCopy.pace(fastest)))
        }
        if let halves = race.halvesSeconds {
            let h = GoalFinishCopy.halves(halves)
            out.append(GoalStatTile(label: "Halves", value: h.value, note: h.note))
        }
        return out
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
                Text(verbatim: "Mile \(race.splits.count)")
            }
            .font(AppFont.caption2())
            .foregroundStyle(Color.hxTextSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: GoalRecordCopy.splitsSummary(race)))
    }
}

/// Every run this year, month by month.
private struct GoalRunningYear: View {
    let runs: GoalRuns
    let paper: HermexPaper

    var body: some View {
        let top = max(1, runs.months.map(\.miles).max() ?? 1)
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Your running year", trailing: "\(GoalFinishCopy.miles(runs.miles)) mi")
            SectionCard {
                VStack(alignment: .leading, spacing: BrainStyle.s) {
                    HStack(alignment: .bottom, spacing: BrainStyle.xs) {
                        ForEach(runs.months, id: \.month) { m in
                            VStack(spacing: 2) {
                                Text(verbatim: GoalFinishCopy.miles(m.miles.rounded()))
                                    .font(AppFont.caption2())
                                    .foregroundStyle(Color.hxTextSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                RoundedRectangle(cornerRadius: HXRadius.xs, style: .continuous)
                                    .fill(paper.glow)
                                    .frame(height: max(2, 64 * m.miles / top))
                                Text(verbatim: GoalFinishCopy.month(m.month))
                                    .font(AppFont.caption2())
                                    .foregroundStyle(Color.hxTextSecondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 104, alignment: .bottom)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: GoalRecordCopy.yearSummary(runs)))
                    Text(verbatim: GoalRecordCopy.yearLine(runs)).brainText(.meta)
                }
                .padding(.vertical, BrainStyle.s)
            }
        }
    }
}

/// The story: moments from setting the goal to the finish, on a dotted line.
private struct GoalStorySection: View {
    let record: GoalRecord
    let ink: Color

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "The story", trailing: record.days == 1 ? "1 day" : "\(record.days) days")
            SectionCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(record.story.enumerated()), id: \.offset) { offset, moment in
                        row(moment, isLast: offset == record.story.count - 1)
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
    /// "2 minimum days · 2 of 4 skips used · 1 missed day".
    static func daysLine(_ r: GoalRecord) -> String {
        var parts: [String] = []
        if r.minDays > 0 { parts.append(r.minDays == 1 ? "1 minimum day" : "\(r.minDays) minimum days") }
        if r.skipsBudget > 0 || r.skipsUsed > 0 { parts.append("\(r.skipsUsed) of \(r.skipsBudget) skips used") }
        parts.append(r.missDays == 1 ? "1 missed day" : "\(r.missDays) missed days")
        return parts.joined(separator: " · ")
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
