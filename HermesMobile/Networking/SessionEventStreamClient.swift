import Foundation
import LDSwiftEventSource

/// How one `/api/sessions/<id>/events` connection ended.
enum SessionEventStreamEnd: Equatable {
    /// The server closed it, as it does after each run's terminal event.
    case closed
    /// The connection dropped or the server failed (network, timeout, 5xx).
    case failed
    /// The server refused it with this client error, such as a 404 from a server without the route.
    case rejected(Int)
}

/// One connection to a session's events stream. `onEventID` gets each event's SSE id
/// (`<stream_id>:<seq>`); `onEnd` fires once when the connection ends on its own, never after `stop()`.
@MainActor
protocol SessionEventStreaming: AnyObject {
    func start(
        url: URL,
        lastEventID: String?,
        onEventID: @escaping @MainActor (String) -> Void,
        onEnd: @escaping @MainActor (SessionEventStreamEnd) -> Void
    )
    func stop()
}

@MainActor
final class SessionEventStreamClient: SessionEventStreaming {
    private let baseConfiguration: URLSessionConfiguration
    private let customHeaderProvider: @MainActor () -> [CustomHeader]
    private var eventSource: EventSource?
    /// The connection whose callbacks may still reach the caller.
    private var connection: UUID?

    init(
        urlSessionConfiguration: URLSessionConfiguration = .default,
        customHeaderProvider: @escaping @MainActor () -> [CustomHeader] = { CustomHeaderStore.shared.snapshot() }
    ) {
        baseConfiguration = urlSessionConfiguration
        self.customHeaderProvider = customHeaderProvider
    }

    func start(
        url: URL,
        lastEventID: String?,
        onEventID: @escaping @MainActor (String) -> Void,
        onEnd: @escaping @MainActor (SessionEventStreamEnd) -> Void
    ) {
        stop()
        let id = UUID()
        connection = id
        let finish: @MainActor (SessionEventStreamEnd) -> Void = { [weak self] end in
            guard let self, self.connection == id else { return }
            self.stop()
            onEnd(end)
        }
        let handler = Handler { [weak self] eventID in
            guard self?.connection == id else { return }
            onEventID(eventID)
        }
        var config = EventSource.Config(handler: handler, url: url)
        // Sent as `Last-Event-Id`: the server replays the session journal after it.
        config.lastEventId = lastEventID ?? ""
        // Every end, a clean close included, goes to the caller, which owns the reconnect.
        config.connectionErrorHandler = { error in
            let end: SessionEventStreamEnd
            if error is StreamClosedByServerError {
                end = .closed
            } else if let error = error as? UnsuccessfulResponseError, (400..<500).contains(error.responseCode) {
                end = .rejected(error.responseCode)
            } else {
                end = .failed
            }
            Task { @MainActor in finish(end) }
            return .shutdown
        }
        config.headers = StreamSession.headers(for: url, custom: customHeaderProvider())
        config.urlSessionConfiguration = StreamSession.configuration(from: baseConfiguration)

        let source = EventSource(config: config)
        eventSource = source
        source.start()
    }

    func stop() {
        connection = nil
        eventSource?.stop()
        eventSource = nil
    }

    private final class Handler: EventHandler {
        private let onEventID: @MainActor (String) -> Void

        init(onEventID: @escaping @MainActor (String) -> Void) {
            self.onEventID = onEventID
        }

        func onOpened() {}
        func onClosed() {}
        func onComment(comment: String) {}
        func onError(error: Error) {}

        func onMessage(eventType: String, messageEvent: MessageEvent) {
            let eventID = messageEvent.lastEventId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !eventID.isEmpty else { return }
            Task { @MainActor in onEventID(eventID) }
        }
    }
}

/// Keeps one session's events stream open and reports the stream id of every run event it
/// carries. The server closes the stream after each run, so this reconnects from the last
/// event id at once, backing off only when connections fail. A client error (a server
/// without the route) stops it for good; the chat transcript still gets every reply.
@MainActor
final class SessionRunListener {
    private let url: URL
    private let stream: any SessionEventStreaming
    private let sleep: @MainActor (Duration) async throws -> Void
    private let onStreamID: @MainActor (String) -> Void
    private let log: (String) -> Void
    private var lastEventID: String?
    private var isRunning = false
    /// Connections in a row that failed or closed without an event, for the backoff.
    private var failures = 0
    /// The wait before the next reconnect after a failure; tests await it.
    private(set) var retryTask: Task<Void, Never>?

    init(
        url: URL,
        stream: any SessionEventStreaming,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        log: @escaping (String) -> Void = { _ in },
        onStreamID: @escaping @MainActor (String) -> Void
    ) {
        self.url = url
        self.stream = stream
        self.sleep = sleep
        self.log = log
        self.onStreamID = onStreamID
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        connect()
    }

    func stop() {
        isRunning = false
        retryTask?.cancel()
        retryTask = nil
        stream.stop()
    }

    /// The run a `<stream_id>:<seq>` event id belongs to.
    nonisolated static func streamID(fromEventID eventID: String) -> String? {
        guard let colon = eventID.lastIndex(of: ":") else { return nil }
        let streamID = eventID[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        return streamID.isEmpty ? nil : streamID
    }

    private func connect() {
        var heardEvent = false
        stream.start(url: url, lastEventID: lastEventID, onEventID: { [weak self] eventID in
            guard let self, self.isRunning else { return }
            heardEvent = true
            self.failures = 0
            self.lastEventID = eventID
            if let streamID = Self.streamID(fromEventID: eventID) { self.onStreamID(streamID) }
        }, onEnd: { [weak self] end in
            guard let self, self.isRunning else { return }
            switch end {
            case .rejected(let status):
                self.log("session events unavailable (HTTP \(status)); not listening")
                self.stop()
            case .closed where heardEvent:
                self.connect()
            case .closed, .failed:
                self.failures += 1
                self.reconnectAfterBackoff()
            }
        })
    }

    private func reconnectAfterBackoff() {
        let delay = Duration.seconds(min(30, 1 << min(failures - 1, 5)))
        retryTask = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard let self, self.isRunning, !Task.isCancelled else { return }
            self.connect()
        }
    }
}
