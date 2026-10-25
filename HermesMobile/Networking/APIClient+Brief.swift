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

/// `POST /api/brief/intention`: the review's answers so far, the same list the filer gets.
struct BriefIntentionRequest: Encodable, Sendable {
    let date: String
    let answers: [DeckAnswer]
}

/// The drafted intention for next week. Every field is optional; the route answers `{}` when the
/// model is down or slow, which decodes as an empty draft.
struct WeekIntentionDraft: Decodable, Equatable, Sendable {
    let thread: String?
    let intention: String?
    let obstacle: String?
    let ifThen: String?

    init(thread: String? = nil, intention: String? = nil, obstacle: String? = nil, ifThen: String? = nil) {
        self.thread = thread
        self.intention = intention
        self.obstacle = obstacle
        self.ifThen = ifThen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thread = try? c.decodeIfPresent(String.self, forKey: .thread)
        intention = try? c.decodeIfPresent(String.self, forKey: .intention)
        obstacle = try? c.decodeIfPresent(String.self, forKey: .obstacle)
        ifThen = try? c.decodeIfPresent(String.self, forKey: .ifThen)
    }

    /// Nothing drafted: every field missing or blank.
    var isEmpty: Bool {
        [thread, intention, obstacle, ifThen].allSatisfy { $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }
    }

    // `APIClient`'s decoder converts snake_case, so `if_then` arrives as `ifThen`.
    private enum CodingKeys: String, CodingKey { case thread, intention, obstacle, ifThen }
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
    /// Asks the server to draft next week's intention from the review's answers so far. Read-only;
    /// a server without the route throws its 404, and one whose model failed answers an empty draft.
    func draftIntention(date: String, answers: DeckAnswersPayload) async throws -> WeekIntentionDraft {
        let data = try await sendData(endpoint: .briefIntention, method: "POST",
                                      body: BriefIntentionRequest(date: date, answers: answers.answers))
        return try decode(WeekIntentionDraft.self, from: data)
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
