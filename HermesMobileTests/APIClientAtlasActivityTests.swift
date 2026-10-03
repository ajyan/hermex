import XCTest
import Foundation
@testable import HermesMobile

final class APIClientAtlasActivityTests: APIClientTestCase {
    func testEventsRequestBuildsPathAndQuery() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/extensions/atlas-activity/sidecar/events")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["before"], "42")
            XCTAssertEqual(query["limit"], "50")
            XCTAssertEqual(query["filter"], "attention")

            return apiTestJSONResponse("""
            {
              "events": [
                {
                  "id": 42,
                  "ts": "2026-10-02T17:08:14Z",
                  "session_id": "session-abc",
                  "source": "tool",
                  "tool_name": "terminal",
                  "summary": "Ran a build",
                  "rule_id": "no-secret-files",
                  "outcome": "blocked",
                  "duration_ms": 120
                },
                {
                  "id": 41,
                  "ts": "2026-10-02T16:55:03Z",
                  "session_id": null,
                  "source": "cron",
                  "tool_name": "cron",
                  "summary": "Weekly summary delivered",
                  "rule_id": null,
                  "outcome": "ok",
                  "duration_ms": null
                }
              ],
              "next_before": 41
            }
            """, for: request)
        }

        let response = try await client.atlasActivity(before: 42, limit: 50, filter: .attention)

        XCTAssertEqual(response.events.count, 2)
        XCTAssertEqual(response.events.first?.id, 42)
        XCTAssertEqual(response.events.first?.sessionID, "session-abc")
        XCTAssertEqual(response.events.first?.toolName, "terminal")
        XCTAssertEqual(response.events.first?.summary, "Ran a build")
        XCTAssertEqual(response.events.first?.ruleID, "no-secret-files")
        XCTAssertEqual(response.events.first?.outcome, .blocked)
        XCTAssertEqual(response.events.first?.durationMs, 120)

        let timestampJSON = #""2026-10-02T17:08:14Z""#
        let expectedTimestamp = try XCTUnwrap(
            AtlasActivityTimestampFormatter.decoder.decode(Date.self, from: Data(timestampJSON.utf8))
        )
        XCTAssertEqual(response.events.first?.ts, expectedTimestamp)

        XCTAssertEqual(response.events.last?.id, 41)
        XCTAssertNil(response.events.last?.sessionID)
        XCTAssertNil(response.events.last?.ruleID)
        XCTAssertEqual(response.events.last?.outcome, .ok)
        XCTAssertNil(response.events.last?.durationMs)

        XCTAssertEqual(response.nextBefore, 41)
    }

    func testUnknownOutcomeAndMissingFieldsDecodeTolerantly() throws {
        let response = try AtlasActivityTimestampFormatter.decoder.decode(
            AtlasActivityPage.self,
            from: Data("""
            {
              "events": [
                {
                  "id": 7,
                  "ts": "2026-10-02T17:08:14Z",
                  "source": "cron",
                  "tool_name": "cron",
                  "summary": "Paused job",
                  "outcome": "paused"
                }
              ],
              "next_before": null
            }
            """.utf8)
        )

        XCTAssertEqual(response.events.count, 1)
        XCTAssertEqual(response.events.first?.id, 7)
        XCTAssertEqual(response.events.first?.outcome, .unknown)
        XCTAssertNil(response.events.first?.durationMs)
        XCTAssertNil(response.events.first?.ruleID)
        XCTAssertNil(response.events.first?.sessionID)
        XCTAssertNil(response.nextBefore)
    }

    func testEventsWithDisplayDecode() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/extensions/atlas-activity/sidecar/events")
            return apiTestJSONResponse("""
            {
              "events": [
                {
                  "id": 10,
                  "ts": "2026-10-02T17:08:14Z",
                  "session_id": "s-1",
                  "source": "tool",
                  "tool_name": "terminal",
                  "summary": "Ran a build",
                  "rule_id": "no-secret-files",
                  "outcome": "blocked",
                  "duration_ms": 120,
                  "display": {
                    "plain_command": "cat .env",
                    "rule_plain": "Do not read secret files",
                    "action_needed": "Remove the .env path from the script"
                  }
                }
              ],
              "next_before": null
            }
            """, for: request)
        }

        let response = try await client.atlasActivity(before: nil, limit: 50, filter: .attention)
        let event = try XCTUnwrap(response.events.first)
        let display = try XCTUnwrap(event.display)
        XCTAssertEqual(display.plainCommand, "cat .env")
        XCTAssertEqual(display.rulePlain, "Do not read secret files")
        XCTAssertEqual(display.actionNeeded, "Remove the .env path from the script")
    }

    func testEventsWithoutDisplayDecodeNil() throws {
        let response = try AtlasActivityTimestampFormatter.decoder.decode(
            AtlasActivityPage.self,
            from: Data("""
            {
              "events": [
                {
                  "id": 11,
                  "ts": "2026-10-02T17:08:14Z",
                  "source": "tool",
                  "tool_name": "terminal",
                  "summary": "Ran a build",
                  "rule_id": "no-secret-files",
                  "outcome": "blocked"
                }
              ],
              "next_before": null
            }
            """.utf8)
        )

        let event = try XCTUnwrap(response.events.first)
        XCTAssertNil(event.display)
        XCTAssertEqual(event.ruleID, "no-secret-files")
        XCTAssertEqual(event.outcome, .blocked)
    }

    func testEpisodesRequestBuildsPathAndDecodes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/extensions/atlas-activity/sidecar/episodes")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://example.test")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query["limit"], "20")
            XCTAssertEqual(query["before"], "7")
            XCTAssertEqual(query["filter"], "attention")

            return apiTestJSONResponse("""
            {
              "episodes": [
                {
                  "rule_id": "no-secret-files",
                  "rule_plain": "Do not read secret files",
                  "session_id": "s-1",
                  "first_ts": "2026-10-02T17:12:00Z",
                  "last_ts": "2026-10-02T17:14:00Z",
                  "count": 6,
                  "tools": ["terminal", "browser_snapshot"],
                  "outcomes": ["ok", "blocked", "ok"],
                  "sample_command": "cat .env",
                  "action_needed": "Remove the .env path from the script",
                  "first_id": 9,
                  "last_id": 4
                }
              ],
              "next_before": 4
            }
            """, for: request)
        }

        let response = try await client.atlasEpisodes(before: 7, limit: 20, filter: .attention)

        XCTAssertEqual(response.episodes.count, 1)
        let episode = try XCTUnwrap(response.episodes.first)
        XCTAssertEqual(episode.ruleID, "no-secret-files")
        XCTAssertEqual(episode.rulePlain, "Do not read secret files")
        XCTAssertEqual(episode.sessionID, "s-1")
        XCTAssertEqual(episode.count, 6)
        XCTAssertEqual(episode.tools, ["terminal", "browser_snapshot"])
        XCTAssertEqual(episode.outcomes, [.ok, .blocked, .ok])
        XCTAssertEqual(episode.sampleCommand, "cat .env")
        XCTAssertEqual(episode.actionNeeded, "Remove the .env path from the script")
        XCTAssertEqual(episode.firstId, 9)
        XCTAssertEqual(episode.lastId, 4)
        XCTAssertEqual(episode.id, 9)
        XCTAssertEqual(response.nextBefore, 4)

        let firstJSON = #""2026-10-02T17:12:00Z""#
        let expectedFirst = try XCTUnwrap(
            AtlasActivityTimestampFormatter.decoder.decode(Date.self, from: Data(firstJSON.utf8))
        )
        XCTAssertEqual(episode.firstTs, expectedFirst)
        let lastJSON = #""2026-10-02T17:14:00Z""#
        let expectedLast = try XCTUnwrap(
            AtlasActivityTimestampFormatter.decoder.decode(Date.self, from: Data(lastJSON.utf8))
        )
        XCTAssertEqual(episode.lastTs, expectedLast)
    }

    func testEpisodesDecodeNullNextBeforeAndEmptyRulePlain() throws {
        let response = try AtlasActivityTimestampFormatter.decoder.decode(
            AtlasEpisodePage.self,
            from: Data("""
            {
              "episodes": [
                {
                  "rule_id": null,
                  "rule_plain": null,
                  "session_id": null,
                  "first_ts": "2026-10-02T17:12:00Z",
                  "last_ts": "2026-10-02T17:12:30Z",
                  "count": 1,
                  "tools": ["terminal"],
                  "outcomes": ["ok"],
                  "sample_command": "ls",
                  "action_needed": "",
                  "first_id": 3,
                  "last_id": 3
                }
              ],
              "next_before": null
            }
            """.utf8)
        )

        let episode = try XCTUnwrap(response.episodes.first)
        XCTAssertNil(episode.ruleID)
        XCTAssertNil(episode.rulePlain)
        XCTAssertNil(episode.sessionID)
        XCTAssertEqual(episode.count, 1)
        XCTAssertEqual(episode.tools, ["terminal"])
        XCTAssertEqual(episode.outcomes, [.ok])
        XCTAssertEqual(episode.actionNeeded, "")
        XCTAssertEqual(episode.id, 3)
        XCTAssertNil(response.nextBefore)
    }

    func testEpisodesEndpointOmitsFilterForAll() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/extensions/atlas-activity/sidecar/episodes")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let names = (components?.queryItems ?? []).map(\.name)
            XCTAssertFalse(names.contains("filter"), "filter should be omitted for .all")
            XCTAssertFalse(names.contains("before"), "before should be omitted when nil")
            XCTAssertEqual(names, ["limit"])
            return apiTestJSONResponse(#"{"episodes": [], "next_before": null}"#, for: request)
        }

        let response = try await client.atlasEpisodes(before: nil, limit: 20, filter: .all)
        XCTAssertTrue(response.episodes.isEmpty)
        XCTAssertNil(response.nextBefore)
    }

    func testRulesRequestBuildsPathAndDecodes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/extensions/atlas-activity/sidecar/rules")
            // hermes-webui rejects sidecar proxy calls without browser provenance.
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://example.test")

            return apiTestJSONResponse("""
            {
              "version": 1,
              "rules": [
                { "id": "no-secret-files", "action": "deny", "description": "Block reads of .env files" },
                { "id": "allow-calendar", "action": "allow", "description": "Calendar reads are fine" }
              ],
              "error": null
            }
            """, for: request)
        }

        let response = try await client.atlasRules()

        XCTAssertEqual(response.rules.count, 2)
        XCTAssertEqual(response.rules.first?.id, "no-secret-files")
        XCTAssertEqual(response.rules.first?.action, "deny")
        XCTAssertEqual(response.rules.first?.description, "Block reads of .env files")
        XCTAssertEqual(response.rules.last?.id, "allow-calendar")
        XCTAssertEqual(response.rules.last?.action, "allow")
        XCTAssertNil(response.error)
    }
}
