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
            method: "GET"
        )
        return try AtlasActivityTimestampFormatter.decoder.decode(AtlasActivityPage.self, from: data)
    }

    /// The sidecar's current ruleset, or the sidecar's own error reason when
    /// the rules could not be loaded.
    func atlasRules() async throws -> AtlasRulesSnapshot {
        let data = try await sendData(endpoint: .atlasRules, method: "GET")
        return try AtlasActivityTimestampFormatter.decoder.decode(AtlasRulesSnapshot.self, from: data)
    }
}
