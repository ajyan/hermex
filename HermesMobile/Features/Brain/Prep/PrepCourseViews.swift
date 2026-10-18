import SwiftUI

// Prep home's course: today's ring card and the path of units and lesson nodes. Passed units
// collapse to a row with their stars, the current unit opens to its nodes and boss, later units
// wait locked with Test out. The path wears the `.knowledge` paper; the next step is Nous blue
// (it starts the run); rewards are gold marks only.

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
                .stroke(HermexPaper.knowledge.glow, style: StrokeStyle(lineWidth: line, lineCap: .round))
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

/// The top of Prep home with a course: today's ring, how much of the course is interview-ready, the
/// streak, and the run's Start or Resume. A glow card: the course is the object on this screen.
struct PrepTodayRingCard: View {
    let course: PrepCourse
    let streak: PrepStreak
    let action: PrepCopy.RunAction

    var body: some View {
        HXCard(.wash(.knowledge), spacing: BrainStyle.m) {
            HStack(spacing: BrainStyle.m) {
                PrepDayRing(done: course.today.done, total: course.today.total, side: 60)
                VStack(alignment: .leading, spacing: BrainStyle.xs) {
                    Text(verbatim: PrepCopy.readyLine(ready: course.readyCount, total: course.lessonTotal))
                        .font(AppFont.display(style: .headline))
                        .foregroundStyle(HermexPaper.knowledge.glow)
                    Label {
                        Text(verbatim: PrepCopy.todayLine(days: streak.days, xp: course.xp))
                    } icon: {
                        Image(systemName: "flame").foregroundStyle(HermexPaper.opener.glow)
                    }
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxTextPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PrepRunButton(action: action)
            }
            if let calibration = course.calibration {
                Text(verbatim: PrepCopy.calibrationLine(calibration))
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxTextSecondary)
            }
        }
    }
}

/// The course: passed units as rows with stars, each current unit (the one being taught, and any whose
/// boss is still to beat) as a banner over a winding path, the next unit with Test out, and the rest as a
/// quiet "Coming up" list.
struct PrepUnitPath<Between: View>: View {
    let course: PrepCourse
    /// Shown between the units and the mock row (the story bank).
    @ViewBuilder let between: Between

    var body: some View {
        let lastCurrent = course.units.lastIndex { $0.state == .current }
        let nextLocked = course.units.indices.first { i in
            course.units[i].state != .passed && course.units[i].state != .current && lastCurrent.map { i > $0 } ?? true
        }
        VStack(alignment: .leading, spacing: BrainStyle.l) {
            ForEach(Array(course.units.enumerated()), id: \.element.id) { index, unit in
                if unit.state == .passed {
                    PrepPassedUnitRow(index: index, unit: unit)
                } else if unit.state == .current {
                    PrepCurrentUnit(index: index, unit: unit)
                } else if index == nextLocked {
                    PrepLockedUnitRow(index: index, unit: unit, prominent: true)
                }
            }
            let later = course.units.indices.filter { i in
                course.units[i].state != .passed && course.units[i].state != .current && i != nextLocked
            }
            if !later.isEmpty {
                VStack(alignment: .leading, spacing: BrainStyle.xs) {
                    BrainSectionHeader(title: "Coming up")
                    ForEach(later, id: \.self) { i in
                        PrepLockedUnitRow(index: i, unit: course.units[i], prominent: false)
                    }
                }
            }
            between
            if course.units.contains(where: { $0.mock }) {
                NavigationLink(value: ShellPushDestination.brainRoute(.prep(.mock))) {
                    BrainRow(title: "Mock interview", subtitle: "Full critique on what you've passed")
                        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
                        .hxCard()
                }
                .buttonStyle(.plain)
            }
        }
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

/// A unit not yet reached. The next one offers Test out as a chip; later ones as a quiet link.
private struct PrepLockedUnitRow: View {
    let index: Int
    let unit: PrepUnit
    let prominent: Bool

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
                if prominent {
                    HXChip(paper: .knowledge, label: "Test out") { EmptyView() }
                        .frame(minHeight: BrainStyle.minTapTarget)
                } else {
                    Text(verbatim: "Test out")
                        .font(BrainStyle.meta)
                        .foregroundStyle(Color.hxTextSecondary)
                        .frame(minHeight: BrainStyle.minTapTarget)
                }
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
                        .foregroundStyle(HermexPaper.knowledge.glow)
                    Text(verbatim: PrepCopy.readyLine(ready: unit.readyCount, total: unit.lessonsTotal))
                        .font(BrainStyle.meta)
                        .foregroundStyle(Color.hxTextPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if unit.boss != .ready {
                    NavigationLink(value: ShellPushDestination.brainRoute(.prep(.testout(unit.id)))) {
                        HXChip(paper: .knowledge, label: "Test out") { EmptyView() }
                            .frame(minHeight: BrainStyle.minTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "Test out of \(unit.title)"))
                }
            }
            .padding(BrainStyle.l)
            .glowSurface(.knowledge, cornerRadius: HXRadius.xl, opaque: true)
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
                        .stroke(HermexPaper.knowledge.edge, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 7]))
                    }
                    .accessibilityHidden(true)
                }
            }
    }
}

/// A node's disc. Ready is filled glow with ✓; learned is a glow ring; shaky is an amber ring with ◌;
/// next is larger with a Nous-blue ring; locked is neutral; the boss is a gold crown.
private struct PrepNodeDisc: View {
    enum Kind { case ready, learned, shaky, next, locked, boss }
    let kind: Kind
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    var body: some View {
        let paper = HermexPaper.knowledge
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
                Circle().strokeBorder(Color.hxWarning, lineWidth: 2.5)
                symbol("circle.dashed", weight: .semibold, color: .hxWarning)
            case .next:
                Circle().fill(Color.hxCanvas)
                Circle().strokeBorder(Color.accentColor, lineWidth: 4)
                symbol("play.fill", weight: .bold, color: .accentColor)
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
            .font(.system(size: side * 0.4, weight: weight))
            .foregroundStyle(color)
    }
}

/// One lesson on the path. Learned, ready and shaky lessons open the reader; the next one starts today's run.
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
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.run))) { row }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(lesson.title), next"))
                .accessibilityHint(Text(verbatim: "Starts today's run"))
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
                    Text(verbatim: "Back in reviews").font(BrainStyle.meta).foregroundStyle(Color.hxWarning)
                } else if lesson.reteach {
                    Text(verbatim: "Another way to see it is waiting").font(BrainStyle.meta)
                        .foregroundStyle(HermexPaper.knowledge.glow)
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
        if unit.boss == .ready {
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.run))) { row }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: label))
                .accessibilityHint(Text(verbatim: "Starts today's run"))
        } else {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: label))
        }
    }
}
