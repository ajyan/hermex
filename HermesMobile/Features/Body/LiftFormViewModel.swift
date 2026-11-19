import Foundation
import Observation

/// A lift's Form page: its cue card from the lift's detail, and picking which cue Baki uses. A
/// pick shows at once and goes back to the old cue if the server doesn't take it.
@MainActor
@Observable
final class LiftFormViewModel {
    private(set) var state: BrainLoadState<BodyLift> = .loading
    /// The cue whose pick is on its way to the server; other taps wait for it.
    private(set) var picking: Int?
    /// Why the last pick didn't take; cleared by the next one.
    private(set) var pickError: String?

    @ObservationIgnored private let client: BodyDataClient
    @ObservationIgnored private let id: String
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private var generation = 0

    init(client: BodyDataClient, id: String, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.id = id
        self.onAPIError = onAPIError
    }

    var lift: BodyLift? {
        if case .loaded(let lift) = state { return lift }
        return nil
    }

    /// Loads the lift. A refresh that fails (other than a 404) keeps what's on screen.
    func load() async {
        generation += 1
        let token = generation
        do {
            let lift = try await client.lift(id: id)
            guard token == generation, !Task.isCancelled else { return }
            // A pick still in flight owns the form until it answers.
            if picking != nil, let form = self.lift?.form {
                var kept = lift
                kept.form = form
                state = .loaded(kept)
            } else {
                state = .loaded(lift)
            }
        } catch {
            guard token == generation, !Self.isCancellation(error) else { return }
            onAPIError(error)
            let notFound = (error as? APIError)?.isNotFound ?? false
            if case .loaded = state, !notFound { return }
            state = notFound ? .unavailable : .failed(error.localizedDescription)
        }
    }

    /// Makes cue `index` the one Baki uses. The card shows it at once; the server's answer replaces
    /// the form, and a failure puts the old cue back.
    func pick(_ index: Int) async {
        guard picking == nil, var lift, let before = lift.form, before.cues.indices.contains(index),
              before.picked != index else { return }
        picking = index
        pickError = nil
        defer { picking = nil }
        lift.form?.picked = index
        state = .loaded(lift)
        do {
            // The cue card's key, which on an alternate week is not the lift's own id.
            let form = try await client.pickCue(lift: before.lift ?? lift.id, index: index)
            replaceForm(form)
        } catch {
            replaceForm(before)
            guard !Self.isCancellation(error) else { return }
            onAPIError(error)
            pickError = "Couldn't save that cue. Try again."
        }
    }

    /// Lands a form on the lift that is on screen now, which a refresh may have replaced meanwhile.
    private func replaceForm(_ form: BodyForm) {
        guard var lift else { return }
        var form = form
        // The lift's areas ride on the page, not on every pick's answer.
        if form.loads.isEmpty { form.loads = lift.form?.loads ?? [] }
        lift.form = form
        state = .loaded(lift)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// The words a lift's Form page composes.
enum LiftFormCopy {
    /// The areas the lift loads, from the form or the lift, whichever the server sent.
    static func loads(_ lift: BodyLift) -> [String] {
        if let loads = lift.form?.loads, !loads.isEmpty { return loads }
        return lift.loads
    }

    /// A cue row for VoiceOver: "Cue 1: Pull the bar to your chest".
    static func cueLabel(_ cue: String, index: Int) -> String {
        "Cue \(index + 1): \(cue)"
    }
}
