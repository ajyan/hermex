import Observation
import SwiftUI

/// One finished workout, pushed as `.bodySession(id)` from a row in Body home's Sessions: how the
/// finish check went, every lift set by set against the time before, and Baki's note on it. A
/// lift's row opens that lift's history. A workout that saved itself has no check yet: it says so
/// and offers to reopen it, and every return to this screen reads the workout again.
struct BodySessionView: View {
    @State private var viewModel: BodySessionViewModel

    init(id: String, server: URL, onAPIError: @escaping (Error) -> Void) {
        let client = APIClientBodyAdapter(apiClient: APIClient(baseURL: server))
        _viewModel = State(initialValue: BodySessionViewModel(client: client, id: id, onAPIError: onAPIError))
    }

    private var paper: HermexPaper { .training }

    var body: some View {
        content
            .hxLoadSwap(viewModel.state.loadSwapPhase)
            .hxNavigationTitle(BodySessionCopy.title(id: viewModel.id), subtitle: BodySessionCopy.date(id: viewModel.id))
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            HXModuleHomePlaceholder(name: "Workout")
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
                    howItWent(session)
                    LiftResultsCard(session: session, frame: .past, opensLifts: true)
                    baki(session)
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

    /// The finish check as chips; for a workout that saved itself, that it did and the way back in;
    /// for one he reopened and left, the way to carry on.
    @ViewBuilder
    private func howItWent(_ session: BodySession) -> some View {
        switch BodySessionCopy.outcome(session) {
        case .checked(let check):
            VStack(alignment: .leading, spacing: 8) {
                HXSectionHeader(title: "How it went", trailing: summary(session))
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
        case .savedItself:
            VStack(alignment: .leading, spacing: 8) {
                HXSectionHeader(title: "How it went", trailing: summary(session))
                FlowRow(spacing: 8) {
                    HXChip(paper: paper, symbol: "clock", label: "Saved itself")
                }
                footnote(BodySessionCopy.savedItselfNote(finished: session.finished))
                reopenLink("Reopen workout", hint: "Opens the workout to add sets and finish it", id: session.id)
            }
        case .open:
            VStack(alignment: .leading, spacing: 8) {
                HXSectionHeader(title: "How it went")
                footnote(BodySessionCopy.openNote)
                reopenLink("Continue workout", hint: "Opens the workout where you left it", id: session.id)
            }
        case .unchecked:
            EmptyView()
        }
    }

    private func summary(_ session: BodySession) -> String {
        WorkoutFinishCopy.summary(session, finished: session.finished, now: .now)
    }

    private func footnote(_ text: String) -> some View {
        Text(verbatim: text)
            .font(AppFont.footnote())
            .foregroundStyle(.hxSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    /// The way back into the live workout: a neutral secondary capsule on the canvas, like the
    /// workout's own "Finish early".
    private func reopenLink(_ title: String, hint: String, id: String) -> some View {
        NavigationLink(value: ShellPushDestination.bodyReopen(id)) {
            Text(verbatim: title).bodyTapHeight()
        }
        .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
        .accessibilityHint(Text(verbatim: hint))
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

    /// What the "How it went" section has to show for a saved workout.
    enum Outcome: Equatable {
        /// He finished it and answered the check.
        case checked(BodyCheck)
        /// The server closed it at his last set; it can be reopened.
        case savedItself
        /// Reopened and not finished again yet.
        case open
        /// Finished with no check on file: the section is left out.
        case unchecked
    }

    static func outcome(_ session: BodySession) -> Outcome {
        if session.finished == nil { return .open }
        if session.autoFinished { return .savedItself }
        return session.check.map(Outcome.checked) ?? .unchecked
    }

    /// "It saved itself at your last set, 8:24 AM. Reopen it to add sets or say how it went." The
    /// time is left out when the finish stamp doesn't read.
    static func savedItselfNote(finished: String?, locale: Locale = .current) -> String {
        let time = finished.flatMap(WorkoutFinishCopy.date).map { date in
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return ", \(formatter.string(from: date))"
        } ?? ""
        return "It saved itself at your last set\(time). Reopen it to add sets or say how it went."
    }

    /// Under a workout he reopened and left before finishing.
    static let openNote = "This workout is open again. Finish it to say how it went, or it saves itself two hours after your last set."

    /// The finish check as chips: "Solid", "Lower back fine", "Shoulder blades tight", and
    /// "Pain 4 of 10" when he scored it.
    static func checkChips(_ check: BodyCheck) -> [String] {
        var chips = [check.effort.rawValue.capitalized, "Lower back \(check.back.rawValue)",
                     "Shoulder blades \(check.shoulders.rawValue)"]
        if let pain = check.pain { chips.append("Pain \(pain.score) of 10") }
        return chips
    }
}
