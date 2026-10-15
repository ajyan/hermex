import Foundation

/// Posts a finished turn's timings to `/api/telemetry/turn`. Fire and forget: every error is
/// ignored, and a server that answers 404 (no such route) gets no further uploads this launch.
@MainActor
enum TurnTraceUploader {
    /// Off under XCTest so the many tests that send a message through a mocked server don't each see
    /// an unexpected `/api/telemetry/turn` request. `TurnTraceFlowTests` turns it back on.
    static var isEnabled = NSClassFromString("XCTestCase") == nil

    private static var unsupported: Set<String> = []

    static func send(_ upload: TurnTraceUpload, client: APIClient) async {
        let server = client.baseURL.absoluteString
        guard isEnabled, !unsupported.contains(server) else { return }
        do {
            _ = try await client.sendData(endpoint: .telemetryTurn, method: "POST", body: upload)
        } catch let error as APIError {
            if case .http(let statusCode, _) = error, statusCode == 404 {
                unsupported.insert(server)
            }
        } catch {
            // Telemetry never surfaces failures.
        }
    }

    /// For tests: forget which servers lack the route.
    static func reset() {
        unsupported.removeAll()
    }
}
