import Foundation

/// Timings and identity for one chat turn. `ChatViewModel.sendMessage` creates it, `ChatStreamCoordinator`
/// holds it while the response streams, and `upload(outcome:endedAt:)` turns it into the body POSTed to
/// `/api/telemetry/turn`. Metadata only: no message text, titles, paths or URLs are recorded.
struct TurnTrace: Sendable {
    enum Connection: String, Encodable, Sendable {
        case localhost, tailscale, tunnel

        /// `localhost`, `127.0.0.1` and `::1` are local; `*.ts.net` and IPv4 in 100.64.0.0/10 are Tailscale;
        /// everything else is treated as a tunnel.
        static func classify(host: String?) -> Connection {
            guard let host = host?.lowercased(), !host.isEmpty else { return .tunnel }
            if host == "localhost" || host == "127.0.0.1" || host == "::1" { return .localhost }
            if host.hasSuffix(".ts.net") { return .tailscale }
            let octets = host.split(separator: ".", omittingEmptySubsequences: false)
            if octets.count == 4,
               let first = Int(octets[0]), let second = Int(octets[1]),
               first == 100, (64...127).contains(second) {
                return .tailscale
            }
            return .tunnel
        }
    }

    enum Outcome: String, Encodable, Sendable { case done, error, cancelled }

    /// 32 lowercase hex characters.
    let traceID: String
    /// 16 lowercase hex characters.
    let spanID: String
    let connection: Connection
    var reconnects: Int = 0
    var backgrounded: Bool = false
    /// The chat dropped its stream before the turn ended because the user left it (navigated away or
    /// the app's background time ran out). The marks after that point measure when the user came back
    /// and the replay caught up, not the response's latency.
    var detached: Bool = false

    private let startedAt: Date
    private let start: ContinuousClock.Instant
    private var headers: ContinuousClock.Instant?
    private var firstToken: ContinuousClock.Instant?
    private var rendered: ContinuousClock.Instant?

    var traceparent: String { "00-\(traceID)-\(spanID)-01" }

    init<R: RandomNumberGenerator>(
        baseURL: URL,
        startedAt: Date = .now,
        start: ContinuousClock.Instant = .now,
        using rng: inout R
    ) {
        self.traceID = Self.randomHex(byteCount: 16, using: &rng)
        self.spanID = Self.randomHex(byteCount: 8, using: &rng)
        self.connection = Connection.classify(host: baseURL.host)
        self.startedAt = startedAt
        self.start = start
    }

    init(baseURL: URL) {
        var rng = SystemRandomNumberGenerator()
        self.init(baseURL: baseURL, using: &rng)
    }

    /// Lets the per-token and per-flush paths skip the clock read once the mark is set.
    var hasMarkedFirstToken: Bool { firstToken != nil }
    var hasMarkedRendered: Bool { rendered != nil }

    mutating func markHeaders(at instant: ContinuousClock.Instant) {
        if headers == nil { headers = instant }
    }

    mutating func markFirstToken(at instant: ContinuousClock.Instant) {
        if firstToken == nil { firstToken = instant }
    }

    mutating func markRendered(at instant: ContinuousClock.Instant) {
        if rendered == nil { rendered = instant }
    }

    func upload(outcome: Outcome, endedAt: ContinuousClock.Instant) -> TurnTraceUpload {
        TurnTraceUpload(
            traceparent: traceparent,
            startUnixNano: Int64(startedAt.timeIntervalSince1970 * 1_000_000_000),
            connection: connection,
            outcome: outcome,
            reconnects: reconnects,
            backgrounded: backgrounded,
            detached: detached,
            marksMs: TurnTraceUpload.Marks(
                headers: headers.map(milliseconds),
                firstToken: firstToken.map(milliseconds),
                rendered: rendered.map(milliseconds),
                end: milliseconds(endedAt)
            )
        )
    }

    private func milliseconds(_ instant: ContinuousClock.Instant) -> Int {
        let parts = start.duration(to: instant).components
        return max(0, Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000))
    }

    /// An all-zero ID is invalid in W3C trace context, so a zero draw is redrawn.
    private static func randomHex<R: RandomNumberGenerator>(byteCount: Int, using rng: inout R) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        repeat {
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &rng) }
        } while bytes.allSatisfy { $0 == 0 }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Body of `POST /api/telemetry/turn`. Encoded with `.convertToSnakeCase` (`start_unix_nano`, `marks_ms`,
/// `first_token`). `Marks` values are milliseconds since the turn started.
struct TurnTraceUpload: Encodable, Equatable, Sendable {
    struct Marks: Encodable, Equatable, Sendable {
        var headers: Int?
        var firstToken: Int?
        var rendered: Int?
        var end: Int

        /// Absent marks encode as explicit `null`, not as a missing key.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(headers, forKey: .headers)
            try container.encode(firstToken, forKey: .firstToken)
            try container.encode(rendered, forKey: .rendered)
            try container.encode(end, forKey: .end)
        }

        private enum CodingKeys: String, CodingKey { case headers, firstToken, rendered, end }
    }

    let traceparent: String
    let startUnixNano: Int64
    let connection: TurnTrace.Connection
    let outcome: TurnTrace.Outcome
    let reconnects: Int
    let backgrounded: Bool
    let detached: Bool
    let marksMs: Marks
    /// Voice-call turns only; absent otherwise. `speechEndToAudibleMs` runs from the end of the user's
    /// speech to the reply's first audible word, `bargeInMs` from speech over the reply to silence.
    var voice: Bool?
    var speechEndToAudibleMs: Int?
    var bargeInMs: Int?
}
