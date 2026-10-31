import SwiftUI

// Prep home's course: the readiness card and the path of units and lesson nodes. Passed units
// collapse to a row with their stars, the unit being taught opens to its nodes and boss, other open
// units fold to one row until tapped, the next unit waits locked with Test out, and the rest are
// counted in one line. The path wears the `.prep` paper; only real controls are Nous blue (Start
// and Start call on the readiness card); rewards are gold marks only.

/// Today's done/total as a ring, the number inside.
struct PrepDayRing: View {
    let done: Int
    let total: Int
    @ScaledMetric private var side: CGFloat

    init(done: Int, total: Int, side: CGFloat = 54) {
        self.done = done
        self.total = total
        _side = ScaledMetric(wrappedValue: side, relativeTo: .body)
    }

    var body: some View {
        let line = max(4, side * 0.11)
        let fraction = total > 0 ? min(1, Double(done) / Double(total)) : 0
        ZStack {
            Circle().stroke(Color.hxSeparator, lineWidth: line)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(HermexPaper.prep.glow, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(verbatim: "\(done)/\(total)")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(line)
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(done) of \(total) done today"))
    }
}

/// The top of Prep home: where interview practice stands (stories ready, graded mocks, open gaps,
/// the speaking streak) and the one thing to do next. A due voice mock leads with Start call and
/// today's run follows as a row under it; otherwise today's run is the card's action.
struct PrepReadinessCard: View {
    struct DueMock {
        let kind: PrepMockKind
        let ladder: PrepLadder
        let isStarting: Bool
        let errorMessage: String?
        let start: () -> Void
    }

    let facts: String
    let streakDays: Int
    let today: PrepDayCount?
    let runAction: PrepCopy.RunAction
    var mock: DueMock?

    var body: some View {
        let paper = HermexPaper.prep
        HXCard(.wash(paper), title: mock == nil ? PrepCopy.runCardTitle(runAction) : "Call the interviewer",
               titleStyle: .title3, spacing: BrainStyle.m, kicker: { EmptyView() }, content: {
            if let mock, let line = PrepCopy.mockLine(mock.kind, level: mock.ladder.current) {
                Text(verbatim: line)
                    .font(BrainStyle.meta)
                    .foregroundStyle(paper.glow)
            }
            Text(verbatim: facts)
                .font(BrainStyle.rowSubtitle)
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Label {
                Text(verbatim: PrepCopy.speakingStreak(days: streakDays))
            } icon: {
                Image(systemName: "flame").foregroundStyle(HermexPaper.opener.glow)
            }
            .font(BrainStyle.meta)
            .foregroundStyle(Color.hxTextSecondary)
            if let message = mock?.errorMessage {
                Text(verbatim: message)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }, footer: {
            VStack(spacing: BrainStyle.m) {
                if let mock {
                    PrepStartCallButton(isStarting: mock.isStarting, action: mock.start)
                    PrepRunRow(today: today, action: runAction)
                } else {
                    if let today { PrepRunProgress(today: today) }
                    PrepRunButton(action: runAction, fullWidth: true)
                }
            }
        })
    }
}

/// Today's run as one quiet row under a due mock: its ring, how far it got, and Start or Resume.
private struct PrepRunRow: View {
    let today: PrepDayCount?
    let action: PrepCopy.RunAction

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: BrainStyle.m) { progress; PrepRunButton(action: action, prominent: false) }
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                progress
                PrepRunButton(action: action, fullWidth: true, prominent: false)
            }
        }
    }

    @ViewBuilder private var progress: some View {
        if let today { PrepRunProgress(today: today).frame(maxWidth: .infinity, alignment: .leading) }
        else { Spacer(minLength: 0) }
    }
}

/// Today's ring beside "Today's run · 3 of 11".
private struct PrepRunProgress: View {
    let today: PrepDayCount

    var body: some View {
        HStack(spacing: BrainStyle.s) {
            PrepDayRing(done: today.done, total: today.total, side: 32)
            Text(verbatim: PrepCopy.runProgressLine(done: today.done, total: today.total))
                .font(BrainStyle.rowSubtitle)
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The course: passed units as rows with stars, each current unit (the one being taught, and any whose
/// boss is still to beat) as a banner over a winding path, the next unit with Test out, and the rest as
/// one quiet "N more units" line.
struct PrepUnitPath: View {
    let course: PrepCourse
    /// Open units the user unfolded; the unit being taught is always open.
    @State private var unfolded: Set<String> = []

    /// The unit being taught: the one holding the next lesson, else the last open unit.
    private var teaching: String? {
        course.units.first { $0.lessons.contains { $0.state == .next } }?.id
            ?? course.units.last { $0.state == .current }?.id
    }

    var body: some View {
        let lastCurrent = course.units.lastIndex { $0.state == .current }
        let nextLocked = course.units.indices.first { i in
            course.units[i].state != .passed && course.units[i].state != .current && lastCurrent.map { i > $0 } ?? true
        }
        let later = course.units.indices.filter { i in
            course.units[i].state != .passed && course.units[i].state != .current && i != nextLocked
        }.count
        VStack(alignment: .leading, spacing: BrainStyle.l) {
            ForEach(Array(course.units.enumerated()), id: \.element.id) { index, unit in
                if unit.state == .passed {
                    PrepPassedUnitRow(index: index, unit: unit)
                } else if unit.state == .current, unit.id == teaching || unfolded.contains(unit.id) {
                    PrepCurrentUnit(index: index, unit: unit)
                } else if unit.state == .current {
                    PrepFoldedUnitRow(index: index, unit: unit) { unfolded.insert(unit.id) }
                } else if index == nextLocked {
                    PrepLockedUnitRow(index: index, unit: unit)
                }
            }
            if later > 0 {
                Text(verbatim: Self.moreUnitsLine(later))
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxTextSecondary)
            }
        }
    }

    /// The units past the next one, counted: "1 more unit", "4 more units".
    static func moreUnitsLine(_ count: Int) -> String {
        count == 1 ? "1 more unit" : "\(count) more units"
    }
}

private struct PrepPassedUnitRow: View {
    let index: Int
    let unit: PrepUnit

    var body: some View {
        HStack(spacing: BrainStyle.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: PrepCopy.unitHeader(index: index, title: unit.title))
                    .font(AppFont.display(style: .subheadline))
                    .foregroundStyle(Color.hxTextPrimary)
                Text(verbatim: PrepCopy.readyLine(ready: unit.readyCount, total: unit.lessonsTotal))
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PrepStars(stars: unit.stars)
        }
        .frame(minHeight: BrainStyle.minTapTarget)
        .accessibilityElement(children: .combine)
    }
}

/// An open unit that isn't being taught (its boss is still to beat): one row with what's waiting in it,
/// opening to its path on a tap.
private struct PrepFoldedUnitRow: View {
    let index: Int
    let unit: PrepUnit
    let unfold: () -> Void

    var body: some View {
        Button(action: unfold) {
            HStack(spacing: BrainStyle.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: PrepCopy.unitHeader(index: index, title: unit.title))
                        .font(AppFont.display(style: .subheadline))
                        .foregroundStyle(Color.hxTextPrimary)
                    Text(verbatim: PrepCopy.foldedUnitLine(unit))
                        .font(BrainStyle.meta)
                        .foregroundStyle(Color.hxTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(BrainStyle.meta.weight(.semibold))
                    .foregroundStyle(Color.hxTextSecondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: BrainStyle.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(verbatim: "Shows the unit's lessons"))
    }
}

/// The next unit not yet reached, with Test out as a chip.
private struct PrepLockedUnitRow: View {
    let index: Int
    let unit: PrepUnit

    var body: some View {
        HStack(spacing: BrainStyle.m) {
            Label {
                Text(verbatim: PrepCopy.unitHeader(index: index, title: unit.title))
            } icon: {
                Image(systemName: "lock")
            }
            .font(BrainStyle.rowSubtitle)
            .foregroundStyle(Color.hxTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.testout(unit.id)))) {
                HXChip(paper: .prep, label: "Test out") { EmptyView() }
                    .frame(minHeight: BrainStyle.minTapTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "Test out of \(unit.title)"))
        }
    }
}

/// The unit being taught: a glow banner with its ready count, then its lessons on a winding path.
private struct PrepCurrentUnit: View {
    let index: Int
    let unit: PrepUnit
    @ScaledMetric(relativeTo: .body) private var step: CGFloat = 30

    private static let pattern: [CGFloat] = [0, 1, 2, 1]

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.m) {
            HStack(alignment: .center, spacing: BrainStyle.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: PrepCopy.unitHeader(index: index, title: unit.title))
                        .font(AppFont.display(style: .headline))
                        .foregroundStyle(HermexPaper.prep.glow)
                    Text(verbatim: PrepCopy.readyLine(ready: unit.readyCount, total: unit.lessonsTotal))
                        .font(BrainStyle.meta)
                        .foregroundStyle(Color.hxTextPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if unit.boss != .ready {
                    NavigationLink(value: ShellPushDestination.brainRoute(.prep(.testout(unit.id)))) {
                        HXChip(paper: .prep, label: "Test out") { EmptyView() }
                            .frame(minHeight: BrainStyle.minTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "Test out of \(unit.title)"))
                }
            }
            .padding(BrainStyle.l)
            .glowSurface(.prep, cornerRadius: HXRadius.xl, opaque: true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(unit.lessons.enumerated()), id: \.element.id) { offset, lesson in
                    PrepPathRow(offset: x(offset), next: x(offset + 1)) {
                        PrepLessonNodeLink(lesson: lesson)
                    }
                }
                PrepPathRow(offset: x(unit.lessons.count), next: nil) {
                    PrepBossNodeRow(unit: unit)
                }
            }
            .padding(.leading, BrainStyle.s)
        }
    }

    private func x(_ i: Int) -> CGFloat { Self.pattern[i % Self.pattern.count] * step }
}

/// One stop on the path: its node pushed right by `offset`, with a dotted connector to the next stop.
/// The connector is decorative and static.
private struct PrepPathRow<Content: View>: View {
    let offset: CGFloat
    let next: CGFloat?
    @ViewBuilder let content: Content
    @ScaledMetric(relativeTo: .body) private var node: CGFloat = 44

    var body: some View {
        content
            .padding(.leading, offset)
            .padding(.bottom, BrainStyle.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) {
                if let next {
                    GeometryReader { proxy in
                        Path { p in
                            p.move(to: CGPoint(x: offset + node / 2, y: node))
                            p.addLine(to: CGPoint(x: next + node / 2, y: proxy.size.height))
                        }
                        .stroke(HermexPaper.prep.edge, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 7]))
                    }
                    .accessibilityHidden(true)
                }
            }
    }
}

/// A node's disc. Ready is filled glow with ✓; learned is a glow ring; a lesson back in reviews is a
/// neutral ring with ◌ (it rejoins reviews, it didn't fail); next is larger with a heavy glow ring (it's
/// in today's run, not a control); locked is neutral; the boss is a gold crown.
private struct PrepNodeDisc: View {
    enum Kind { case ready, learned, shaky, next, locked, boss }
    let kind: Kind
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    var body: some View {
        let paper = HermexPaper.prep
        let size = kind == .next ? side * 1.2 : side
        ZStack {
            switch kind {
            case .ready:
                Circle().fill(paper.glow)
                symbol("checkmark", weight: .bold, color: paper.onGlow)
            case .learned:
                Circle().fill(paper.wash)
                Circle().strokeBorder(paper.glow, lineWidth: 2.5)
                symbol("book", weight: .semibold, color: paper.glow)
            case .shaky:
                Circle().fill(Color.hxSurface)
                Circle().strokeBorder(Color.hxSeparator, lineWidth: 1.5)
                symbol("circle.dashed", weight: .semibold, color: .hxTextSecondary)
            case .next:
                Circle().fill(paper.wash)
                Circle().strokeBorder(paper.glow, lineWidth: 4)
                symbol("arrow.forward", weight: .bold, color: paper.glow)
            case .locked:
                Circle().fill(Color.hxSurface)
                Circle().strokeBorder(Color.hxSeparator, lineWidth: 0.5)
                symbol("lock", weight: .semibold, color: .hxTextSecondary)
            case .boss:
                Circle().fill(Color.hxSurface)
                Circle().strokeBorder(Color.hxSeparator, lineWidth: 0.5)
                symbol("crown", weight: .semibold, color: HermexPaper.opener.glow)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String, weight: Font.Weight, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: side * 0.4, weight: weight)) // design-drift: allow (symbol in a scaled fixed-size disc)
            .foregroundStyle(color)
    }
}

/// One lesson on the path. Learned, ready and reviewing lessons open the reader; the next one is marked as
/// coming up in today's run (Start on the readiness card begins it), so it opens nothing.
private struct PrepLessonNodeLink: View {
    let lesson: PrepLessonNode

    var body: some View {
        switch lesson.state {
        case .learned, .ready, .shaky:
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.lesson(lesson.id)))) { row }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(lesson.title), \(PrepCopy.lessonStateWord(lesson.state))"))
                .accessibilityHint(Text(verbatim: "Opens the lesson"))
        case .next:
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(lesson.title), up next in today's run"))
        case .locked, .unknown:
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(lesson.title), locked"))
        }
    }

    private var kind: PrepNodeDisc.Kind {
        switch lesson.state {
        case .ready: .ready
        case .learned: .learned
        case .shaky: .shaky
        case .next: .next
        case .locked, .unknown: .locked
        }
    }

    private var row: some View {
        HStack(spacing: BrainStyle.m) {
            PrepNodeDisc(kind: kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: lesson.title)
                    .font(kind == .next ? AppFont.display(style: .body) : BrainStyle.rowTitle)
                    .foregroundStyle(kind == .locked ? Color.hxTextSecondary : Color.hxTextPrimary)
                    .lineLimit(2)
                if kind == .shaky {
                    Text(verbatim: "In reviews").font(BrainStyle.meta).foregroundStyle(Color.hxTextSecondary)
                } else if kind == .next {
                    Text(verbatim: "Up next in today's run").font(BrainStyle.meta).foregroundStyle(HermexPaper.prep.glow)
                } else if lesson.reteach {
                    Text(verbatim: "Another way to see it is waiting").font(BrainStyle.meta)
                        .foregroundStyle(HermexPaper.prep.glow)
                }
            }
        }
        .frame(minHeight: BrainStyle.minTapTarget, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct PrepBossNodeRow: View {
    let unit: PrepUnit

    var body: some View {
        let label = PrepCopy.bossNode(unit.boss)
        let row = HStack(spacing: BrainStyle.m) {
            PrepNodeDisc(kind: .boss)
            Text(verbatim: label)
                .font(BrainStyle.rowTitle)
                .foregroundStyle(unit.boss == .ready ? Color.hxTextPrimary : Color.hxTextSecondary)
        }
        .frame(minHeight: BrainStyle.minTapTarget, alignment: .leading)
        .contentShape(Rectangle())
        // The boss comes up inside a run (the server schedules it), so the row says where, and opens nothing.
        row
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
    }
}
