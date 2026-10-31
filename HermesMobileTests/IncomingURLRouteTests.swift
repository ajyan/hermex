import XCTest
@testable import HermesMobile

/// What `ContentView.handleOpenURL` does with each URL kind it can receive, before
/// any server routing or navigation: each builder's link lands on its own route,
/// malformed links degrade the way the app relies on, and everything else is ignored.
final class IncomingURLRouteTests: XCTestCase {
    private let server = URL(string: "https://a.example")!
    private let connectionID = UUID()

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }

    private var scheme: String { HermesDeepLink.scheme }

    func testEachBuiltLinkResolvesToItsOwnRoute() throws {
        let bot = BotDestination(server: server, connectionID: connectionID, profile: "inbox", conversation: nil)
        let cases: [(URL?, IncomingURLRoute)] = [
            (HermesDeepLink.webuiSessionURL(server: server, sessionID: "s1"),
             .webuiPush(WebuiPushDestination(server: server, sessionID: "s1"))),
            (HermesDeepLink.newChatVoiceURL, .newChatVoice),
            (HermesDeepLink.dailyBriefURL, .dailyBrief(date: nil, kind: nil)),
            (HermesDeepLink.dailyBriefURL(date: "2026-10-11", kind: "weekly"), .dailyBrief(date: "2026-10-11", kind: "weekly")),
            (HermesDeepLink.goalsURL, .goals),
            (HermesDeepLink.newCallURL, .newCall),
            (HermesDeepLink.newChatInProfileURL(profileName: "Research Bot"), .newChatInProfile(profileName: "Research Bot")),
            (HermesDeepLink.newChatURL, .newChat),
            (HermesDeepLink.botURL(for: bot), .bot(bot)),
            (HermesDeepLink.sessionURL(sessionID: "s2"), .session(id: "s2")),
            (HermesShareDraft.openURL, .shareOpen)
        ]

        for (link, expected) in cases {
            let link = try XCTUnwrap(link, "\(expected)")
            XCTAssertEqual(IncomingURLRoute(link), expected, link.absoluteString)
        }
    }

    func testLiveActivityTapLinksKeepTheirRouteWithTheActivityItem() throws {
        let push = try XCTUnwrap(HermesDeepLink.webuiSessionURL(server: server, sessionID: "s1"))
        let tagged = try url(push.absoluteString + "&activity=act-1")
        XCTAssertEqual(IncomingURLRoute(tagged), .webuiPush(WebuiPushDestination(server: server, sessionID: "s1")))

        let legacy = try url("\(scheme)://session?id=s2&activity=act-2")
        XCTAssertEqual(IncomingURLRoute(legacy), .session(id: "s2"))
    }

    func testHostsMatchCaseInsensitively() throws {
        XCTAssertEqual(IncomingURLRoute(try url("\(scheme)://New-Chat-Voice")), .newChatVoice)
        XCTAssertEqual(IncomingURLRoute(try url("\(scheme)://NEW-CALL")), .newCall)
        XCTAssertEqual(IncomingURLRoute(try url("\(scheme)://Share")), .shareOpen)
    }

    func testSessionLinkAcceptsThePathAndLegacyQueryForms() throws {
        XCTAssertEqual(IncomingURLRoute(try url("\(scheme)://session/abc")), .session(id: "abc"))
        XCTAssertEqual(IncomingURLRoute(try url("\(scheme)://session?session_id=abc")), .session(id: "abc"))
    }

    func testDailyBriefWithAnUnknownReviewKindStillOpensTheBrief() throws {
        let link = try url("\(scheme)://daily-brief?date=2026-10-11&kind=yearly")
        XCTAssertEqual(IncomingURLRoute(link), .dailyBrief(date: nil, kind: nil))
    }

    func testProfileLinkWithoutAProfileFallsBackToAPlainNewChatRequest() throws {
        XCTAssertEqual(IncomingURLRoute(try url("\(scheme)://new-chat-profile")), .newChatInProfile(profileName: nil))
        XCTAssertEqual(IncomingURLRoute(try url("\(scheme)://new-chat-profile?profile=%20%20")), .newChatInProfile(profileName: nil))
    }

    /// A malformed webui-push, bot, or session link must not fall through into a
    /// different action (a session open, a share import): it is dropped.
    func testMalformedRoutedLinksAreIgnoredRatherThanFallingThrough() throws {
        let malformed = [
            "\(scheme)://webui-push?id=s1",
            "\(scheme)://webui-push?server=https://a.example&id=%20",
            "\(scheme)://bot?server=https://a.example&profile=inbox",
            "\(scheme)://bot?server=https://a.example&connection=not-a-uuid&profile=inbox",
            "\(scheme)://session",
            "\(scheme)://session?id=%20"
        ]
        for string in malformed {
            XCTAssertEqual(IncomingURLRoute(try url(string)), .ignore, string)
        }
    }

    func testUnknownLinksAreIgnored() throws {
        let unknown = [
            "\(scheme)://settings",
            "\(scheme)://",
            "https://a.example/session?id=s1",
            "https://new-chat",
            "other-app://share",
            "other-app://webui-push?server=https://a.example&id=s1"
        ]
        for string in unknown {
            XCTAssertEqual(IncomingURLRoute(try url(string)), .ignore, string)
        }
    }
}
