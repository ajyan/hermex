import Foundation

extension APIClient {
    /// Uploads an audio clip to the server's speech-to-text endpoint and returns
    /// the tolerant `{ok, transcript, error}` payload. Mirrors `uploadFile`'s
    /// multipart shape but sends only the `file` field (no `session_id`).
    ///
    /// The server returns a JSON `{error: ...}` body even for 503/400/413
    /// responses, so we decode the body regardless of status and let the caller
    /// inspect `.error`. Only `401` maps to `.unauthorized`; a body that isn't the
    /// expected shape on a non-2xx status surfaces as `.http`. Connectivity
    /// failures map to `.network` via `sendMultipart`.
    func transcribeAudio(data: Data, filename: String) async throws -> TranscribeResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.appendMultipart(fileField: "file", filename: filename, data: data, boundary: boundary)
        body.appendMultipartClosingBoundary(boundary)

        let (responseData, httpResponse) = try await sendMultipart(
            endpoint: .transcribe,
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            requireSuccess: false
        )
        // Decode first: the server returns `{error: ...}` even for 503/400/413, so
        // surfacing `.error` is friendlier than a raw HTTP failure. Fall back to a
        // thrown HTTP error only when the body isn't the expected JSON shape.
        if let decoded = try? decode(TranscribeResponse.self, from: responseData) {
            return decoded
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.http(
                statusCode: httpResponse.statusCode,
                body: String(data: responseData, encoding: .utf8)
            )
        }
        return try decode(TranscribeResponse.self, from: responseData)
    }

    /// One dictated passage rewritten as clean text by the server's local model.
    /// Throws when the server is unreachable, lacks the route, or returns no text.
    func tidyDictation(_ text: String, timeout: TimeInterval) async throws -> String {
        let response: DictationTidyResponse = try await send(
            endpoint: .dictationTidy, method: "POST", body: DictationTidyRequest(text: text), timeout: timeout)
        guard let tidied = response.text, !tidied.isEmpty else {
            throw APIError.http(statusCode: 502, body: response.error)
        }
        return tidied
    }

    /// The names and words a voice call's recognizer should expect, from the server's vault.
    /// Empty on any failure, including a server without the route: the call works without it.
    func voiceVocabulary() async -> [String] {
        do {
            let response: VoiceVocabularyResponse = try await send(endpoint: .voiceVocabulary, method: "GET")
            return (response.terms ?? []).filter { !$0.isEmpty }
        } catch {
            return []
        }
    }
}
