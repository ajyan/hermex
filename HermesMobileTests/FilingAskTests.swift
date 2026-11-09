import XCTest
@testable import HermesMobile

/// "Where does this belong?": a clarification with `kind: "filing"` and two places.
final class FilingAskTests: XCTestCase {
    private func pending(_ json: String) throws -> PendingClarification {
        try JSONDecoder().decode(PendingClarification.self, from: Data(json.utf8))
    }

    func testFilingRequestDecodesItsPlacesAndDetail() throws {
        let request = try pending("""
        {"clarify_id":"c1","question":"Where does this belong?","kind":"filing",
         "choices_offered":["Story bank","Journal"],"recommended":"Story bank",
         "detail":"It reads like an interview story. It could also be a journal note.","session_id":"s1"}
        """)

        XCTAssertEqual(request.detail, "It reads like an interview story. It could also be a journal note.")
        XCTAssertEqual(request.filingPlaces?.recommended, "Story bank")
        XCTAssertEqual(request.filingPlaces?.other, "Journal")
    }

    func testTheRecommendedPlaceLeadsWhicheverOrderTheChoicesCome() throws {
        let request = try pending(
            #"{"kind":"filing","choices_offered":["Journal","Sam Rivera"],"recommended":"Sam Rivera"}"#
        )
        XCTAssertEqual(request.filingPlaces?.recommended, "Sam Rivera")
        XCTAssertEqual(request.filingPlaces?.other, "Journal")

        // No recommendation, or one that names neither choice: the first choice leads.
        let plain = try pending(#"{"kind":"filing","choices_offered":["Journal","Story bank"],"recommended":"Attic"}"#)
        XCTAssertEqual(plain.filingPlaces?.recommended, "Journal")
    }

    func testOnlyATwoPlaceFilingRequestGetsTheCard() throws {
        XCTAssertNil(try pending(#"{"kind":"clarify","choices_offered":["main","release"]}"#).filingPlaces)
        XCTAssertNil(try pending(#"{"kind":"filing","choices_offered":["Journal"]}"#).filingPlaces)
        XCTAssertNil(try pending(#"{"kind":"filing","choices_offered":["A","B","C"]}"#).filingPlaces)
        XCTAssertNil(try pending(#"{"kind":"filing","choices_offered":["Journal","Journal"]}"#).filingPlaces)
        XCTAssertNil(try pending(#"{"question":"Which branch?"}"#).detail)
    }

    func testAnOrdinaryClarificationStillDecodes() throws {
        let request = try pending(#"{"clarify_id":"c2","question":"Which branch?","choices_offered":["main","release"]}"#)
        XCTAssertEqual(request.displayChoices, ["main", "release"])
        XCTAssertNil(request.recommended)
    }
}
