import Charts
import SwiftUI

/// One lift's page (board 3), pushed as `.bodyLift(id)` from a lift row on Body home: its working
/// weight as a step line, and every session with its weight and reps.
struct LiftProgressView: View {
    @State private var viewModel: LiftProgressViewModel
    @ScaledMetric(relativeTo: .caption) private var pipSize: CGFloat = 26

    init(id: String, server: URL, onAPIError: @escaping (Error) -> Void) {
        let client = APIClientBodyAdapter(apiClient: APIClient(baseURL: server))
        _viewModel = State(initialValue: LiftProgressViewModel(client: client, id: id, onAPIError: onAPIError))
    }

    private var paper: HermexPaper { .training }

    var body: some View {
        content
            .hxNavigationTitle(title, subtitle: viewModel.subtitle)
            .background(Color.hxCanvas.ignoresSafeArea())
            .toolbar {
                if case .loaded = viewModel.state {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: ShellPushDestination.bodyPlan) {
                            Image(systemName: "pencil")
                        }
                        .accessibilityLabel(Text(verbatim: "Edit in the plan"))
                    }
                }
            }
            .task { await viewModel.load() }
    }

    private var title: String {
        if case .loaded(let lift) = viewModel.state, !lift.name.isEmpty { return lift.name }
        return "Lift"
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label { Text(verbatim: "Lift not found") } icon: { Image(systemName: "figure.strengthtraining.traditional") }
            } description: {
                Text(verbatim: "This server doesn't have a lift with that name. It may have been removed from the plan.")
            }
        case .failed(let message):
            PrepFailedView(title: "Couldn't load this lift", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let lift):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.l) {
                    workingWeight(lift)
                    sessions(lift)
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
        }
    }

    // MARK: Working weight

    private func workingWeight(_ lift: BodyLift) -> some View {
        let points = LiftProgressCopy.weighted(lift.series)
        return HXCard(.glow(paper), spacing: 12) {
            Text(verbatim: "Working weight")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(paper.glow)
        } content: {
            Text(verbatim: lift.weightLabel)
                .font(AppFont.display(style: .largeTitle, weight: .bold))
                .foregroundStyle(paper.glow)
                .accessibilityLabel(Text(verbatim: lift.up ? "\(lift.weightLabel), going up next time" : lift.weightLabel))
            if let change = LiftProgressCopy.change(lift.series, unit: lift.unit) {
                Text(verbatim: change)
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextPrimary)
            }
            if !points.isEmpty { stepLine(points, lift: lift) }
        } footer: {
            EmptyView()
        }
    }

    /// The weight at each session, held until the next one changes it.
    private func stepLine(_ points: [(date: Date, weight: Double)], lift: BodyLift) -> some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Date", point.date), y: .value("Weight", point.weight))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(paper.glow)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                PointMark(x: .value("Date", point.date), y: .value("Weight", point.weight))
                    .foregroundStyle(paper.glow)
                    .symbolSize(44)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(AppFont.caption2())
                    .foregroundStyle(Color.hxTextSecondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(paper.edge)
                AxisValueLabel().font(AppFont.caption2()).foregroundStyle(Color.hxTextSecondary)
            }
        }
        .frame(height: 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: LiftProgressCopy.chartSummary(lift.series, unit: lift.unit)))
    }

    // MARK: Sessions

    private func sessions(_ lift: BodyLift) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Sessions")
            if lift.sessions.isEmpty {
                Text(verbatim: "No sessions yet. They'll show here once you've finished a workout with this lift.")
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hxCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(lift.sessions.enumerated()), id: \.element.date) { offset, session in
                        if offset > 0 { Divider().padding(.leading, 14) }
                        sessionRow(session)
                    }
                }
                .hxCard()
            }
        }
    }

    private func sessionRow(_ session: BodyLiftSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: BodyHomeCopy.sessionDate(session.date))
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                Spacer(minLength: 8)
                if let note = session.note, !note.isEmpty {
                    Text(verbatim: note)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            FlowRow(spacing: 6) {
                HXChip(paper: paper, label: session.weightLabel)
                ForEach(Array(session.reps.enumerated()), id: \.offset) { _, reps in
                    Text(verbatim: String(reps))
                        .font(AppFont.caption(weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.hxTextPrimary)
                        .frame(minWidth: pipSize, minHeight: pipSize)
                        .background(Color.hxCanvas, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.hxSeparator, lineWidth: 0.5))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: sessionSummary(session)))
    }

    private func sessionSummary(_ session: BodyLiftSession) -> String {
        var parts = [BodyHomeCopy.sessionDate(session.date), session.weightLabel]
        if !session.reps.isEmpty { parts.append(session.reps.map(String.init).joined(separator: ", ") + " reps") }
        if let note = session.note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: ", ")
    }
}
