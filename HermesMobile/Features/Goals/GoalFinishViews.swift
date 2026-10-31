import SwiftUI

/// "Did you finish?" on a goal whose last milestone is due: I finished asks once more, then
/// closes the goal (the server ticks what's left and saves the record); Not yet hides it until
/// the screen reopens.
struct GoalFinishPrompt: View {
    let goalTitle: String
    let milestone: String
    let paper: HermexPaper
    let isFinishing: Bool
    let onFinish: () -> Void
    let onNotYet: () -> Void

    @State private var confirming = false

    var body: some View {
        HXCard(.glow(paper), title: "Did you finish?", spacing: BrainStyle.s) {
            Text(verbatim: "Last milestone")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(paper.glow)
        } content: {
            if !milestone.isEmpty {
                Text(verbatim: milestone)
                    .font(AppFont.display(style: .subheadline, weight: .medium))
                    .foregroundStyle(Color.hxTextPrimary)
            }
            Text(verbatim: "Finishing closes the goal and saves everything you did.")
                .font(BrainStyle.meta)
                .foregroundStyle(Color.hxTextPrimary)
        } footer: {
            HStack(spacing: BrainStyle.s) {
                Button(action: onNotYet) { Text(verbatim: "Not yet") }
                    .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
                Button { confirming = true } label: {
                    if isFinishing { ProgressView() } else { Text(verbatim: "I finished") }
                }
                .buttonStyle(ChatDecisionButtonStyle(emphasis: .primary))
                .disabled(isFinishing)
                .accessibilityHint(Text(verbatim: "Closes the goal and saves its record"))
            }
            .padding(.top, BrainStyle.xs)
        }
        .environment(\.hxPaper, paper)
        .confirmationDialog(Text(verbatim: "Finish \(GoalsCopy.shortTitle(goalTitle))?"), isPresented: $confirming,
                            titleVisibility: .visible) {
            Button(action: onFinish) { Text(verbatim: "Finish goal") }
            Button(role: .cancel) {} label: { Text(verbatim: "Cancel") }
        } message: {
            Text(verbatim: "Closes the goal and saves its record. You can reopen it from the record.")
        }
    }
}

/// The one-time celebration after "I finished": who he became, four numbers, his why, and a
/// place for a few words that save to the record.
struct GoalCelebrationView: View {
    @Bindable var viewModel: GoalRecordViewModel
    let onSeeRecord: () -> Void

    @State private var draft = ""
    @State private var sealShown = false
    @FocusState private var writing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                if case .loaded(let record) = viewModel.state {
                    content(record, paper: GoalPaper.palette(named: record.color, slug: record.slug).colors)
                }
            }
            .background(Color.hxCanvas.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onSeeRecord) { Image(systemName: "xmark") }
                        .accessibilityLabel(Text(verbatim: "Close"))
                }
            }
        }
        .onAppear {
            draft = viewModel.reflection
            guard !sealShown else { return }
            if reduceMotion { sealShown = true } else { withAnimation(.spring(duration: 0.5)) { sealShown = true } }
        }
    }

    private func content(_ record: GoalRecord, paper: HermexPaper) -> some View {
        VStack(spacing: BrainStyle.l) {
            seal(paper)
            VStack(spacing: BrainStyle.xs) {
                Text(verbatim: "Achieved · \(GoalFinishCopy.longDate(record.finished))")
                    .font(AppFont.caption(weight: .semibold))
                Text(verbatim: GoalFinishCopy.headline(record))
                    .font(AppFont.display(style: .title, weight: .bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: GoalFinishCopy.span(record.days))
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxTextSecondary)
            }
            .foregroundStyle(paper.glow)
            .frame(maxWidth: .infinity)
            GoalStatGrid(tiles: GoalFinishCopy.celebrationTiles(record), paper: paper)
            if !record.why.isEmpty {
                HXCard(.glow(paper), spacing: BrainStyle.xs) {
                    Text(verbatim: "Your why").font(AppFont.caption(weight: .semibold)).foregroundStyle(paper.glow)
                } content: {
                    Text(verbatim: record.why).font(AppFont.serif()).foregroundStyle(Color.hxTextPrimary)
                } footer: { EmptyView() }
            }
            reflection(record, paper: paper)
            Button(action: onSeeRecord) { Text(verbatim: "See the record") }
                .buttonStyle(ChatDecisionButtonStyle(emphasis: .primary))
        }
        .padding(BrainStyle.l)
        .environment(\.hxPaper, paper)
        .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
    }

    private func seal(_ paper: HermexPaper) -> some View {
        ZStack {
            Circle().fill(paper.wash)
            Circle().strokeBorder(paper.glow, lineWidth: 2)
            Image(systemName: "checkmark")
                .font(.system(size: 40, weight: .bold))  // design-drift: allow (a symbol in a fixed seal)
                .foregroundStyle(paper.glow)
        }
        .frame(width: 92, height: 92)
        .overlay(alignment: .topTrailing) {
            Image(systemName: "medal.fill")
                .font(.system(size: 24))  // design-drift: allow (a symbol on a fixed seal)
                .foregroundStyle(HermexPaper.opener.glow)
                .offset(x: 6, y: -6)
        }
        .scaleEffect(sealShown ? 1 : 0.85)
        .opacity(sealShown ? 1 : 0.4)
        .padding(.top, BrainStyle.m)
        .accessibilityHidden(true)
    }

    private func reflection(_ record: GoalRecord, paper: HermexPaper) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "What did it take?")
            TextField(text: $draft, prompt: Text(verbatim: "A few words for later"), axis: .vertical) {
                Text(verbatim: "Your reflection")
            }
            .font(AppFont.serif())
            .lineLimit(3...8)
            .focused($writing)
            .padding(BrainStyle.m)
            .hxCard()
            if let error = viewModel.error {
                Text(verbatim: error).font(BrainStyle.meta).foregroundStyle(Color.hxWarning)
            }
            let saved = draft.trimmingCharacters(in: .whitespacesAndNewlines) == record.reflection
            Button {
                writing = false
                Task { await viewModel.saveReflection(draft) }
            } label: {
                if viewModel.isSaving { ProgressView() } else {
                    Text(verbatim: saved && !record.reflection.isEmpty ? "Saved" : "Save reflection")
                }
            }
            .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
            .disabled(saved || viewModel.isSaving)
        }
    }
}

/// A grid of labelled numbers on a goal's paper (the Sleep screen's tiles).
struct GoalStatGrid: View {
    let tiles: [GoalStatTile]
    let paper: HermexPaper

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: BrainStyle.s), GridItem(.flexible())], spacing: BrainStyle.s) {
            ForEach(tiles) { tile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: tile.label)
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(paper.glow)
                    Text(verbatim: tile.value)
                        .font(AppFont.display(style: .title3, weight: .semibold))
                        .foregroundStyle(Color.hxTextPrimary)
                        .monospacedDigit()
                    if let note = tile.note {
                        Text(verbatim: note).font(AppFont.caption2()).foregroundStyle(Color.hxTextPrimary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(BrainStyle.m)
                .background(paper.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct GoalStatTile: Identifiable, Equatable {
    let label: String
    let value: String
    var note: String?

    var id: String { label }
}

/// Words and numbers for a finished goal, from its record.
enum GoalFinishCopy {
    /// "You're a New York City Marathon finisher", else "You finished <title>".
    static func headline(_ r: GoalRecord) -> String {
        r.identity.isEmpty ? "You finished \(r.title)" : "You're \(r.identity)"
    }

    /// The identity as a card title: "A New York City Marathon finisher".
    static func identityTitle(_ r: GoalRecord) -> String {
        r.identity.isEmpty ? r.title : r.identity.prefix(1).uppercased() + r.identity.dropFirst()
    }

    static func span(_ days: Int) -> String {
        days == 1 ? "1 day from the day you set it" : "\(days) days from the day you set it"
    }

    static func celebrationTiles(_ r: GoalRecord) -> [GoalStatTile] {
        [showedUp(r), streak(r),
         GoalStatTile(label: "Weeks hit", value: "\(r.weeks.weeksHit) / \(r.weeks.weeks)",
                      note: r.weeks.weeks > 0 && r.weeks.weeksHit == r.weeks.weeks ? "every plan kept" : "plans kept"),
         missedTwice(r)]
    }

    /// The finisher card's tiles: miles this year in place of weeks when Garmin ran.
    static func recordTiles(_ r: GoalRecord) -> [GoalStatTile] {
        var tiles = [showedUp(r)]
        if let runs = r.runs {
            tiles.append(GoalStatTile(label: "Miles this year", value: miles(runs.miles),
                                      note: "\(runs.count) runs since \(shortDate(runs.first))"))
        } else {
            tiles.append(GoalStatTile(label: "Weeks hit", value: "\(r.weeks.weeksHit) / \(r.weeks.weeks)"))
        }
        tiles.append(streak(r))
        tiles.append(missedTwice(r))
        return tiles
    }

    static func showedUp(_ r: GoalRecord) -> GoalStatTile {
        let percent = r.days > 0 ? Int((Double(r.shown) / Double(r.days) * 100).rounded()) : 0
        return GoalStatTile(label: "Showed up", value: "\(r.shown) / \(r.days)", note: "\(percent)% of days")
    }

    static func streak(_ r: GoalRecord) -> GoalStatTile {
        guard let s = r.streak else { return GoalStatTile(label: "Longest streak", value: "—") }
        return GoalStatTile(label: "Longest streak", value: s.days == 1 ? "1 day" : "\(s.days) days",
                            note: "\(shortDate(s.start)) – \(shortDate(s.end))")
    }

    static func missedTwice(_ r: GoalRecord) -> GoalStatTile {
        let value = r.missedTwice == 0 ? "Never" : r.missedTwice == 1 ? "Once" : "\(r.missedTwice) times"
        let note = r.missDays == 0 ? "no missed days"
            : r.missedTwice == 0 ? (r.missDays == 1 ? "1 miss, back next day" : "\(r.missDays) misses, back each time")
            : "\(r.missDays) missed days"
        return GoalStatTile(label: "Missed twice", value: value, note: note)
    }

    /// "26.2 mi in 4:56:50 · 11:20/mi".
    static func raceLine(_ race: GoalRace) -> String {
        "\(miles(race.miles)) mi in \(clock(race.seconds)) · \(pace(race.paceSeconds))/mi"
    }

    /// "−0:06" with "negative split", or "+1:12" with "positive split".
    static func halves(_ seconds: Int) -> (value: String, note: String) {
        if seconds == 0 { return ("0:00", "even split") }
        let sign = seconds < 0 ? "−" : "+"
        return ("\(sign)\(pace(abs(seconds)))", seconds < 0 ? "negative split" : "positive split")
    }

    static func miles(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// "4:56:50" (hours) or "48:12".
    static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Minutes and seconds: 680 → "11:20".
    static func pace(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// "41 h 42 m".
    static func hours(_ seconds: Int) -> String {
        let m = (seconds + 30) / 60
        return m >= 60 ? "\(m / 60) h \(m % 60) m" : "\(m) min"
    }

    static func shortDate(_ iso: String) -> String { format(iso, shortFormatter) }
    static func longDate(_ iso: String) -> String { format(iso, longFormatter) }

    /// "2026-04" → "Apr".
    static func month(_ yyyyMM: String) -> String { format("\(yyyyMM)-01", monthFormatter) }

    /// "Oct 10 – Nov 1".
    static func range(_ r: GoalRecord) -> String { "\(shortDate(r.started)) – \(shortDate(r.finished))" }

    // Built once each: the record and the Finished shelf format a date per row.
    private static let shortFormatter = formatter("MMM d")
    private static let longFormatter = formatter("EEEE, MMM d")
    private static let monthFormatter = formatter("MMM")

    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = pattern
        return f
    }

    private static func format(_ iso: String, _ formatter: DateFormatter) -> String {
        guard let date = GoalCalendar.date(iso) else { return iso }
        return formatter.string(from: date)
    }
}
