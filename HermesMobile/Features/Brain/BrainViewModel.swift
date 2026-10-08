import Foundation
import Observation

/// The read-only Brain API on this user's `hermes-webui` fork (`api/brain.py`):
/// `GET /api/brain/people` and `GET /api/brain/person?file=`. Stock upstream
/// servers answer 404, which the screens show as "no Brain on this server".
/// Only GETs: the Second Brain is edited by the agent, never from the app.
protocol BrainDataClient: Sendable {
    func people() async throws -> [BrainPerson]
    func person(file: String) async throws -> BrainPersonFile
}

/// One contact from `GET /api/brain/people` (frontmatter only, no body).
/// Every field is optional on the wire; `file` is the row identity.
struct BrainPerson: Decodable, Identifiable, Hashable, Sendable {
    let file: String
    let name: String
    let relationship: String
    let tags: [String]
    let lastContacted: String

    var id: String { file }

    init(file: String, name: String, relationship: String = "", tags: [String] = [], lastContacted: String = "") {
        self.file = file
        self.name = name
        self.relationship = relationship
        self.tags = tags
        self.lastContacted = lastContacted
    }

    private enum CodingKeys: String, CodingKey {
        case file, name, relationship, tags
        case lastContacted = "last_contacted"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = (try? container.decodeIfPresent(String.self, forKey: .file)) ?? ""
        let decodedName = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        name = decodedName.isEmpty ? (file as NSString).deletingPathExtension : decodedName
        relationship = (try? container.decodeIfPresent(String.self, forKey: .relationship)) ?? ""
        tags = (try? container.decodeIfPresent([String].self, forKey: .tags)) ?? []
        lastContacted = (try? container.decodeIfPresent(String.self, forKey: .lastContacted)) ?? ""
    }
}

/// `GET /api/brain/people` envelope.
struct BrainPeopleResponse: Decodable {
    let people: [BrainPerson]?
}

/// `GET /api/brain/person?file=` — the contact's whole Markdown file.
struct BrainPersonFile: Decodable, Equatable, Sendable {
    let content: String?
    let error: String?

    /// The note as the reader should see it: the YAML frontmatter block the CRM
    /// keeps for scripts is dropped, since the body repeats it in prose.
    var body: String { Self.strippingFrontmatter(content ?? "") }

    static func strippingFrontmatter(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return text }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum BrainLoadState<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    /// The server has no Brain API (a stock `hermes-webui`, or another server).
    case unavailable
    case failed(String)
}

/// The People list: loaded once per screen, filtered locally as the user types.
/// Nothing is cached, so a server switch (which rebuilds the shell) never shows
/// another server's contacts.
@MainActor
@Observable
final class BrainPeopleViewModel {
    private(set) var state: BrainLoadState<[BrainPerson]> = .loading
    var query = ""

    private let client: any BrainDataClient
    private let onAPIError: (Error) -> Void

    init(client: any BrainDataClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.onAPIError = onAPIError
    }

    var people: [BrainPerson] {
        if case .loaded(let people) = state { return people }
        return []
    }

    var filteredPeople: [BrainPerson] { Self.filter(people, query: query) }

    /// Matches every typed word against the name, relationship, or tags, so
    /// "kev" finds Kevin Feng and Kevin Tam and "kevin t" narrows to Kevin Tam.
    /// People whose name starts with the query sort first.
    static func filter(_ people: [BrainPerson], query: String) -> [BrainPerson] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return people }
        let matches = people.filter { person in
            let haystack = ([person.name, person.relationship] + person.tags).joined(separator: " ")
            return words.allSatisfy { haystack.localizedStandardContains($0) }
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let prefixed = matches.filter { $0.name.lowercased().hasPrefix(trimmed.lowercased()) }
        return prefixed + matches.filter { !$0.name.lowercased().hasPrefix(trimmed.lowercased()) }
    }

    func load() async {
        if people.isEmpty { state = .loading }
        do {
            state = .loaded(try await client.people())
        } catch is CancellationError {
            // The screen went away; nothing to update.
        } catch {
            state = Self.failureState(for: error)
            onAPIError(error)
        }
    }

    nonisolated static func failureState<Value>(for error: Error) -> BrainLoadState<Value> {
        if let apiError = error as? APIError, apiError.isNotFound { return .unavailable }
        return .failed(error.localizedDescription)
    }
}

/// One contact's file. Each pushed detail screen owns its own instance, so
/// opening a second person never flashes the first one's note.
@MainActor
@Observable
final class BrainPersonViewModel {
    let person: BrainPerson
    private(set) var state: BrainLoadState<String> = .loading

    private let client: any BrainDataClient
    private let onAPIError: (Error) -> Void

    init(person: BrainPerson, client: any BrainDataClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.person = person
        self.client = client
        self.onAPIError = onAPIError
    }

    func load() async {
        do {
            let file = try await client.person(file: person.file)
            if let message = file.error, file.content == nil {
                state = .failed(message)
            } else {
                state = .loaded(file.body)
            }
        } catch is CancellationError {
            // The screen went away; nothing to update.
        } catch {
            if let apiError = error as? APIError, apiError.isNotFound {
                state = .failed(String(localized: "This contact's file is no longer in the Second Brain."))
            } else {
                state = .failed(error.localizedDescription)
            }
            onAPIError(error)
        }
    }
}

/// Wraps the `APIClient` actor in a `Sendable` value for the protocol.
struct APIClientBrainAdapter: BrainDataClient {
    let apiClient: APIClient

    func people() async throws -> [BrainPerson] {
        let response: BrainPeopleResponse = try await apiClient.send(endpoint: .brainPeople, method: "GET")
        return (response.people ?? []).filter { !$0.file.isEmpty }
    }

    func person(file: String) async throws -> BrainPersonFile {
        try await apiClient.send(endpoint: .brainPerson(file: file), method: "GET")
    }
}
