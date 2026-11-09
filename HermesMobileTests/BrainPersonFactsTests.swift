import SwiftData
import XCTest
import Foundation
@testable import HermesMobile

/// Editing a person's facts on their page: the wire shapes, what the sheet sends, and save, error
/// and undo in the page view model. Every person here is made up.
@MainActor
final class BrainPersonFactsTests: XCTestCase {
    private let pageID = "crm/contacts/Mira Okafor.md"
    private let facts = BrainPersonFacts(relationship: "Friend (climbing gym)", relationshipType: "friend",
                                         birthday: "1991-03-09", family: [BrainFact(label: "Partner", value: "Sam Okafor")])

    /// `APIClient`'s coders: snake_case on the wire.
    private var appDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func wire(_ request: BrainPersonFactsRequest) throws -> NSDictionary {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(request)) as? NSDictionary)
    }

    private func makeViewModel(_ client: FakeBrainClient) throws -> BrainPageViewModel {
        let container = try ModelContainer(for: CachedBrainEntry.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let cache = BrainCacheHandle(server: URL(string: "https://a.example")!, context: ModelContext(container))
        client.pageResult = .success(BrainPage(item: BrainItem(module: .people, id: pageID, title: "Mira Okafor"),
                                               person: BrainPerson(editable: facts)))
        return BrainPageViewModel(module: .people, id: pageID, client: client, cache: cache, onAPIError: { _ in })
    }

    // MARK: - Wire

    func testEditableFactsDecodeTolerantlyAndSurviveTheCache() throws {
        let json = #"""
        {"editable": {"relationship": "Friend (climbing gym)", "relationship_type": "friend", "birthday": "1991-03-09",
                      "family": [{"label": "Partner", "value": "Sam Okafor"}, 7], "nickname": "M"}}
        """#
        let person = try appDecoder.decode(BrainPerson.self, from: Data(json.utf8))
        XCTAssertEqual(person.editable, facts)
        XCTAssertEqual(try JSONDecoder().decode(BrainPerson.self, from: JSONEncoder().encode(person)).editable, facts)
        XCTAssertNil(try appDecoder.decode(BrainPerson.self, from: Data("{}".utf8)).editable,
                     "an older server sends no facts, so the page offers no edit")
        XCTAssertEqual(try appDecoder.decode(BrainPerson.self, from: Data(#"{"editable": {}}"#.utf8)).editable,
                       BrainPersonFacts())
    }

    func testRequestSendsOnlyTheChangedFactsFlatWithFamilyAsRows() throws {
        let change = BrainPersonFactsChange(relationshipType: "family", birthday: "",
                                            family: [BrainFact(label: "Partner", value: "Sam Reyes")])
        XCTAssertEqual(try wire(BrainPersonFactsRequest(id: pageID, change: change)), [
            "id": pageID, "relationship_type": "family", "birthday": "",
            "family": [["label": "Partner", "value": "Sam Reyes"]],
        ] as NSDictionary)
        XCTAssertEqual(Endpoint.brainPersonFacts.path, "/api/brain/person/facts")
    }

    func testResultReadsWhatTheSaveReplaced() throws {
        let json = #"""
        {"ok": true, "contact": "Mira Okafor", "changed": ["birthday", "family"],
         "previous": {"birthday": "", "family": [{"label": "Partner", "value": "Sam Okafor"}]}, "facts": {}}
        """#
        let result = try appDecoder.decode(BrainPersonFactsResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.previous, BrainPersonFactsChange(birthday: "", family: [BrainFact(label: "Partner", value: "Sam Okafor")]))
        XCTAssertFalse(result.previous.isEmpty, "a birthday that wasn't there before is undone by removing it")
        XCTAssertTrue(try appDecoder.decode(BrainPersonFactsResult.self, from: Data(#"{"ok": true}"#.utf8)).previous.isEmpty)
    }

    // MARK: - Draft

    func testDraftSendsOnlyWhatDiffersFromThePage() {
        var draft = BrainPersonFactsDraft(facts)
        XCTAssertTrue(draft.change.isEmpty)
        XCTAssertFalse(draft.canSave, "nothing changed, nothing to save")

        draft.relationship = "  Family   (Sister-in-law) "
        draft.relationshipType = "family"
        draft.family["Partner"] = ""
        draft.family["Children"] = "Ada Okafor,  Bo Okafor"
        draft.family["Mother"] = "   "
        XCTAssertEqual(draft.change, BrainPersonFactsChange(
            relationship: "Family (Sister-in-law)", relationshipType: "family",
            family: [BrainFact(label: "Partner", value: ""), BrainFact(label: "Children", value: "Ada Okafor, Bo Okafor")]))
        XCTAssertTrue(draft.canSave)
    }

    func testDraftRefusesABadBirthdayAndAnEmptiedRelationship() {
        var draft = BrainPersonFactsDraft(facts)
        for good in ["1991-03-09", "03-09", "02-29", " 2000-02-29 ", ""] {
            draft.birthday = good
            XCTAssertNil(draft.birthdayProblem, good)
        }
        for bad in ["March 9", "1991-02-30", "13-01", "91-03-09", "3-9", "1991/03/09", "٠٣-٠٩"] {
            draft.birthday = bad
            XCTAssertNotNil(draft.birthdayProblem, bad)
            XCTAssertFalse(draft.canSave, bad)
        }
        draft.birthday = ""
        XCTAssertEqual(draft.change, BrainPersonFactsChange(birthday: ""), "clearing the birthday removes it")

        draft.relationship = " "
        XCTAssertNotNil(draft.relationshipProblem)
        XCTAssertFalse(draft.canSave)
    }

    func testAPageWithNoKindKeepsItUnsetUntilHePicksOne() {
        var draft = BrainPersonFactsDraft(BrainPersonFacts(relationshipType: "acquaintance"))
        XCTAssertNil(draft.relationshipProblem, "a page with no relationship may stay without one")
        draft.birthday = "05-02"
        XCTAssertEqual(draft.change, BrainPersonFactsChange(birthday: "05-02"), "the unknown kind is left alone")
        draft.relationshipType = "network"
        XCTAssertEqual(draft.change.relationshipType, "network")
    }

    // MARK: - Save, error, undo

    func testSavingWritesTheChangeReloadsThePageAndOffersUndo() async throws {
        let client = FakeBrainClient()
        let viewModel = try makeViewModel(client)
        await viewModel.load()
        let previous = BrainPersonFactsChange(birthday: "1991-03-09")
        client.factsResult = .success(BrainPersonFactsResult(previous: previous))

        try await viewModel.saveFacts(BrainPersonFactsChange(birthday: "03-10"))
        XCTAssertEqual(client.savedFacts, [BrainPersonFactsRequest(id: pageID, change: BrainPersonFactsChange(birthday: "03-10"))])
        XCTAssertEqual(client.pageCalls.count, 2, "the page reloads with the new facts")
        XCTAssertEqual(viewModel.factsUndo, previous)

        try await viewModel.undoFacts()
        XCTAssertEqual(client.savedFacts.last, BrainPersonFactsRequest(id: pageID, change: previous),
                       "undo posts back exactly what the save replaced")
        XCTAssertEqual(client.pageCalls.count, 3)
        XCTAssertNil(viewModel.factsUndo)
    }

    func testAFailedSaveThrowsAndChangesNothing() async throws {
        let client = FakeBrainClient()
        let viewModel = try makeViewModel(client)
        await viewModel.load()
        client.factsResult = .failure(URLError(.notConnectedToInternet))
        do {
            try await viewModel.saveFacts(BrainPersonFactsChange(birthday: "03-10"))
            XCTFail("a failed save throws, so the sheet keeps his edits")
        } catch {}
        XCTAssertNil(viewModel.factsUndo)
        XCTAssertEqual(client.pageCalls.count, 1, "nothing written, nothing to reload")
    }

    func testAFailedUndoKeepsTheOfferAndASaveThatChangedNothingOffersNone() async throws {
        let client = FakeBrainClient()
        let viewModel = try makeViewModel(client)
        await viewModel.load()
        let previous = BrainPersonFactsChange(relationship: "Friend (climbing gym)")
        client.factsResult = .success(BrainPersonFactsResult(previous: previous))
        try await viewModel.saveFacts(BrainPersonFactsChange(relationship: "Colleague"))

        client.factsResult = .failure(URLError(.timedOut))
        do {
            try await viewModel.undoFacts()
            XCTFail("a failed undo throws")
        } catch {}
        XCTAssertEqual(viewModel.factsUndo, previous, "he can try again")

        client.factsResult = .success(BrainPersonFactsResult())
        try await viewModel.saveFacts(BrainPersonFactsChange(relationship: "Friend (climbing gym)"))
        XCTAssertNil(viewModel.factsUndo, "the server changed nothing, so there is nothing to undo")

        try await viewModel.saveFacts(BrainPersonFactsChange())
        XCTAssertEqual(client.savedFacts.count, 3, "an empty change never reaches the server")
    }
}
