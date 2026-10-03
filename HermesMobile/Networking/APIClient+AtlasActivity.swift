import Foundation

extension APIClient {
    /// One page of Atlas activity events, newest first. `before` is the cursor
    /// from a previous page's `nextBefore`; `limit` defaults to the UI's page
    /// size. The sidecar is proxied under `/api/extensions/atlas-activity/` so
    /// it shares the app's auth, and 403/404/502/503 reach this method as
    /// `APIError.http` — the view model maps them to distinct states.
    func atlasActivity(
        before: Int? = nil,
        limit: Int = 50,
        filter: AtlasActivityFilter = .all
    ) async throws -> AtlasActivityPage {
        let data = try await sendData(
            endpoint: .atlasActivityEvents(before: before, limit: limit, filter: filter),
            method: "GET",
            encodedBody: nil,
            extraHeaders: sidecarProvenanceHeaders
        )
        return try AtlasActivityTimestampFormatter.decoder.decode(AtlasActivityPage.self, from: data)
    }

    /// One page of attention episodes, newest first. `before` is the cursor
    /// from a previous page's `nextBefore`. Shares the events endpoint's auth
    /// and error surface: 404 means the sidecar predates episodes, which the
    /// view model treats as the feature being absent.
    func atlasEpisodes(
        before: Int? = nil,
        limit: Int = 20,
        filter: AtlasActivityFilter = .attention
    ) async throws -> AtlasEpisodePage {
        let data = try await sendData(
            endpoint: .atlasActivityEpisodes(before: before, limit: limit, filter: filter),
            method: "GET",
            encodedBody: nil,
            extraHeaders: sidecarProvenanceHeaders
        )
        return try AtlasActivityTimestampFormatter.decoder.decode(AtlasEpisodePage.self, from: data)
    }

    /// The sidecar's current ruleset, or the sidecar's own error reason when
    /// the rules could not be loaded.
    func atlasRules() async throws -> AtlasRulesSnapshot {
        let data = try await sendData(
            endpoint: .atlasRules,
            method: "GET",
            encodedBody: nil,
            extraHeaders: sidecarProvenanceHeaders
        )
        return try AtlasActivityTimestampFormatter.decoder.decode(AtlasRulesSnapshot.self, from: data)
    }

    /// hermes-webui only proxies `/api/extensions/<id>/sidecar/*` for requests
    /// carrying same-origin browser provenance (it answers 403 otherwise, before
    /// any consent check), so the app sends its own server origin as `Origin`.
    private var sidecarProvenanceHeaders: [String: String] {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return [:] }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string.map { ["Origin": $0] } ?? [:]
    }
}
