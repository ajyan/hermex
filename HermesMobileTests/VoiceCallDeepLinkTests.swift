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

    // MARK: - Start gate

    func testACallNeverStartsWhileAppLockCoversTheApp() {
        XCTAssertFalse(VoiceCallStartGate(isAppLocked: true, waitsForTap: false, tapped: false).mayStart)
        XCTAssertFalse(VoiceCallStartGate(isAppLocked: true, waitsForTap: true, tapped: true).mayStart)
        XCTAssertTrue(VoiceCallStartGate(isAppLocked: false, waitsForTap: false, tapped: false).mayStart)
    }

    func testACallFromAnotherAppsLinkWaitsForStartCall() {
        XCTAssertFalse(VoiceCallStartGate(isAppLocked: false, waitsForTap: true, tapped: false).mayStart)
        XCTAssertTrue(VoiceCallStartGate(isAppLocked: false, waitsForTap: true, tapped: true).mayStart)
    }

    @MainActor
    func testTheLaunchMarkIsTakenOnce() {
        VoiceCallLaunch.request(waitsForTap: true)
        XCTAssertTrue(VoiceCallLaunch.takeWaitsForTap())
        XCTAssertFalse(VoiceCallLaunch.takeWaitsForTap(), "A later call from inside the app starts as before")
        VoiceCallLaunch.request(waitsForTap: false)
        XCTAssertFalse(VoiceCallLaunch.takeWaitsForTap())
    }
}
