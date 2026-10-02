import XCTest
@testable import HermesMobile

final class VoiceApprovalMatcherTests: XCTestCase {
    func testApprovePhrases() {
        for phrase in ["Approve.", "approved", "Yes, approve!", "approve it", "  APPROVE  "] {
            XCTAssertEqual(VoiceApprovalMatcher.decide(phrase), .approve, phrase)
        }
    }

    func testEverythingElseDenies() {
        for phrase in ["yes", "approve the email", "deny", "", "I approve of that", "approve approve"] {
            XCTAssertEqual(VoiceApprovalMatcher.decide(phrase), .deny, phrase)
        }
        XCTAssertEqual(VoiceApprovalMatcher.decide(nil), .deny)
    }
}
