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

    func testRulesRequestBuildsPathAndDecodes() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/extensions/atlas-activity/sidecar/rules")

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
