import Foundation
import Observation

/// The read-only Brain API surface. Only GETs: this client must never grow
/// write paths — the Second Brain is edited on the machine, not from the app.
protocol BrainDataClient: Sendable {
    func people() async throws -> BrainPeopleResponse
    func person(file: String) async throws -> BrainPersonDetailResponse
}

/// `GET /api/brain/people` — the whole contact list, server-side sorted.
struct BrainPeopleResponse: Decodable {
    let count: Int
    let people: [BrainPersonSummary]
}

/// One row of the contact list (frontmatter only, no file content).
struct BrainPersonSummary: Decodable, Identifiable, Hashable {
    let name: String
    let file: String
    let relationship: String
    let tags: [String]
    let lastContacted: String
    let birthday: String
    let nextBirthday: String?

    private enum CodingKeys: String, CodingKey {
        case name, file, relationship, tags
        case lastContacted = "last_contacted"
        case birthday
        case nextBirthday = "next_birthday"
    }

    /// The list carries no other stable identity; the filename is unique
    /// within the vault, so it is the row identity.
    var id: String { file }
}

/// `GET /api/brain/person?file=…` — the summary plus the full markdown.
/// The error shape mirrors the API: an unknown file is a JSON 200-style
/// error member, not an HTTP error.
struct BrainPersonDetailResponse: Decodable {
    let error: String?
    let name: String?
    let file: String?
    let relationship: String?
    let tags: [String]?
    let birthday: String?
    let nextBirthday: String?
    let lastContacted: String?
    let content: String?

    private enum CodingKeys: String, CodingKey {
        case error, name, file, relationship, tags, birthday, content
        case nextBirthday = "next_birthday"
        case lastContacted = "last_contacted"
    }
}

enum BrainListState {
    case loading
    case loaded([BrainPersonSummary])
    case failed(String)
}

enum BrainDetailState {
    case loading
    case loaded(BrainPersonDetailResponse)
    case failed(String)
}

@MainActor
@Observable
final class BrainPeopleViewModel {
    private(set) var list: BrainListState = .loading
    private(set) var detail: BrainDetailState = .loading
    /// Filters as the user types; empty shows everyone.
    var query = ""

    private let client: any BrainDataClient

    init(client: any BrainDataClient) {
        self.client = client
    }

    var people: [BrainPersonSummary] {
        if case .loaded(let people) = list { return people }
        return []
    }

    var filteredPeople: [BrainPersonSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return people }
        return people.filter { person in
            person.name.lowercased().contains(q)
                || person.relationship.lowercased().contains(q)
                || person.tags.contains { $0.lowercased().contains(q) }
        }
    }

    func loadList() async {
        list = .loading
        do {
            let response = try await client.people()
            list = .loaded(response.people)
        } catch {
            list = .failed(error.localizedDescription)
        }
    }

    func loadDetail(for person: BrainPersonSummary) async {
        detail = .loading
        do {
            let response = try await client.person(file: person.file)
            if let error = response.error {
                detail = .failed(error == "not found" ? "No profile for this contact yet." : error)
            } else {
                detail = .loaded(response)
            }
        } catch {
            detail = .failed(error.localizedDescription)
        }
    }
}

struct APIClientBrainAdapter: BrainDataClient {
    let apiClient: APIClient

    func people() async throws -> BrainPeopleResponse {
        try await apiClient.send(endpoint: .brainPeople, method: "GET")
    }

    func person(file: String) async throws -> BrainPersonDetailResponse {
        try await apiClient.send(endpoint: .brainPerson(file: file), method: "GET")
    }
}
