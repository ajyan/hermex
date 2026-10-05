import XCTest
@testable import HermesMobile

final class ShellNavigationStateTests: XCTestCase {
    func testLaunchRootIsNewChatAndDrawerClosed() {
        let state = ShellNavigationState()

        guard case .newChat = state.root else { return XCTFail("launch root should be a new chat") }
        XCTAssertTrue(state.path.isEmpty)
        XCTAssertFalse(state.isDrawerOpen)
        XCTAssertTrue(state.isCreatingNewChat)
        XCTAssertNil(state.selectedSessionID)
    }

    func testSelectingSessionClearsPathAndClosesDrawer() {
        var state = ShellNavigationState()
        state.push(.tasks)
        state.isDrawerOpen = true
        let revision = state.rootRevision

        state.select(SessionSummary(sessionId: "s1"))

        XCTAssertEqual(state.root, .session(SessionSummary(sessionId: "s1")))
        XCTAssertTrue(state.path.isEmpty)
        XCTAssertFalse(state.isDrawerOpen)
        XCTAssertEqual(state.selectedSessionID, "s1")
        XCTAssertEqual(state.rootRevision, revision + 1)
    }

    func testPushClosesDrawer() {
        var state = ShellNavigationState()
        state.isDrawerOpen = true

        state.push(.projects)

        XCTAssertEqual(state.path, [.projects])
        XCTAssertFalse(state.isDrawerOpen)
    }

    func testRememberedNewChatReportsCreatedSession() {
        var state = ShellNavigationState()
        let route = PendingNewChatRoute()
        state.select(route)

        state.remember(SessionSummary(sessionId: "c1"))

        XCTAssertEqual(state.root, .newChat(route))
        XCTAssertEqual(state.selectedSessionID, "c1")
        XCTAssertFalse(state.isCreatingNewChat)
    }

    func testNewChatIsEmptyUntilItsFirstTurn() {
        var state = ShellNavigationState()
        XCTAssertTrue(state.isOnEmptyNewChat)

        state.remember(SessionSummary(sessionId: "c1"))
        XCTAssertTrue(state.isOnEmptyNewChat)

        state.markNewChatStarted()
        XCTAssertFalse(state.isOnEmptyNewChat)

        state.select(PendingNewChatRoute())
        XCTAssertTrue(state.isOnEmptyNewChat)
    }

    func testSessionRootIsNeverAnEmptyNewChat() {
        var state = ShellNavigationState()
        state.select(SessionSummary(sessionId: "s1"))
        XCTAssertFalse(state.isOnEmptyNewChat)
        state.markNewChatStarted()
        XCTAssertFalse(state.isOnEmptyNewChat)
    }

    func testSelectingNewChatForgetsRememberedSession() {
        var state = ShellNavigationState()
        state.remember(SessionSummary(sessionId: "c1"))

        state.select(PendingNewChatRoute())

        XCTAssertNil(state.selectedSessionID)
        XCTAssertTrue(state.isCreatingNewChat)
    }

    func testRemovingCurrentSessionResetsRootToNewChat() {
        var sessionState = ShellNavigationState()
        sessionState.select(SessionSummary(sessionId: "s1"))
        sessionState.remove(sessionID: "s1")
        guard case .newChat = sessionState.root else { return XCTFail("removed session root should become a new chat") }

        var newChatState = ShellNavigationState()
        let route = PendingNewChatRoute()
        newChatState.select(route)
        newChatState.remember(SessionSummary(sessionId: "c1"))
        newChatState.remove(sessionID: " c1 ")
        guard case .newChat(let replacement) = newChatState.root else { return XCTFail("expected new chat") }
        XCTAssertNotEqual(replacement.id, route.id)
        XCTAssertNil(newChatState.selectedSessionID)
    }

    func testRemovingCurrentSessionKeepsTheDrawerAsItWas() {
        var state = ShellNavigationState()
        state.select(SessionSummary(sessionId: "s1"))
        state.isDrawerOpen = true

        state.remove(sessionID: "s1")

        XCTAssertTrue(state.isDrawerOpen, "archiving from the drawer must not close it")
    }

    func testRemovingAnotherSessionKeepsRoot() {
        var state = ShellNavigationState()
        state.select(SessionSummary(sessionId: "s1"))

        state.remove(sessionID: "other")

        XCTAssertEqual(state.root, .session(SessionSummary(sessionId: "s1")))
    }

    func testShowOnlyReplacesPath() {
        var state = ShellNavigationState()
        state.push(.projects)
        state.push(.project("p"))
        state.isDrawerOpen = true

        state.showOnly(.settings(.notifications))

        XCTAssertEqual(state.path, [.settings(.notifications)])
        XCTAssertFalse(state.isDrawerOpen)
    }

    func testOpeningDrawerRequestsRefresh() {
        XCTAssertTrue(ShellNavigationState.drawerOpenRequestsRefresh(wasOpen: false, isOpen: true))
        XCTAssertFalse(ShellNavigationState.drawerOpenRequestsRefresh(wasOpen: true, isOpen: true))
        XCTAssertFalse(ShellNavigationState.drawerOpenRequestsRefresh(wasOpen: true, isOpen: false))
        XCTAssertFalse(ShellNavigationState.drawerOpenRequestsRefresh(wasOpen: false, isOpen: false))
    }

    func testDeepLinkLoadIsSingleFlightAndIgnoresBlankIDs() {
        var state = ShellNavigationState()

        XCTAssertNil(state.beginDeepLinkedSessionLoad(id: "   "))
        XCTAssertEqual(state.beginDeepLinkedSessionLoad(id: " d1 "), "d1")
        XCTAssertNil(state.beginDeepLinkedSessionLoad(id: "d2"))

        state.finishDeepLinkedSessionLoad(id: "d1")

        XCTAssertEqual(state.beginDeepLinkedSessionLoad(id: "d2"), "d2")
    }
}
