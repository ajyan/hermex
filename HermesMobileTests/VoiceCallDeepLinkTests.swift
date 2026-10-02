import XCTest
@testable import HermesMobile

final class VoiceCallDeepLinkTests: XCTestCase {
    func testNewCallDeepLinkParses() throws {
        let url = try XCTUnwrap(HermesDeepLink.newCallURL)
        XCTAssertEqual(url.scheme, HermesDeepLink.scheme)
        XCTAssertEqual(url.host, HermesDeepLink.newCallHost)
        XCTAssertTrue(HermesDeepLink.isNewCallURL(url))
        XCTAssertTrue(HermesDeepLink.isNewCallURL(try XCTUnwrap(URL(string: "\(HermesDeepLink.scheme)://New-Call"))))
        XCTAssertFalse(HermesDeepLink.isNewCallURL(try XCTUnwrap(URL(string: "https://new-call"))))
    }

    func testNewCallDoesNotAliasOtherNewChatLinks() throws {
        let call = try XCTUnwrap(HermesDeepLink.newCallURL)
        XCTAssertFalse(HermesDeepLink.isNewChatURL(call))
        XCTAssertFalse(HermesDeepLink.isNewChatVoiceURL(call))
        XCTAssertFalse(HermesDeepLink.isNewChatInProfileURL(call))
        XCTAssertNil(HermesDeepLink.sessionID(from: call))
        XCTAssertFalse(HermesDeepLink.isNewCallURL(try XCTUnwrap(HermesDeepLink.newChatURL)))
        XCTAssertFalse(HermesDeepLink.isNewCallURL(try XCTUnwrap(HermesDeepLink.newChatVoiceURL)))
    }

    @MainActor
    func testCallAtlasIntentQueuesTheCallDeepLink() async throws {
        _ = try await CallAtlasIntent().perform()
        XCTAssertEqual(AppIntentRouter.shared.pendingDeepLink, HermesDeepLink.newCallURL)
        XCTAssertTrue(CallAtlasIntent.openAppWhenRun)
    }

    func testNewCallRequestStartsACall() {
        XCTAssertTrue(NewChatRequest(startsCall: true).startsCall)
        XCTAssertFalse(NewChatRequest().startsCall)
    }
}
