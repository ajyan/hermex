import Foundation
import Observation
import SwiftUI

// The voice mock ladders: two rows on Prep home, a brief screen per ladder with Start call, and the
// graded result after hang-up. Cards are `.prep` wash cards like every Prep card; Start call is
// a control, so it alone wears Nous blue. Only the candidate's own quoted words are serif.

// MARK: - Home section

/// Prep home's two ladder rows, each opening its brief, with the last graded score.
struct PrepMockSection: View {
    let mocks: PrepMocks

    private var rows: [(kind: PrepMockKind, ladder: PrepLadder)] {
        PrepMockKind.allCases.compactMap { kind in mocks.ladder(kind).map { (kind, $0) } }
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "Mock interviews")
                SectionCard {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.kind) { offset, row in
                            if offset > 0 { PrepRowDivider() }
                            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.mockLadder(row.kind)))) {
                                BrainRow(
                                    leading: { PrepMockIcon() },
                                    title: PrepMockCopy.rowTitle(row.kind, ladder: row.ladder),
                                    subtitle: row.ladder.best.map { "Passed through \($0)" },
                                    trailing: row.ladder.lastScore.map { "Last \(PrepMockCopy.score($0))" })
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

/// A phone on a small tile in the Prep paper's wash.
private struct PrepMockIcon: View {
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 32

    var body: some View {
        let paper = HermexPaper.prep
        Image(systemName: "phone.fill")
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(paper.glow)
            .frame(width: side, height: side)
            .background(paper.wash, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous).strokeBorder(paper.edge, lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

// MARK: - Brief

/// One ladder: the level a call takes (the current one, or any unlocked level picked to replay it),
/// how long it runs and what is scored, Start call, and the recent mocks of this kind. Pushed as
/// `.prep(.mockLadder(kind))`.
struct PrepMockBriefView: View {
    let kind: PrepMockKind
    @State private var viewModel: PrepMockViewModel
    @Environment(\.openMockCall) private var openMockCall

    init(kind: PrepMockKind, server: URL, onAPIError: @escaping (Error) -> Void) {
        self.kind = kind
        _viewModel = State(initialValue: PrepMockViewModel(
            client: APIClientPrepAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
    }

    var body: some View {
        content
            .hxNavigationTitle("\(kind.title) mock")
            .feedbackContext(FeedbackContext(feature: "Prep", screen: "Mock brief"))
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            PrepUnavailableView()
        case .failed(let message):
            PrepFailedView(title: "Couldn't load mocks", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let mocks):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.xl) {
                    briefCard(mocks.ladder(kind))
                    recent(mocks.recent(for: kind), ladder: mocks.ladder(kind))
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
        }
    }

    private func briefCard(_ ladder: PrepLadder?) -> some View {
        let paper = HermexPaper.prep
        let chosen = viewModel.level(for: kind)
        let level = ladder?.levels.first { $0.level == chosen } ?? ladder?.current
        return HXCard(.wash(paper), title: level.map { "\($0.level) \u{00B7} \($0.title)" } ?? kind.title,
                      titleStyle: .title3, spacing: BrainStyle.m, kicker: {
            HXChip(paper: paper, symbol: "phone.fill", label: "Voice mock with the interviewer")
        }, content: {
            levelPicker
            if let minutes = level.flatMap({ PrepMockCopy.minutes($0.minutes) }) {
                Text(verbatim: minutes)
                    .font(BrainStyle.meta)
                    .foregroundStyle(paper.glow)
            }
            Text(verbatim: PrepMockCopy.scored(kind))
                .font(BrainStyle.rowSubtitle)
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = viewModel.errorMessage {
                Text(verbatim: message)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }, footer: {
            if openMockCall.isAvailable {
                PrepStartCallButton(isStarting: viewModel.isStarting) {
                    Task { await viewModel.startCall(kind: kind, open: openMockCall) }
                }
            }
        })
    }

    /// A compact menu of the unlocked levels, on the current one until another is picked. Hidden
    /// while only one level is unlocked.
    @ViewBuilder
    private var levelPicker: some View {
        let levels = viewModel.replayableLevels(kind)
        if levels.count > 1 {
            Picker(selection: Binding(get: { viewModel.level(for: kind) ?? "" },
                                      set: { viewModel.chosenLevel = $0 })) {
                ForEach(levels, id: \.level) { level in
                    Text(verbatim: "\(level.level) \(level.title)").tag(level.level)
                }
            } label: {
                Text(verbatim: "Level")
            }
            .pickerStyle(.menu)
            .font(BrainStyle.rowSubtitle)
            .disabled(viewModel.isStarting)
        }
    }

    @ViewBuilder
    private func recent(_ results: [PrepMockResult], ladder: PrepLadder?) -> some View {
        if !results.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "Recent", count: results.count)
                SectionCard {
                    VStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { offset, result in
                            if offset > 0 { PrepRowDivider() }
                            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.mockResult(result.mockID)))) {
                                BrainRow(
                                    title: "\(PrepMockCopy.levelTitle(result.level, in: ladder)) \u{00B7} \(PrepMockCopy.statusWord(result))",
                                    subtitle: result.ts.map { BrainStyle.displayDate($0) },
                                    trailing: result.score.map(PrepMockCopy.score))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

/// Start call: a full-width Nous blue capsule, "Starting…" and off while the mock starts.
struct PrepStartCallButton: View {
    let isStarting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text(verbatim: isStarting ? "Starting…" : "Start call")
            } icon: {
                Image(systemName: "phone.fill")
            }
            .font(AppFont.body(weight: .semibold))
            .foregroundStyle(isStarting ? Color.hxTextSecondary : Color.hxOnAccent)
            .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
            .background(isStarting ? Color.hxSeparator.opacity(0.6) : Color.accentColor, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
        .accessibilityLabel(Text(verbatim: isStarting ? "Starting the call" : "Start call"))
    }
}

// MARK: - Result

/// One mock after hang-up: "Grading your mock…" until the grader is done (refreshed on appear and
/// by pulling, never polled), then the score, each scored dimension and frame point as ✓ or ◌ with
/// the words that showed it, the next level when it passed, and the median time to the first word.
/// Pushed as `.prep(.mockResult(id))`.
struct PrepMockResultView: View {
    let mockID: String
    /// The grade request when it never got through, for Send for grading.
    let unsent: MockCallGrade?
    @State private var viewModel: PrepMockViewModel

    init(mockID: String, unsent: MockCallGrade? = nil, server: URL, onAPIError: @escaping (Error) -> Void) {
        self.mockID = mockID
        self.unsent = unsent
        _viewModel = State(initialValue: PrepMockViewModel(
            client: APIClientPrepAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
    }

    var body: some View {
        content
            .hxNavigationTitle("Mock result")
            .feedbackContext(FeedbackContext(feature: "Prep", screen: "Mock result"))
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            PrepUnavailableView()
        case .failed(let message):
            PrepFailedView(title: "Couldn't load this mock", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let mocks):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.xl) {
                    switch PrepMockCopy.display(viewModel.result(mockID: mockID)) {
                    case .grading:
                        statusCard(PrepMockCopy.grading, symbol: "hourglass", detail: "Pull down to check again.")
                    case .ungraded:
                        statusCard(PrepMockCopy.ungraded, symbol: "moon.zzz")
                    case .tooShort:
                        statusCard(PrepMockCopy.tooShort, symbol: "phone.down")
                    case .notSent:
                        notSentCard
                    case .notFound:
                        statusCard(PrepMockCopy.notFound, symbol: "questionmark.circle")
                    case .graded(let result):
                        PrepMockGradedView(result: result, ladder: PrepMockKind(rawValue: result.kind).flatMap(mocks.ladder))
                    }
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
        }
    }

    /// The grade request never got through: say so, and offer to send it when this screen has it.
    private var notSentCard: some View {
        PrepRunCard {
            statusTitle(PrepMockCopy.notSent, symbol: "exclamationmark.triangle")
            if let message = viewModel.errorMessage {
                Text(verbatim: message)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if unsent == nil {
                Text(verbatim: PrepMockCopy.notSentNoRequest)
                    .font(BrainStyle.rowSubtitle)
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let unsent {
                Button {
                    Task { await viewModel.sendForGrading(unsent) }
                } label: {
                    Text(verbatim: viewModel.isSendingGrade ? "Sending…" : "Send for grading")
                        .font(AppFont.body(weight: .semibold))
                        .foregroundStyle(viewModel.isSendingGrade ? Color.hxTextSecondary : Color.hxOnAccent)
                        .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget)
                        .background(viewModel.isSendingGrade ? Color.hxSeparator.opacity(0.6) : Color.accentColor,
                                    in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isSendingGrade)
            }
        }
    }

    private func statusTitle(_ title: String, symbol: String) -> some View {
        Label {
            Text(verbatim: title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(HermexPaper.prep.glow)
        }
        .font(AppFont.display(style: .headline))
        .foregroundStyle(Color.hxTextPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }

    private func statusCard(_ title: String, symbol: String, detail: String? = nil) -> some View {
        PrepRunCard {
            statusTitle(title, symbol: symbol)
            if let detail {
                Text(verbatim: detail)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxTextSecondary)
            }
        }
    }
}

/// A graded mock: the score card, then the dimensions, then the points the grader named.
private struct PrepMockGradedView: View {
    let result: PrepMockResult
    let ladder: PrepLadder?

    private var dimNames: Set<String> { Set(result.dims.keys.map { $0.lowercased() }) }

    /// Each dimension, best first, with the hit or miss that names it.
    private var dims: [(name: String, score: Double, note: PrepMockMiss?)] {
        result.dims.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { name, score in
            let named = { (m: PrepMockMiss) in m.point?.lowercased() == name.lowercased() }
            let note = score >= PrepMockResult.passMark
                ? result.hits.first(where: named) : result.misses.first(where: named)
            return (name, score, note)
        }
    }

    /// The frame points, beats and probe points: hits then misses, without the dimensions above.
    private var points: [(hit: Bool, note: PrepMockMiss)] {
        let isPoint = { (m: PrepMockMiss) in !dimNames.contains(m.point?.lowercased() ?? "") }
        return result.hits.filter(isPoint).map { (true, $0) } + result.misses.filter(isPoint).map { (false, $0) }
    }

    var body: some View {
        let paper = HermexPaper.prep
        HXCard(.wash(paper), title: "\(PrepMockCopy.score(result.score ?? 0)) of 5", titleStyle: .title2,
               spacing: BrainStyle.s, kicker: {
            HXChip(paper: paper, symbol: "phone.fill", label: PrepMockCopy.levelTitle(result.level, in: ladder))
        }, content: {
            Text(verbatim: result.passed ? "Passed" : "Not yet: 4 out of 5 passes")
                .font(BrainStyle.rowTitle.weight(.semibold))
                .foregroundStyle(Color.hxTextPrimary)
            if result.passed, let ladder, let next = PrepMockCopy.next(after: result.level, in: ladder) {
                Text(verbatim: next)
                    .font(BrainStyle.rowSubtitle)
                    .foregroundStyle(paper.glow)
            }
        }, footer: { EmptyView() })
        if !dims.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "Scored")
                SectionCard {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(dims.enumerated()), id: \.element.name) { offset, dim in
                            if offset > 0 { PrepRowDivider() }
                            PrepMockPointRow(hit: dim.score >= PrepMockResult.passMark, title: PrepMockCopy.dimTitle(dim.name),
                                             trailing: PrepMockCopy.score(dim.score), note: dim.note)
                        }
                    }
                }
            }
        }
        if !points.isEmpty {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                BrainSectionHeader(title: "Points")
                SectionCard {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(points.enumerated()), id: \.offset) { offset, point in
                            if offset > 0 { PrepRowDivider() }
                            PrepMockPointRow(hit: point.hit, title: point.note.point ?? point.note.concept ?? "Point",
                                             trailing: nil, note: point.note)
                        }
                    }
                }
            }
        }
    }
}

/// A scored dimension or point: ✓ in `hxSuccess` or ◌ in `hxWarning`, its name, the candidate's own
/// words in the serif, and why it missed. Color is never the only signal.
private struct PrepMockPointRow: View {
    let hit: Bool
    let title: String
    let trailing: String?
    let note: PrepMockMiss?

    private var quote: String? { note?.quote.flatMap { $0.isEmpty ? nil : $0 } }
    private var why: String? { note?.why.flatMap { $0.isEmpty ? nil : $0 } }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BrainStyle.s) {
            Image(systemName: hit ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(hit ? Color.hxSuccess : Color.hxWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BrainStyle.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: title)
                        .font(BrainStyle.rowTitle)
                        .foregroundStyle(Color.hxTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: BrainStyle.s)
                    if let trailing {
                        Text(verbatim: trailing)
                            .font(BrainStyle.meta)
                            .foregroundStyle(Color.hxTextSecondary)
                            .monospacedDigit()
                    }
                }
                if let quote {
                    Text(verbatim: "\u{201C}\(quote)\u{201D}")
                        .brainText(.quote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let why {
                    Text(verbatim: why)
                        .font(BrainStyle.meta)
                        .foregroundStyle(Color.hxTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, BrainStyle.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: ([hit ? "Hit" : "Missed", title, trailing, quote, why].compactMap { $0 })
            .joined(separator: ", ")))
    }
}
