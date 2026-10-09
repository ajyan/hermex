import XCTest
import Foundation
@testable import HermesMobile

@MainActor
final class BrainViewModelTests: XCTestCase {
    private let kevinFeng = BrainPerson(file: "Kevin Feng.md", name: "Kevin Feng", relationship: "Friend")
    private let kevinTam = BrainPerson(file: "Kevin Tam.md", name: "Kevin Tam", relationship: "Professional", tags: ["climbing"])
    private let jen = BrainPerson(file: "Jennifer Chou.md", name: "Jennifer Chou", relationship: "Family")
    private let mckevin = BrainPerson(file: "Al McKevin.md", name: "Al McKevin", relationship: "Mentor")

    // MARK: - Search

    func testEmptyQueryShowsEveryone() {
        let people = [kevinFeng, kevinTam, jen]
        XCTAssertEqual(BrainPeopleViewModel.filter(people, query: "  "), people)
    }

    func testEveryWordMustMatchAndCaseIsIgnored() {
        let people = [kevinFeng, kevinTam, jen]
        XCTAssertEqual(BrainPeopleViewModel.filter(people, query: "KEV"), [kevinFeng, kevinTam])
        XCTAssertEqual(BrainPeopleViewModel.filter(people, query: "kevin t"), [kevinTam])
    }

    func testMatchesRelationshipAndTags() {
        let people = [kevinFeng, kevinTam, jen]
        XCTAssertEqual(BrainPeopleViewModel.filter(people, query: "family"), [jen])
        XCTAssertEqual(BrainPeopleViewModel.filter(people, query: "climb"), [kevinTam])
    }

    func testNamePrefixMatchesSortFirst() {
        XCTAssertEqual(BrainPeopleViewModel.filter([mckevin, kevinTam], query: "kevin"), [kevinTam, mckevin])
    }

    // MARK: - Decoding

    func testPeopleDecodeToleratesMissingAndMistypedFields() throws {
        let json = #"{"count": 2, "people": [{"file": "Kevin Tam.md", "tags": "oops"}, {"file": "Jon Chan.md", "name": "Jon Chan", "relationship": "Friend", "tags": ["a"], "last_contacted": "2026-10-01", "extra": 1}]}"#
        let response = try JSONDecoder().decode(BrainPeopleResponse.self, from: Data(json.utf8))
        let people = try XCTUnwrap(response.people)
        XCTAssertEqual(people[0].name, "Kevin Tam")
        XCTAssertEqual(people[0].tags, [])
        XCTAssertEqual(people[1].relationship, "Friend")
        XCTAssertEqual(people[1].lastContacted, "2026-10-01")
    }

    func testFrontmatterIsStrippedFromTheNote() {
        let note = "---\ntype: person\nname: Kevin Tam\n---\n# Kevin Tam\n\nRelationship: Friend\n"
        XCTAssertEqual(BrainPersonFile.strippingFrontmatter(note), "# Kevin Tam\n\nRelationship: Friend")
    }

    func testNoteWithoutFrontmatterIsUnchanged() {
        let note = "# James Lilley\n\n---\n\nNotes"
        XCTAssertEqual(BrainPersonFile.strippingFrontmatter(note), note)
    }

    // MARK: - Loading

    func testListLoadsPeople() async {
        let viewModel = BrainPeopleViewModel(client: StubBrainClient(peopleResult: .success([kevinTam])))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded([kevinTam]))
    }

    func testServerWithoutBrainAPIShowsUnavailable() async {
        let viewModel = BrainPeopleViewModel(client: StubBrainClient(peopleResult: .failure(APIError.http(statusCode: 404, body: nil))))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .unavailable)
    }

    func testPersonLoadsItsNoteBody() async {
        let file = BrainPersonFile(content: "---\nname: Kevin Tam\n---\n# Kevin Tam", error: nil)
        let viewModel = BrainPersonViewModel(person: kevinTam, client: StubBrainClient(personResult: .success(file)))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .loaded("# Kevin Tam"))
    }

    func testMissingPersonFileFails() async {
        let viewModel = BrainPersonViewModel(
            person: kevinTam,
            client: StubBrainClient(personResult: .failure(APIError.http(statusCode: 404, body: #"{"error": "not found"}"#)))
        )
        await viewModel.load()
        guard case .failed = viewModel.state else {
            return XCTFail("Expected a failure, got \(viewModel.state)")
        }
    }
}

private struct StubBrainClient: BrainDataClient {
    var peopleResult: Result<[BrainPerson], Error> = .success([])
    var personResult: Result<BrainPersonFile, Error> = .success(BrainPersonFile(content: "", error: nil))

    func people() async throws -> [BrainPerson] { try peopleResult.get() }
    func person(file: String) async throws -> BrainPersonFile { try personResult.get() }
    func modules() async throws -> [BrainModule] { [] }
    func list(module: BrainModuleID, tag: String?, cursor: Int?) async throws -> BrainList { BrainList() }
    func page(module: BrainModuleID, id: String) async throws -> BrainPage { throw CancellationError() }
    func search(query: String, module: BrainModuleID?) async throws -> BrainSearchResult { BrainSearchResult() }
    func graph(module: BrainModuleID, id: String) async throws -> BrainGraph { BrainGraph() }
}
