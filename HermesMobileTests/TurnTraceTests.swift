import XCTest
@testable import HermesMobile

final class TurnTraceTests: XCTestCase {
    private let base = URL(string: "https://example.test")!

    private func makeTrace(startedAt: Date = .now, start: ContinuousClock.Instant) -> TurnTrace {
        var rng = SystemRandomNumberGenerator()
        return TurnTrace(baseURL: base, startedAt: startedAt, start: start, using: &rng)
    }

    func testTraceparentFormat() {
        let a = TurnTrace(baseURL: base)
        let b = TurnTrace(baseURL: base)
        XCTAssertNotNil(a.traceparent.range(of: "^00-[0-9a-f]{32}-[0-9a-f]{16}-01$", options: .regularExpression))
        XCTAssertNotEqual(a.traceparent, b.traceparent)
    }

    func testConnectionClassification() {
        XCTAssertEqual(TurnTrace.Connection.classify(host: "localhost"), .localhost)
        XCTAssertEqual(TurnTrace.Connection.classify(host: "127.0.0.1"), .localhost)
        XCTAssertEqual(TurnTrace.Connection.classify(host: "::1"), .localhost)
        XCTAssertEqual(TurnTrace.Connection.classify(host: "mac.tail1234.ts.net"), .tailscale)
        XCTAssertEqual(TurnTrace.Connection.classify(host: "100.101.2.3"), .tailscale)
        XCTAssertEqual(TurnTrace.Connection.classify(host: "100.128.0.1"), .tunnel)
        XCTAssertEqual(TurnTrace.Connection.classify(host: "hermes.example.com"), .tunnel)
        XCTAssertEqual(TurnTrace.Connection.classify(host: nil), .tunnel)
    }

    func testMarksFirstCallWins() {
        let start = ContinuousClock.now
        var trace = makeTrace(start: start)
        trace.markFirstToken(at: start + .milliseconds(100))
        trace.markFirstToken(at: start + .milliseconds(900))
        let upload = trace.upload(outcome: .done, endedAt: start + .milliseconds(1000))
        XCTAssertEqual(upload.marksMs.firstToken, 100)
    }

    func testUploadMillisecondsAndSnakeCaseJSON() throws {
        let start = ContinuousClock.now
        var trace = makeTrace(startedAt: Date(timeIntervalSince1970: 1_700_000_000), start: start)
        trace.reconnects = 1
        trace.backgrounded = true
        trace.detached = true
        trace.markHeaders(at: start + .milliseconds(312))
        trace.markFirstToken(at: start + .milliseconds(2410))
        trace.markRendered(at: start + .milliseconds(2462))
        let upload = trace.upload(outcome: .done, endedAt: start + .milliseconds(6400))

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(upload)) as? [String: Any])
        let marks = try XCTUnwrap(json["marks_ms"] as? [String: Any])
        XCTAssertEqual(marks["headers"] as? Int, 312)
        XCTAssertEqual(marks["first_token"] as? Int, 2410)
        XCTAssertEqual(marks["rendered"] as? Int, 2462)
        XCTAssertEqual(marks["end"] as? Int, 6400)
        XCTAssertEqual((json["start_unix_nano"] as? NSNumber)?.int64Value, 1_700_000_000_000_000_000)
        XCTAssertEqual(json["traceparent"] as? String, trace.traceparent)
        XCTAssertEqual(json["connection"] as? String, "tunnel")
        XCTAssertEqual(json["outcome"] as? String, "done")
        XCTAssertEqual(json["reconnects"] as? Int, 1)
        XCTAssertEqual(json["backgrounded"] as? Bool, true)
        XCTAssertEqual(json["detached"] as? Bool, true)
    }

    func testVoiceFieldsEncodeOnlyWhenSet() throws {
        let start = ContinuousClock.now
        var upload = makeTrace(start: start).upload(outcome: .done, endedAt: start + .milliseconds(50))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(upload)) as? [String: Any])
        XCTAssertNil(json["voice"])
        XCTAssertNil(json["speech_end_to_audible_ms"])
        XCTAssertNil(json["barge_in_ms"])

        upload.voice = true
        upload.speechEndToAudibleMs = 2840
        upload.bargeInMs = 920
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(upload)) as? [String: Any])
        XCTAssertEqual(json["voice"] as? Bool, true)
        XCTAssertEqual(json["speech_end_to_audible_ms"] as? Int, 2840)
        XCTAssertEqual(json["barge_in_ms"] as? Int, 920)
    }

    func testMissingMarksEncodeAsNull() throws {
        let start = ContinuousClock.now
        let trace = makeTrace(start: start)
        let upload = trace.upload(outcome: .cancelled, endedAt: start + .milliseconds(50))
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(upload)) as? [String: Any])
        let marks = try XCTUnwrap(json["marks_ms"] as? [String: Any])
        XCTAssertTrue(marks["headers"] is NSNull)
        XCTAssertTrue(marks["first_token"] is NSNull)
        XCTAssertTrue(marks["rendered"] is NSNull)
        XCTAssertEqual(marks["end"] as? Int, 50)
    }
}
