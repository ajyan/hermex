import Foundation
import Observation

/// Today's Daily Ask, read live from `GET /api/jobs/ask`, with its actions. The Deck's Ask card,
/// the Prep gate and the Brain tile each own one. Only a loaded Ask the server calls `locked` locks
/// Prep: loading, a server without the route (404) and failures all leave Prep open.
@MainActor
@Observable
final class DailyAskModel {
    private(set) var state: BrainLoadState<DailyAsk> = .loading
    /// An action in flight; more taps are ignored until it lands.
    private(set) var pending = false
    private(set) var error: String?

    @ObservationIgnored private let client: DailyAskDataClient
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private var generation = 0

    init(client: DailyAskDataClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.onAPIError = onAPIError
    }

    var isLocked: Bool {
        guard case .loaded(let ask) = state else { return false }
        return ask.locked == true
    }

    /// Whether the card shows the live Ask: only on the deck for the server's today.
    func isLive(for deckDate: String) -> Bool {
        guard case .loaded(let ask) = state else { return false }
        return ask.today == deckDate
    }

    func load() async {
        generation += 1
        let token = generation
        do {
            let ask = try await client.ask()
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(ask)
        } catch {
            guard token == generation, !Self.isCancellation(error) else { return }
            onAPIError(error)
            let notFound = (error as? APIError)?.isNotFound ?? false
            if case .loaded = state, !notFound { return }  // a failed reload keeps the Ask on screen
            state = notFound ? .unavailable : .failed(error.localizedDescription)
        }
    }

    /// Whether the server saved it: the Pass sheet stays open (keeping its reason) when not.
    @discardableResult
    func act(_ action: DailyAskAction) async -> Bool {
        guard case .loaded(let current) = state, !pending else { return false }
        pending = true
        error = nil
        defer { pending = false }
        do {
            let next = try await client.act(action.request(asOf: current.today))
            generation += 1  // a load that started earlier must not overwrite this answer
            state = .loaded(next)
            return true
        } catch {
            onAPIError(error)
            if case .http(409, _)? = error as? APIError {
                await load()  // the server's day moved on: show its today instead of saving to the wrong one
                self.error = "The day changed. Nothing was saved; this is today's Ask."
                return false
            }
            self.error = "Couldn't save. Try again."
            return false
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
