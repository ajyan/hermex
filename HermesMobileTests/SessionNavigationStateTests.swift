import SwiftUI
import XCTest
@testable import HermesMobile

final class SessionNavigationStateTests: XCTestCase {
    func testInitialRefreshStartsBeforeDelayedDeepLinkFinishes() async {
        let recorder = SessionInitialLoadEventRecorder()

        await SessionListInitialLoad.run(
            resolvePendingDeepLink: {
                await recorder.record(.deepLinkStarted)
                try? await Task.sleep(nanoseconds: 50_000_000)
                await recorder.record(.deepLinkFinished)
            },
            loadSessions: {
                await recorder.record(.refreshStarted)
            },
            sessionsDidLoad: {},
            loadProjects: {},
            loadActiveProfile: {}
        )

        let events = await recorder.snapshot()
        guard let refreshIndex = events.firstIndex(of: .refreshStarted),
              let deepLinkFinishIndex = events.firstIndex(of: .deepLinkFinished)
        else {
            return XCTFail("Expected both refresh and deep-link completion events")
        }

        XCTAssertLessThan(refreshIndex, deepLinkFinishIndex)
    }

    /// Over a tunnel each held request is a round trip, so the rows must not
    /// wait for projects or the profile, and neither of those waits for the other.
    @MainActor
    func testInitialLoadFinishesRowsBeforeProjectsAndProfileAndLoadsThemTogether() async {
        let log = InitialLoadLog()
        let projects = HeldInitialLoad()
        let profile = HeldInitialLoad()
        let rowsLoadedWithBothLoadsInFlight = expectation(description: "rows loaded while projects and profile are held")
        rowsLoadedWithBothLoadsInFlight.expectedFulfillmentCount = 2

        let initialLoad = Task { @MainActor in
            await SessionListInitialLoad.run(
                resolvePendingDeepLink: { log.events.append("deepLink") },
                loadSessions: { log.events.append("sessions") },
                sessionsDidLoad: { log.events.append("loaded") },
                loadProjects: {
                    rowsLoadedWithBothLoadsInFlight.fulfill()
                    await projects.wait()
                    log.events.append("projects")
                },
                loadActiveProfile: {
                    rowsLoadedWithBothLoadsInFlight.fulfill()
                    await profile.wait()
                    log.events.append("profile")
                }
            )
        }

        await fulfillment(of: [rowsLoadedWithBothLoadsInFlight], timeout: 5)
        XCTAssertEqual(Set(log.events), ["deepLink", "sessions", "loaded"])
        XCTAssertEqual(log.events.last, "loaded")

        profile.release()
        projects.release()
        await initialLoad.value
        XCTAssertEqual(Set(log.events.suffix(2)), ["projects", "profile"])
    }

    func testLeavingANewChatSuppressesPlaceholdersThenRefreshesSessions() {
        var events: [DestinationReturnEvent] = []

        SessionListDestinationReturn.run(
            from: .newChat(PendingNewChatRoute()),
            to: .session(SessionSummary(sessionId: "session-1")),
            suppressEmptyPlaceholders: { events.append(.suppressedPlaceholders) },
            refreshSessions: { events.append(.refreshedSessions) }
        )

        XCTAssertEqual(events, [.suppressedPlaceholders, .refreshedSessions])
    }

    func testReplacingNewChatRouteDoesNotRefreshSessions() {
        var events: [DestinationReturnEvent] = []

        SessionListDestinationReturn.run(
            from: .newChat(PendingNewChatRoute()),
            to: .newChat(PendingNewChatRoute()),
            suppressEmptyPlaceholders: { events.append(.suppressedPlaceholders) },
            refreshSessions: { events.append(.refreshedSessions) }
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testLeavingASessionRefreshesSessionsWithoutSuppressingPlaceholders() {
        var events: [DestinationReturnEvent] = []

        SessionListDestinationReturn.run(
            from: .session(SessionSummary(sessionId: "session-1")),
            to: .newChat(PendingNewChatRoute()),
            suppressEmptyPlaceholders: { events.append(.suppressedPlaceholders) },
            refreshSessions: { events.append(.refreshedSessions) }
        )

        XCTAssertEqual(events, [.refreshedSessions])
    }

    func testSwitchingBetweenSessionsRefreshesSessions() {
        var events: [DestinationReturnEvent] = []

        SessionListDestinationReturn.run(
            from: .session(SessionSummary(sessionId: "session-1")),
            to: .session(SessionSummary(sessionId: "session-2")),
            suppressEmptyPlaceholders: { events.append(.suppressedPlaceholders) },
            refreshSessions: { events.append(.refreshedSessions) }
        )

        XCTAssertEqual(events, [.refreshedSessions])
    }

    func testUnchangedRootRefreshesNothing() {
        let root = ShellRoot.session(SessionSummary(sessionId: "session-1"))
        var events: [DestinationReturnEvent] = []

        SessionListDestinationReturn.run(
            from: root,
            to: root,
            suppressEmptyPlaceholders: { events.append(.suppressedPlaceholders) },
            refreshSessions: { events.append(.refreshedSessions) }
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testMonitorPollsOnlyWhileDrawerOpen() {
        XCTAssertFalse(activeRowMonitorID(isDrawerOpen: false).shouldPoll)
        XCTAssertTrue(activeRowMonitorID(isDrawerOpen: true).shouldPoll)
        XCTAssertFalse(activeRowMonitorID(hasActiveRows: false, isDrawerOpen: true).shouldPoll)
        XCTAssertFalse(activeRowMonitorID(isViewingCachedData: true, isDrawerOpen: true).shouldPoll)
    }

    @MainActor
    func testOpeningTheDrawerTicksOnceAfterReloadingRows() async {
        var events: [String] = []
        var streamIDs = ["before-reload"]

        await SessionListReturnRefresh.run(
            refreshSessions: {
                events.append("reload")
                streamIDs = ["after-reload"]
            },
            monitorTaskID: {
                ActiveSessionMonitorTaskID(
                    streamIDs: streamIDs,
                    hasActiveRows: true,
                    isViewingCachedData: false,
                    isDrawerOpen: true
                )
            },
            refreshActiveRows: { taskID in
                events.append("tick:\(taskID.streamIDs.joined())")
            }
        )

        // The tick runs right away, on the rows the reload found, rather than
        // leaving stale Approval or Input badges up until the poll's first tick.
        XCTAssertEqual(events, ["reload", "tick:after-reload"])
    }

    @MainActor
    func testReturnSkipsTheTickWhenThePollWouldNotRun() async {
        for monitorID in [
            activeRowMonitorID(isDrawerOpen: false),
            activeRowMonitorID(hasActiveRows: false),
            activeRowMonitorID(isViewingCachedData: true),
        ] {
            var ticks = 0
            await SessionListReturnRefresh.run(
                refreshSessions: {},
                monitorTaskID: { monitorID },
                refreshActiveRows: { _ in ticks += 1 }
            )
            XCTAssertEqual(ticks, 0)
        }
    }

    private func activeRowMonitorID(
        hasActiveRows: Bool = true,
        isViewingCachedData: Bool = false,
        isDrawerOpen: Bool = true
    ) -> ActiveSessionMonitorTaskID {
        ActiveSessionMonitorTaskID(
            streamIDs: ["stream-1"],
            hasActiveRows: hasActiveRows,
            isViewingCachedData: isViewingCachedData,
            isDrawerOpen: isDrawerOpen
        )
    }

    func testReadableContentWidthsKeepSecondaryAndWorkspaceSurfacesDistinct() {
        XCTAssertEqual(AdaptiveReadableContentWidth.secondaryDestination, 800)
        XCTAssertEqual(AdaptiveReadableContentWidth.workspace, 1_000)
        XCTAssertLessThan(
            AdaptiveReadableContentWidth.secondaryDestination,
            AdaptiveReadableContentWidth.workspace
        )
    }

    func testForegroundReturnRefreshesAtOnceWhenNothingIsLoading() {
        var refresh = SessionListForegroundRefresh()

        XCTAssertTrue(refresh.appReturned(didCompleteInitialLoad: true, isLoading: false))
        XCTAssertFalse(refresh.isPending)
        XCTAssertFalse(refresh.consumeIfReady(didCompleteInitialLoad: true, isLoading: false))
    }

    func testForegroundReturnDuringTheInitialLoadRefreshesOnceItCompletes() {
        var refresh = SessionListForegroundRefresh()

        XCTAssertFalse(refresh.appReturned(didCompleteInitialLoad: false, isLoading: true))
        XCTAssertFalse(refresh.consumeIfReady(didCompleteInitialLoad: false, isLoading: false))
        XCTAssertTrue(refresh.consumeIfReady(didCompleteInitialLoad: true, isLoading: false))
        XCTAssertFalse(refresh.consumeIfReady(didCompleteInitialLoad: true, isLoading: false))
    }

    func testForegroundReturnDuringALoadRefreshesOnceWhenItSettles() {
        var refresh = SessionListForegroundRefresh()

        XCTAssertFalse(refresh.appReturned(didCompleteInitialLoad: true, isLoading: true))
        XCTAssertFalse(refresh.consumeIfReady(didCompleteInitialLoad: true, isLoading: true))
        XCTAssertTrue(refresh.consumeIfReady(didCompleteInitialLoad: true, isLoading: false))
        XCTAssertFalse(
            refresh.consumeIfReady(didCompleteInitialLoad: true, isLoading: false),
            "the deferred refresh runs once, and its own load must not trigger another"
        )
    }

    func testRepeatedForegroundReturnsDuringALoadCoalesce() {
        var refresh = SessionListForegroundRefresh()

        XCTAssertFalse(refresh.appReturned(didCompleteInitialLoad: true, isLoading: true))
        XCTAssertFalse(refresh.appReturned(didCompleteInitialLoad: true, isLoading: true))
        XCTAssertTrue(refresh.consumeIfReady(didCompleteInitialLoad: true, isLoading: false))
        XCTAssertFalse(refresh.consumeIfReady(didCompleteInitialLoad: true, isLoading: false))
    }

    func testLoadsWithoutAForegroundReturnDoNotRefresh() {
        var refresh = SessionListForegroundRefresh()

        XCTAssertFalse(refresh.consumeIfReady(didCompleteInitialLoad: true, isLoading: false))
    }

    func testArchiveToastShowsOnlyWhileTheDrawerIsOpen() {
        var route = SessionListArchiveToastRoute()
        let hidden = route.archiveStarted()
        let shown = route.archiveStarted()

        XCTAssertFalse(route.archiveConfirmed(shown, isListShowing: false))
        XCTAssertTrue(
            route.archiveConfirmed(hidden, isListShowing: true),
            "a skipped toast must not block an older archive that lands where the user can see it"
        )
    }

    func testOlderArchiveNeverReplacesTheNewerArchivesToast() {
        var route = SessionListArchiveToastRoute()
        let first = route.archiveStarted()
        let second = route.archiveStarted()

        XCTAssertTrue(route.archiveConfirmed(second, isListShowing: true))
        XCTAssertFalse(route.archiveConfirmed(first, isListShowing: true), "the first archive's reply landed last")
    }

    func testChatShortcutPositionPicksNthChatOrNothing() {
        let chats = ["a", "b", "c"].map { SessionSummary(sessionId: $0) }

        XCTAssertEqual(ChatShortcutNavigation.chat(atPosition: 1, in: chats)?.sessionId, "a")
        XCTAssertEqual(ChatShortcutNavigation.chat(atPosition: 3, in: chats)?.sessionId, "c")
        XCTAssertNil(ChatShortcutNavigation.chat(atPosition: 4, in: chats))
        XCTAssertNil(ChatShortcutNavigation.chat(atPosition: 9, in: chats))
        XCTAssertNil(ChatShortcutNavigation.chat(atPosition: 0, in: chats))
        XCTAssertNil(ChatShortcutNavigation.chat(atPosition: 1, in: []))
    }

    func testNextAndPreviousChatWrapAndStartFromTheEndsWithoutSelection() {
        let chats = ["a", "b", "c"].map { SessionSummary(sessionId: $0) }
        func adjacent(_ offset: Int, from selectedSessionID: String?) -> String? {
            ChatShortcutNavigation.adjacentChat(offset: offset, from: selectedSessionID, in: chats)?.sessionId
        }

        XCTAssertEqual(adjacent(1, from: "a"), "b")
        XCTAssertEqual(adjacent(-1, from: "b"), "a")
        XCTAssertEqual(adjacent(1, from: "c"), "a", "next wraps from the last chat to the first")
        XCTAssertEqual(adjacent(-1, from: "a"), "c", "previous wraps from the first chat to the last")
        XCTAssertEqual(adjacent(1, from: nil), "a")
        XCTAssertEqual(adjacent(-1, from: nil), "c")
        XCTAssertEqual(adjacent(1, from: "filtered-out"), "a")
        XCTAssertEqual(adjacent(-1, from: "filtered-out"), "c")
        XCTAssertNil(ChatShortcutNavigation.adjacentChat(offset: 1, from: "a", in: []))
    }
}

private enum DestinationReturnEvent: Equatable {
    case suppressedPlaceholders
    case refreshedSessions
}

@MainActor
private final class InitialLoadLog {
    var events: [String] = []
}

/// Holds a scripted load open until the test releases it.
@MainActor
private final class HeldInitialLoad {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor SessionInitialLoadEventRecorder {
    enum Event: Equatable {
        case deepLinkStarted
        case refreshStarted
        case deepLinkFinished
    }

    private var events: [Event] = []

    func record(_ event: Event) {
        events.append(event)
    }

    func snapshot() -> [Event] {
        events
    }
}
