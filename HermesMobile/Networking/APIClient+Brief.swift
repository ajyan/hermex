import Foundation

/// `POST /api/brief/file` on this user's `hermes-webui` fork: files a Daily Deck's answers
/// without the model. The server saves the answers file and runs the filing CLI, which
/// updates only what changed, so refiling is safe.
struct BriefFileRequest: Encodable, Sendable {
    let date: String
    let kind: String
    /// The same object the chat-message fallback carries as JSON.
    let answers: DeckAnswersPayload
}

/// The filer's reply. Every field is optional: `ran` lists the steps the server ran,
/// `agentSteps` the follow-ups only the agent can do (empty when filing is complete).
struct BriefFileResponse: Decodable, Equatable, Sendable {
    struct Step: Decodable, Equatable, Sendable {
        let step: String?
        let ok: Bool?
        let error: String?

        init(step: String?, ok: Bool?, error: String? = nil) {
            self.step = step
            self.ok = ok
            self.error = error
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            step = try? c.decodeIfPresent(String.self, forKey: .step)
            ok = try? c.decodeIfPresent(Bool.self, forKey: .ok)
            error = try? c.decodeIfPresent(String.self, forKey: .error)
        }

        private enum CodingKeys: String, CodingKey { case step, ok, error }
    }

    let ok: Bool?
    let summary: String?
    let ran: [Step]?
    let agentSteps: [String]?
    let error: String?

    init(ok: Bool? = true, summary: String? = nil, ran: [Step]? = nil, agentSteps: [String]? = nil, error: String? = nil) {
        self.ok = ok
        self.summary = summary
        self.ran = ran
        self.agentSteps = agentSteps
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try? c.decodeIfPresent(Bool.self, forKey: .ok)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        ran = try? c.decodeIfPresent([Step].self, forKey: .ran)
        agentSteps = try? c.decodeIfPresent([String].self, forKey: .agentSteps)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }

    // `APIClient`'s decoder converts snake_case, so `agent_steps` arrives as `agentSteps`.
    private enum CodingKeys: String, CodingKey { case ok, summary, ran, agentSteps, error }
}

/// A filing the server refused or failed, in the server's words when it gave any.
struct BriefFileError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

extension APIClient {
    /// Files a deck's answers on the server. Returns nil when the server has no filer
    /// (a 404: upstream servers and other configured servers), so the caller can fall
    /// back to asking the agent. Other HTTP failures throw `BriefFileError` with the
    /// server's `error` when it sent one.
    func fileBrief(_ request: BriefFileRequest) async throws -> BriefFileResponse? {
        let data: Data
        do {
            data = try await sendData(endpoint: .briefFile, method: "POST", body: request)
        } catch let APIError.http(statusCode, _) where statusCode == 404 {
            return nil
        } catch let APIError.http(statusCode, body) {
            if let message = body.flatMap({ try? decode(BriefFileResponse.self, from: Data($0.utf8)) })?.error?
                .trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                throw BriefFileError(message: "Filing failed: \(message.prefix(200))")
            }
            throw APIError.http(statusCode: statusCode, body: body)
        }
        return try decode(BriefFileResponse.self, from: data)
    }
}

extension APIClient {
    /// Saves `jpeg` as the photo of the week ending `weekEnding` (a raw `image/jpeg` body; the
    /// server keeps at most 4 MB). A server without the route answers 404, which throws.
    func uploadWeekPhoto(weekEnding: String, jpeg: Data) async throws {
        _ = try await sendData(endpoint: .briefPhoto(weekEnding: weekEnding), method: "POST",
                               encodedBody: jpeg, contentType: "image/jpeg")
    }

    /// Removes the week's photo; a week with none is not an error.
    func deleteWeekPhoto(weekEnding: String) async throws {
        _ = try await sendData(endpoint: .briefPhoto(weekEnding: weekEnding), method: "DELETE")
    }
}
