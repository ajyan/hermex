import Observation
import SwiftUI

/// One finished workout, pushed as `.bodySession(id)` from a row in Body home's Sessions: Baki's
/// note on it, how the finish check went, and every lift with the sets that were done. A lift's
/// row opens that lift's history.
struct BodySessionView: View {
    @State private var viewModel: BodySessionViewModel

    init(id: String, server: URL, onAPIError: @escaping (Error) -> Void) {
        let client = APIClientBodyAdapter(apiClient: APIClient(baseURL: server))
        _viewModel = State(initialValue: BodySessionViewModel(client: client, id: id, onAPIError: onAPIError))
    }

    private var paper: HermexPaper { .training }

    var body: some View {
        content
            .hxNavigationTitle(BodySessionCopy.title(id: viewModel.id), subtitle: BodySessionCopy.date(id: viewModel.id))
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label { Text(verbatim: "Workout not found") } icon: { Image(systemName: "figure.strengthtraining.traditional") }
            } description: {
                Text(verbatim: "This server doesn't have that workout any more.")
            }
        case .failed(let message):
            HXFailedView(title: "Couldn't load this workout", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let session):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.l) {
                    baki(session)
                    if let check = session.check { howItWent(check, session: session) }
                    lifts(session)
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
        }
    }

    private func baki(_ session: BodySession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Baki")
            HXCard(.wash(paper), spacing: 10) {
                EmptyView()
            } content: {
                if let note = session.coachNote {
                    BakiNoteText(note: note)
                } else {
                    Text(verbatim: "Baki didn't write a note on this one.")
                        .font(AppFont.subheadline())
                        .foregroundStyle(paper.secondaryInk)
                }
            } footer: {
                BakiRule()
                BakiAskRow(title: "Ask Baki about this workout",
                           draft: BodyAskBaki.draft(aboutSession: BodySessionCopy.title(id: session.id),
                                                    date: BodySessionCopy.date(id: session.id)))
            }
        }
    }

    private func howItWent(_ check: BodyCheck, session: BodySession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "How it went", trailing: WorkoutFinishCopy.summary(session, finished: session.finished, now: .now))
            FlowRow(spacing: 8) {
                ForEach(BodySessionCopy.checkChips(check), id: \.self) { label in
                    HXChip(paper: paper, label: label)
                }
            }
            if !check.note.isEmpty {
                // His own words about the workout: the serif is for what he wrote.
                Text(verbatim: check.note)
                    .font(AppFont.serif(style: .body))
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func lifts(_ session: BodySession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Lifts")
            VStack(spacing: 0) {
                ForEach(Array(session.exercises.enumerated()), id: \.element.id) { offset, lift in
                    if offset > 0 { PrepRowDivider().padding(.leading, 14) }
                    NavigationLink(value: ShellPushDestination.bodyLift(lift.id)) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: lift.name)
                                    .font(AppFont.subheadline(weight: .semibold))
                                    .foregroundStyle(Color.hxTextPrimary)
                                Text(verbatim: BodySessionCopy.setsLine(lift))
                                    .font(AppFont.caption())
                                    .monospacedDigit()
                                    .foregroundStyle(Color.hxTextSecondary)
                            }
                            Spacer(minLength: 8)
                            BodyChevron()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .combine)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(verbatim: "Opens this lift's history"))
                }
            }
            .hxCard()
        }
    }
}

/// Loads one saved workout for `BodySessionView`.
@MainActor
@Observable
final class BodySessionViewModel {
    private(set) var state: BrainLoadState<BodySession> = .loading
    let id: String

    @ObservationIgnored private let client: BodyDataClient
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private var generation = 0

    init(client: BodyDataClient, id: String, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.id = id
        self.onAPIError = onAPIError
    }

    /// Loads the workout. A refresh that fails (other than a 404) keeps what's on screen.
    func load() async {
        generation += 1
        let token = generation
        do {
            let session = try await client.session(id: id)
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(session)
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
            guard token == generation, !cancelled else { return }
            onAPIError(error)
            let notFound = (error as? APIError)?.isNotFound ?? false
            if case .loaded = state, !notFound { return }
            state = notFound ? .unavailable : .failed(error.localizedDescription)
        }
    }
}

/// The words a past workout's screen composes from its saved document.
enum BodySessionCopy {
    /// A session id is its date and day, `2026-11-09-pull`: the title is "Pull".
    static func title(id: String) -> String {
        let day = String(id.dropFirst(11))
        return day.isEmpty ? "Workout" : day.capitalized
    }

    /// "Mon, Nov 9" from the id's date.
    static func date(id: String) -> String { BodyHomeCopy.sessionDate(String(id.prefix(10))) }

    /// The done work sets on one line: "115 × 8 8 7 6", "BW × 5 4 3 3", "3 sets" for holds and
    /// carries, and "Skipped" when none were ticked.
    static func setsLine(_ lift: BodyExercise) -> String {
        let done = lift.workSets.filter(\.done)
        guard !done.isEmpty else { return "Skipped" }
        let summary = WorkoutCopy.doneSummary(lift)
        guard BodyMeasure(lift) == .reps else { return summary }
        let weights = Set(done.map(\.weight))
        guard weights.count == 1, let weight = WorkoutCopy.shortWeight(unit: lift.unit, weight: done[0].weight) else {
            return summary
        }
        return "\(weight) × \(summary)"
    }

    /// The finish check as chips: "Solid", "Lower back fine", "Shoulder blades tight", and
    /// "Pain 4 of 10" when he scored it.
    static func checkChips(_ check: BodyCheck) -> [String] {
        var chips = [check.effort.rawValue.capitalized, "Lower back \(check.back.rawValue)",
                     "Shoulder blades \(check.shoulders.rawValue)"]
        if let pain = check.pain { chips.append("Pain \(pain.score) of 10") }
        return chips
    }
}
