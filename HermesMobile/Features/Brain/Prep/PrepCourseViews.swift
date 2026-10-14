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

/// The top of Prep home with a course: the ring, streak and XP, and the run's Start or Resume.
struct PrepTodayRingCard: View {
    let course: PrepCourse
    let streak: PrepStreak
    let action: PrepCopy.RunAction

    var body: some View {
        HStack(spacing: BrainStyle.m) {
            PrepDayRing(done: course.today.done, total: course.today.total)
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                Text(verbatim: "Today")
                    .font(AppFont.display(style: .headline))
                    .foregroundStyle(Color.hxTextPrimary)
                Label {
                    Text(verbatim: PrepCopy.todayLine(days: streak.days, xp: course.xp))
                } icon: {
                    Image(systemName: "flame").foregroundStyle(HermexPaper.opener.glow)
                }
                .font(BrainStyle.meta)
                .foregroundStyle(Color.hxTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PrepRunButton(action: action)
        }
        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
        .padding(.vertical, BrainStyle.cardVerticalPadding)
        .hxCard()
    }
}

/// The course as a path of units.
struct PrepUnitPath: View {
    let course: PrepCourse

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.l) {
            ForEach(Array(course.units.enumerated()), id: \.element.id) { index, unit in
                switch unit.state {
                case .passed:
                    PrepPassedUnitRow(index: index, unit: unit)
                case .current:
                    PrepCurrentUnit(index: index, unit: unit,
                                    next: course.units.indices.contains(index + 1) ? course.units[index + 1].title : nil)
                case .locked, .unknown:
                    PrepLockedUnitRow(index: index, unit: unit)
                }
            }
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
            Text(verbatim: PrepCopy.unitHeader(index: index, title: unit.title))
                .font(AppFont.display(style: .subheadline))
                .foregroundStyle(Color.hxTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            PrepStars(stars: unit.stars)
        }
        .frame(minHeight: BrainStyle.minTapTarget)
        .accessibilityElement(children: .combine)
    }
}

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
                HXChip(paper: .knowledge, label: "Test out") { EmptyView() }
                    .frame(minHeight: BrainStyle.minTapTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "Test out of \(unit.title)"))
        }
    }
}

/// The unit being taught: its nodes in a zigzag and its boss at the end.
private struct PrepCurrentUnit: View {
    let index: Int
    let unit: PrepUnit
    let next: String?
    @ScaledMetric(relativeTo: .body) private var step: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            HStack(alignment: .firstTextBaseline) {
                BrainSectionHeader(title: PrepCopy.unitHeader(index: index, title: unit.title),
                                   trailing: "\(unit.lessonsDone) of \(unit.lessonsTotal)")
                if unit.boss != .ready {  // the boss early, for a unit you already know
                    NavigationLink(value: ShellPushDestination.brainRoute(.prep(.testout(unit.id)))) {
                        HXChip(paper: .knowledge, label: "Test out") { EmptyView() }
                            .frame(minHeight: BrainStyle.minTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: "Test out of \(unit.title)"))
                }
            }
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                ForEach(Array(unit.lessons.enumerated()), id: \.element.id) { offset, lesson in
                    PrepLessonNodeRow(lesson: lesson)
                        .padding(.leading, offset % 2 == 0 ? 0 : step)
                }
                PrepBossNodeRow(unit: unit, next: next)
                    .padding(.leading, unit.lessons.count % 2 == 0 ? 0 : step)
            }
            .padding(BrainStyle.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glowSurface(.knowledge, cornerRadius: HXRadius.lg)
        }
    }
}

/// A node's 34pt disc: learned (filled ✓), next (Nous-blue ring ▶), locked (neutral 🔒) or the boss crown.
private struct PrepNodeDisc: View {
    enum Kind { case learned, next, locked, boss }
    let kind: Kind
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 34

    var body: some View {
        let paper = HermexPaper.knowledge
        ZStack {
            switch kind {
            case .learned:
                Circle().fill(paper.glow)
                Image(systemName: "checkmark")
                    .font(.system(size: side * 0.42, weight: .bold))
                    .foregroundStyle(paper.onGlow)
            case .next:
                Circle().fill(Color.hxCanvas)
                Circle().strokeBorder(Color.accentColor, lineWidth: 3)
                Image(systemName: "play.fill")
                    .font(.system(size: side * 0.36, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            case .locked:
                Circle().fill(Color.hxSurface)
                Circle().strokeBorder(Color.hxSeparator, lineWidth: 0.5)
                Image(systemName: "lock")
                    .font(.system(size: side * 0.38, weight: .semibold))
                    .foregroundStyle(Color.hxTextSecondary)
            case .boss:
                Circle().fill(Color.hxSurface)
                Circle().strokeBorder(Color.hxSeparator, lineWidth: 0.5)
                Image(systemName: "crown")
                    .font(.system(size: side * 0.42, weight: .semibold))
                    .foregroundStyle(HermexPaper.opener.glow)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// One lesson on the path. A learned lesson opens the reader; the next one starts today's run.
private struct PrepLessonNodeRow: View {
    let lesson: PrepLessonNode

    var body: some View {
        switch lesson.state {
        case .learned:
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.lesson(lesson.id)))) { row(.learned) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(lesson.title), learned"))
                .accessibilityHint(Text(verbatim: "Opens the lesson"))
        case .next:
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.run))) { row(.next) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(lesson.title), next"))
                .accessibilityHint(Text(verbatim: "Starts today's run"))
        case .locked, .unknown:
            row(.locked)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(lesson.title), locked"))
        }
    }

    private func row(_ kind: PrepNodeDisc.Kind) -> some View {
        HStack(spacing: BrainStyle.m) {
            PrepNodeDisc(kind: kind)
            Text(verbatim: lesson.title)
                .font(kind == .next ? AppFont.display(style: .body) : BrainStyle.rowTitle)
                .foregroundStyle(kind == .locked ? Color.hxTextSecondary : Color.hxTextPrimary)
                .lineLimit(2)
            if lesson.reteach {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(HermexPaper.knowledge.glow)
                    .accessibilityLabel(Text(verbatim: "Another way to see it is waiting"))
            }
        }
        .frame(minHeight: BrainStyle.minTapTarget, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct PrepBossNodeRow: View {
    let unit: PrepUnit
    let next: String?

    var body: some View {
        let label = PrepCopy.bossNode(unit.boss, next: next)
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
