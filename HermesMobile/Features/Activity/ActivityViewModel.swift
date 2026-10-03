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
    /// events cursor: the two paginates independently.
    private var nextBeforeEpisodes: Int?
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
    /// pagination cursor.
    func reload() async {
        state = .loading
        nextBefore = nil
        nextBeforeEpisodes = nil
        episodes = []
        episodesAvailable = false
        isLoadingMore = false

        do {
            let page = try await client.atlasActivity(before: nil, limit: pageSize, filter: filter)
            apply(page: page)
        } catch is CancellationError {
            // Superseded by a newer reload; that one owns the state.
        } catch {
            state = Self.state(for: error)
        }

        if filter == .attention {
            await reloadEpisodes()
        }
    }

    /// Attention-only: fetch the first page of episodes in the same load.
    /// The events fetch is primary — an episode failure never overrides the
    /// events state. A 404 means the sidecar predates episodes, so the feature
    /// is simply absent.
    private func reloadEpisodes() async {
        do {
            let page = try await client.atlasEpisodes(before: nil, limit: episodePageSize, filter: filter)
            apply(page: page)
        } catch is CancellationError {
            // Superseded by a newer reload; that one owns the state.
        } catch {
            clearEpisodes()
        }
    }

    /// Appends the next older page using the pagination cursor. A no-op when
    /// there is nothing older (`nextBefore` is nil) or a load is in flight.
    /// When episodes are available in attention mode, the next episode page is
    /// appended in the same load; its failure never affects the events state.
    func loadMore() async {
        guard state == .loaded, let cursor = nextBefore, !isLoadingMore else {
            return
        }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await client.atlasActivity(before: cursor, limit: pageSize, filter: filter)
            events.append(contentsOf: page.events)
            nextBefore = page.nextBefore
        } catch is CancellationError {
            // Superseded by a newer reload; that one owns the state.
        } catch {
            keepEvents()
            state = Self.state(for: error)
        }

        if filter == .attention, episodesAvailable, let episodeCursor = nextBeforeEpisodes {
            await loadMoreEpisodes(cursor: episodeCursor)
        }
    }

    private func loadMoreEpisodes(cursor: Int) async {
        do {
            let page = try await client.atlasEpisodes(before: cursor, limit: episodePageSize, filter: filter)
            episodes.append(contentsOf: page.episodes)
            nextBeforeEpisodes = page.nextBefore
        } catch is CancellationError {
            // Superseded by a newer reload; that one owns the state.
        } catch {
            // The events fetch is primary: an episode pagination failure keeps
            // what we have and only stops further episode paging.
            clearEpisodes()
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
    /// (404) or an episode request fails: the view falls back to the events
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
