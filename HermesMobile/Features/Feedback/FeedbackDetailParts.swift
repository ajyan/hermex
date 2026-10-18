import SwiftUI

// The pieces of the feedback detail screen: the stage track, Now → After, the build's
// checks and the plan's questions.

/// Where an entry is in You said → Plan → Build → Merge, and whether that step waits on the user.
struct FeedbackStage: Equatable {
    enum Mark: Equatable {
        /// The user's turn: approve a plan, merge a branch.
        case waiting
        /// The nightly job's turn.
        case working
        case failed
        /// Every step is behind it.
        case finished
    }

    static let names = ["You said", "Plan", "Build", "Merge"]

    let index: Int
    let mark: Mark

    init(index: Int, mark: Mark) {
        self.index = index
        self.mark = mark
    }

    /// Nil for a rejected entry, which left the track.
    init?(entry: FeedbackEntry) {
        switch entry.status {
        case .new, .planning: self.init(index: 1, mark: .working)
        case .planned: self.init(index: 1, mark: .waiting)
        case .approved, .building: self.init(index: 2, mark: .working)
        case .ready: self.init(index: 3, mark: .waiting)
        case .merged: self.init(index: 3, mark: .finished)
        // A plan's summary means planning finished, so the build is what failed.
        case .failed: self.init(index: entry.summary == nil ? 1 : 2, mark: .failed)
        case .rejected, .unknown: return nil
        }
    }

    var accessibilityText: String {
        let state = switch mark {
        case .waiting: "waiting on you"
        case .working: "in progress"
        case .failed: "failed"
        case .finished: "done"
        }
        return "Step \(index + 1) of \(Self.names.count), \(Self.names[index]), \(state)"
    }
}

/// The four steps as dots joined by lines. Steps behind are filled, the current one is marked
/// by its state (amber halo while it waits on the user), and steps ahead are hollow.
struct FeedbackStageTrack: View {
    let stage: FeedbackStage
    @ScaledMetric(relativeTo: .caption) private var dot: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(FeedbackStage.names.indices, id: \.self) { index in
                if index > 0 {
                    Rectangle()
                        .fill(index <= stage.index ? Color.hxTextSecondary : Color.hxSeparator)
                        .frame(height: 2)
                        .padding(.top, dot / 2 - 1)
                }
                VStack(spacing: 5) {
                    marker(index)
                    Text(verbatim: FeedbackStage.names[index])
                        .font(AppFont.caption2(weight: index == stage.index ? .semibold : .regular))
                        .foregroundStyle(labelColor(index))
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(minWidth: 52)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: stage.accessibilityText))
    }

    @ViewBuilder
    private func marker(_ index: Int) -> some View {
        let paper = HermexPaper.request
        if index < stage.index || (index == stage.index && stage.mark == .finished) {
            Circle().fill(Color.hxTextSecondary).frame(width: dot, height: dot)
        } else if index == stage.index {
            switch stage.mark {
            case .waiting:
                Circle().fill(paper.glow).frame(width: dot, height: dot)
                    .background(Circle().fill(paper.wash).padding(-4))
            case .working:
                Circle().strokeBorder(paper.glow, lineWidth: 2).frame(width: dot, height: dot)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .resizable()
                    .frame(width: dot + 2, height: dot + 2)
                    .foregroundStyle(Color.hxDanger)
                    .padding(-1)
            case .finished:
                EmptyView()
            }
        } else {
            Circle().strokeBorder(Color.hxSeparator, lineWidth: 1.5).frame(width: dot, height: dot)
        }
    }

    private func labelColor(_ index: Int) -> Color {
        guard index == stage.index else { return .hxTextSecondary }
        switch stage.mark {
        case .waiting, .working: return HermexPaper.request.glow
        case .failed: return .hxDanger
        case .finished: return .hxTextSecondary
        }
    }
}

/// What the change does as two lines: Now and After for a plan, Before and Now once it's built.
struct FeedbackNowAfterCard: View {
    let entry: FeedbackEntry

    var body: some View {
        let built = entry.status == .ready || entry.status == .merged
        VStack(alignment: .leading, spacing: 12) {
            if let now = entry.now {
                row(built ? "Before" : "Now", now, color: .hxTextSecondary)
            }
            if entry.now != nil, entry.after != nil {
                Divider().overlay(Color.hxSeparator)
            }
            if let after = entry.after {
                row(built ? "Now" : "After", after, color: HermexPaper.request.glow)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hxCard()
    }

    private func row(_ label: String, _ text: String, color: Color) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                tag(label, color: color).frame(width: 52, alignment: .leading)
                Text(verbatim: text)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                tag(label, color: color)
                Text(verbatim: text)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func tag(_ label: String, color: Color) -> some View {
        Text(verbatim: label)
            .font(AppFont.caption(weight: .bold))
            .foregroundStyle(color)
    }
}

/// A built branch's checklist (what passed, what couldn't be checked, what failed) and its commits.
/// An older report without checks shows its `TESTS:`-less tail in the build report sheet instead.
struct FeedbackChecksCard: View {
    let entry: FeedbackEntry

    var body: some View {
        if !entry.checks.isEmpty || !entry.commits.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HXSectionHeader(title: "Checks")
                VStack(spacing: 0) {
                    ForEach(Array(entry.checks.enumerated()), id: \.offset) { index, check in
                        if index > 0 { divider }
                        row(symbol: check.state.symbol, color: check.state.color, title: check.text, detail: nil)
                    }
                    ForEach(Array(entry.commits.enumerated()), id: \.offset) { index, commit in
                        if index > 0 || !entry.checks.isEmpty { divider }
                        row(symbol: "arrow.triangle.branch", color: .hxTextSecondary,
                            title: commit.title, detail: commit.sha, mono: true)
                    }
                }
                .hxCard()
            }
        }
    }

    private var divider: some View {
        Divider().overlay(Color.hxSeparator).padding(.leading, 46)
    }

    private func row(symbol: String, color: Color, title: String, detail: String?, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(AppFont.caption(weight: .bold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(color.opacity(0.16), in: Circle())
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextPrimary)
                if let detail {
                    Text(verbatim: detail)
                        .font(mono ? AppFont.mono(style: .caption) : AppFont.caption())
                        .foregroundStyle(Color.hxTextSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// The plan's questions as a request card: each question with its answers as choices and
/// "Other…" for a typed answer. Until the user picks, the recommended answer shows as chosen,
/// since that's what the build takes.
struct FeedbackQuestionsCard: View {
    let questions: [FeedbackQuestion]
    @Binding var answers: FeedbackAnswers
    @State private var otherTarget: Int?
    @State private var otherText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: question.text)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(HermexPaper.request.glow)
                        .accessibilityAddTraits(.isHeader)
                    let pick = answers.pick(for: index)
                    let shown = pick ?? question.options.firstIndex(where: \.recommended).map { .option($0) }
                    ForEach(Array(question.options.enumerated()), id: \.offset) { option, answer in
                        choice(answer.text,
                               note: answer.recommended ? "Recommended" : nil,
                               isPicked: shown == .option(option)) {
                            answers.toggle(option, for: index)
                        }
                    }
                    let typed: String? = if case .other(let text)? = pick { text } else { nil }
                    choice(typed ?? "Other…", note: nil, isPicked: typed != nil, dashed: typed == nil) {
                        otherText = typed ?? ""
                        otherTarget = index
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glowSurface(.request, cornerRadius: HXRadius.lg)
        .alert(
            Text(verbatim: "Your answer"),
            isPresented: Binding(get: { otherTarget != nil }, set: { if !$0 { otherTarget = nil } })
        ) {
            TextField(text: $otherText) { Text(verbatim: "Answer in your words") }
            Button {
                if let otherTarget { answers.setOther(otherText, for: otherTarget) }
            } label: {
                Text(verbatim: "Done")
            }
            Button(role: .cancel) {} label: { Text(verbatim: "Cancel") }
        }
    }

    private func choice(_ title: String, note: String?, isPicked: Bool, dashed: Bool = false,
                        action: @escaping () -> Void) -> some View {
        let paper = HermexPaper.request
        let shape = RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous)
        return Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: title)
                    .font(AppFont.subheadline(weight: .medium))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let note {
                    Text(verbatim: note)
                        .font(AppFont.caption(weight: .semibold))
                }
                if isPicked {
                    Image(systemName: "checkmark")
                        .font(AppFont.caption(weight: .bold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(isPicked ? paper.onGlow : paper.glow)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 40)
            .background(isPicked ? paper.glow : paper.wash, in: shape)
            .overlay(shape.strokeBorder(isPicked ? paper.glow : paper.edge,
                                        style: StrokeStyle(lineWidth: 0.5, dash: dashed ? [4, 3] : [])))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: [title, note].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}
