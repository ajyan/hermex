import Foundation
import Observation

/// The network surface `ActivityViewModel` needs, so tests can drive it with a
/// scripted client. `APIClient` is non-`Sendable` (an actor), so the view model
/// wraps it in a `Sendable` shim (see `ActivityViewModel`'s init) rather than
/// conforming it here.
protocol AtlasActivityDataClient: Sendable {
    func atlasActivity(before: Int?, limit: Int, filter: AtlasActivityFilter) async throws -> AtlasActivityPage
    func atlasEpisodes(before: Int?, limit: Int, filter: AtlasActivityFilter) async throws -> AtlasEpisodePage
    func atlasRules() async throws -> AtlasRulesSnapshot
}

/// What the activity screen is showing. `loaded` and `serviceDown` both keep
/// `events` populated — `serviceDown` is the last good page with a banner.
enum ActivityLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case notInstalled
    case notConsented
    case serviceDown
    case failed(String)
}

@MainActor
@Observable
final class ActivityViewModel {
    private(set) var events: [AtlasActivityEvent] = []
    var filter: AtlasActivityFilter = .all
    private(set) var state: ActivityLoadState = .idle
    private(set) var rulesError: String?
    private(set) var isLoadingMore = false
    private(set) var episodes: [AtlasEpisode] = []
    private(set) var episodesAvailable: Bool = false

    /// Cursor for the next (older) page: the last page's `nextBefore`.
    private var nextBefore: Int?
    /// Episode cursor for the next (older) episode page, separate from the
    /// events cursor: the two paginate independently.
    private var nextBeforeEpisodes: Int?
    /// Bumped by every `reload()`. A request whose generation is no longer
    /// current was superseded (usually by a filter change) and its result is
    /// dropped, so a slow response for the old filter never lands on screen.
    private var generation = 0
    private let client: any AtlasActivityDataClient
    /// Page size for the sidecar's `limit` parameter.
    private let pageSize: Int = 50
    /// Page size for the sidecar's episode `limit` parameter.
    private let episodePageSize: Int = 20

    init(client: any AtlasActivityDataClient) {
        self.client = client
    }

    /// Wraps `APIClient` in a `Sendable` shim: the client is an actor and not
    /// itself `Sendable`, but a closure capturing it is, so the protocol sees
    /// a `Sendable` value without `APIClient` conforming.
    init(apiClient: APIClient) {
        let apiClient = apiClient
        self.client = APIClientAtlasActivityAdapter(apiClient: apiClient)
    }

    /// Replaces the whole list with the first page for `filter`, resetting the
    /// pagination cursor. Supersedes any reload or page load still in flight.
    func reload() async {
        generation += 1
        let requestGeneration = generation
        let requestFilter = filter
        state = .loading
        nextBefore = nil
        nextBeforeEpisodes = nil
        episodes = []
        episodesAvailable = false
        isLoadingMore = false

        do {
            let page = try await client.atlasActivity(before: nil, limit: pageSize, filter: requestFilter)
            guard requestGeneration == generation else { return }
            apply(page: page)
        } catch {
            guard requestGeneration == generation, !Self.isCancellationError(error) else { return }
            state = Self.state(for: error)
        }

        if requestFilter == .attention {
            await reloadEpisodes(filter: requestFilter, generation: requestGeneration)
        }
    }

    /// Attention-only: fetch the first page of episodes in the same load.
    /// The events fetch is primary — an episode failure never overrides the
    /// events state. A 404 means the sidecar predates episodes, so the feature
    /// is simply absent.
    private func reloadEpisodes(filter: AtlasActivityFilter, generation requestGeneration: Int) async {
        do {
            let page = try await client.atlasEpisodes(before: nil, limit: episodePageSize, filter: filter)
            guard requestGeneration == generation else { return }
            apply(page: page)
        } catch {
            guard requestGeneration == generation, !Self.isCancellationError(error) else { return }
            clearEpisodes()
        }
    }

    /// Appends the next older page of events and, when episodes are shown in
    /// attention mode, of episodes. Each pages on its own cursor, so one can
    /// keep paging after the other runs out. A no-op when neither has anything
    /// older or a load is in flight. An episode failure never affects the
    /// events state.
    func loadMore() async {
        let episodeCursor = filter == .attention && episodesAvailable ? nextBeforeEpisodes : nil
        guard state == .loaded, !isLoadingMore, nextBefore != nil || episodeCursor != nil else {
            return
        }

        let requestGeneration = generation
        let requestFilter = filter
        isLoadingMore = true
        defer {
            // A reload in between already reset this and may own a newer load.
            if requestGeneration == generation { isLoadingMore = false }
        }

        if let cursor = nextBefore {
            do {
                let page = try await client.atlasActivity(before: cursor, limit: pageSize, filter: requestFilter)
                guard requestGeneration == generation else { return }
                events.append(contentsOf: page.events)
                nextBefore = page.nextBefore
            } catch {
                guard requestGeneration == generation else { return }
                if !Self.isCancellationError(error) {
                    keepEvents()
                    state = Self.state(for: error)
                }
            }
        }

        if let episodeCursor {
            await loadMoreEpisodes(cursor: episodeCursor, filter: requestFilter, generation: requestGeneration)
        }
    }

    private func loadMoreEpisodes(cursor: Int, filter: AtlasActivityFilter, generation requestGeneration: Int) async {
        do {
            let page = try await client.atlasEpisodes(before: cursor, limit: episodePageSize, filter: filter)
            guard requestGeneration == generation else { return }
            episodes.append(contentsOf: page.episodes)
            nextBeforeEpisodes = page.nextBefore
        } catch {
            guard requestGeneration == generation, !Self.isCancellationError(error) else { return }
            // The events fetch is primary: an episode pagination failure keeps
            // what we have and only stops further episode paging.
            nextBeforeEpisodes = nil
        }
    }

    /// Fetches the sidecar's ruleset. Failures here are not fatal for the
    /// screen: the rules panel is a bonus, so every error path leaves
    /// `state` (the events) alone and only records `rulesError`.
    func loadRules() async {
        do {
            let snapshot = try await client.atlasRules()
            rulesError = snapshot.error
        } catch {
            rulesError = error.localizedDescription
        }
    }

    // MARK: - State transitions

    private func apply(page: AtlasActivityPage) {
        events = page.events
        nextBefore = page.nextBefore
        state = .loaded
    }

    private func apply(page: AtlasEpisodePage) {
        episodes = page.episodes
        nextBeforeEpisodes = page.nextBefore
        episodesAvailable = true
    }

    /// Clears episode state. Used when the sidecar does not serve episodes
    /// (404) or the first episode request fails: the view falls back to the events
    /// list, which is always loaded independently.
    private func clearEpisodes() {
        episodes = []
        nextBeforeEpisodes = nil
        episodesAvailable = false
    }

    /// A 502/503 means the sidecar is briefly unreachable: keep the last good
    /// page on screen (the view shows a banner) instead of clearing it.
    private func keepEvents() {
        // Intentionally a no-op on `events` — the last page stays put.
    }

    /// Cancellation arrives as `CancellationError` or as a (possibly
    /// `APIError.network`-wrapped) `URLError.cancelled` from URLSession.
    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let underlying: Error
        if case APIError.network(let wrapped) = error {
            underlying = wrapped
        } else {
            underlying = error
        }

        guard let urlError = underlying as? URLError else { return false }
        return urlError.code == .cancelled
    }

    private static func state(for error: Error) -> ActivityLoadState {
        if case APIError.http(let statusCode, _) = error {
            switch statusCode {
            case 403:
                return .notConsented
            case 404:
                return .notInstalled
            case 502, 503:
                return .serviceDown
            default:
                return .failed(error.localizedDescription)
            }
        }

        if case APIError.decoding = error {
            return .failed(error.localizedDescription)
        }

        return .failed(error.localizedDescription)
    }
}

/// Adapts `APIClient` to `AtlasActivityDataClient`. Capturing the actor in a
/// class stored property is fine: actors are reference types and the protocol
/// only ever calls its async methods.
private struct APIClientAtlasActivityAdapter: AtlasActivityDataClient {
    let apiClient: APIClient

    func atlasActivity(before: Int?, limit: Int, filter: AtlasActivityFilter) async throws -> AtlasActivityPage {
        try await apiClient.atlasActivity(before: before, limit: limit, filter: filter)
    }

    func atlasEpisodes(before: Int?, limit: Int, filter: AtlasActivityFilter) async throws -> AtlasEpisodePage {
        try await apiClient.atlasEpisodes(before: before, limit: limit, filter: filter)
    }

    func atlasRules() async throws -> AtlasRulesSnapshot {
        try await apiClient.atlasRules()
    }
}
