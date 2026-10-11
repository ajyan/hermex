import XCTest
import UIKit
@testable import HermesMobile

@MainActor
final class FeedbackSheetViewModelTests: XCTestCase {
    private let context = FeedbackContext(feature: "Prep", screen: "Spot the bug", item: "Longest Substring")

    func testSendPostsContextAndText() async throws {
        let client = StubFeedbackClient()
        let viewModel = FeedbackSheetViewModel(context: context, client: client, build: "412")
        viewModel.text = "  Hints should wait until I ask.\n"

        let didSend = await viewModel.send()

        XCTAssertTrue(didSend)
        let created = await client.created
        XCTAssertEqual(created.count, 1)
        let body = try XCTUnwrap(created.first)
        XCTAssertEqual(body.feature, "Prep")
        XCTAssertEqual(body.screen, "Spot the bug")
        XCTAssertEqual(body.item, "Longest Substring")
        XCTAssertEqual(body.build, "412")
        XCTAssertEqual(body.text, "Hints should wait until I ask.")
        XCTAssertFalse(viewModel.isSending)
        XCTAssertNil(viewModel.error)
    }

    func testEmptyTextCannotSend() async {
        let client = StubFeedbackClient()
        let viewModel = FeedbackSheetViewModel(context: context, client: client, build: nil)
        viewModel.text = " \n  "

        XCTAssertFalse(viewModel.canSend)
        let didSend = await viewModel.send()

        XCTAssertFalse(didSend)
        let created = await client.created
        XCTAssertTrue(created.isEmpty)
    }

    func testFailureKeepsTextAndShowsError() async {
        let client = StubFeedbackClient()
        await client.fail(with: APIError.http(statusCode: 500, body: nil))
        let viewModel = FeedbackSheetViewModel(context: context, client: client, build: nil)
        viewModel.text = "The trace drill skips a line."

        let didSend = await viewModel.send()

        XCTAssertFalse(didSend)
        XCTAssertEqual(viewModel.text, "The trace drill skips a line.")
        XCTAssertNotNil(viewModel.error)
        XCTAssertFalse(viewModel.isSending)
        XCTAssertTrue(viewModel.canSend)
    }

    func testDismissDuringSendDoesNotRepost() async {
        let client = StubFeedbackClient()
        await client.holdCreates()
        let viewModel = FeedbackSheetViewModel(context: context, client: client, build: nil)
        viewModel.text = "Approach rep needs a bigger editor."

        let firstSend = Task { await viewModel.send() }
        await client.waitForCreate()

        XCTAssertTrue(viewModel.isSending)
        XCTAssertFalse(viewModel.canSend)
        let doubleTap = await viewModel.send()
        XCTAssertFalse(doubleTap)

        viewModel.dismiss()
        let afterDismiss = await viewModel.send()
        XCTAssertFalse(afterDismiss)

        await client.releaseCreates()
        _ = await firstSend.value

        let created = await client.created
        XCTAssertEqual(created.count, 1)
        XCTAssertNil(viewModel.error)
    }

    func testUnavailableHidesItem() async {
        let client = StubFeedbackClient()
        await client.setAvailable(false)
        let availability = FeedbackAvailability(client: client)

        XCTAssertFalse(availability.isAvailable, "hidden until the server answers")
        await availability.check()

        XCTAssertFalse(availability.isAvailable)
    }

    func testUnavailableChecksAgainUntilTheServerSaysYes() async {
        let client = StubFeedbackClient()
        await client.setAvailable(false)
        let availability = FeedbackAvailability(client: client)
        await availability.check()
        XCTAssertFalse(availability.isAvailable)

        await client.setAvailable(true)
        await availability.check()

        XCTAssertTrue(availability.isAvailable, "a later check shows the item once the server has the inbox")
        let checks = await client.availabilityChecks
        XCTAssertEqual(checks, 2)
    }

    func testAvailableShowsItemAndChecksOncePerServerSession() async {
        let client = StubFeedbackClient()
        let availability = FeedbackAvailability(client: client)

        await availability.check()
        await availability.check()

        XCTAssertTrue(availability.isAvailable)
        let checks = await client.availabilityChecks
        XCTAssertEqual(checks, 1)
    }
    // MARK: Attachments

    private func solidImage(_ size: CGSize = CGSize(width: 40, height: 80)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func isJPEG(base64: String?) -> Bool {
        guard let base64, let data = Data(base64Encoded: base64) else { return false }
        return data.starts(with: [0xFF, 0xD8, 0xFF])
    }

    func testBodyIncludesScreenshotWhenKept() async throws {
        let client = StubFeedbackClient()
        let viewModel = FeedbackSheetViewModel(context: context, client: client, build: nil, screenshot: solidImage())
        viewModel.text = "The hint covers the code."

        let didSend = await viewModel.send()

        XCTAssertTrue(didSend)
        let created = await client.created
        let body = try XCTUnwrap(created.first)
        XCTAssertTrue(isJPEG(base64: body.screenshot), "the kept screenshot goes up as base64 JPEG")
    }

    func testRemovingScreenshotOmitsIt() async throws {
        let client = StubFeedbackClient()
        let viewModel = FeedbackSheetViewModel(context: context, client: client, build: nil, screenshot: solidImage())
        viewModel.text = "The hint covers the code."

        viewModel.removeScreenshot()
        XCTAssertNil(viewModel.screenshot)
        _ = await viewModel.send()

        let created = await client.created
        let body = try XCTUnwrap(created.first)
        XCTAssertNil(body.screenshot)
    }

    func testSummaryLine() {
        let chat = FeedbackContext(feature: "Chat", screen: "Chat", item: "Fix login", state: ["session_id": "abc123"])
        let withShot = FeedbackSheetViewModel(context: chat, client: StubFeedbackClient(), build: nil, screenshot: solidImage())
        XCTAssertEqual(withShot.attachmentSummary, "Screenshot · Chat session (last turn)")

        withShot.removeScreenshot()
        XCTAssertEqual(withShot.attachmentSummary, "Chat session (last turn)")

        let prep = FeedbackContext(feature: "Prep", screen: "Trace", state: ["item_id": "two-sum"])
        XCTAssertEqual(FeedbackSheetViewModel(context: prep, client: StubFeedbackClient(), build: nil, screenshot: solidImage()).attachmentSummary,
                       "Screenshot · Screen state")

        let bare = FeedbackSheetViewModel(context: FeedbackContext(feature: "Prep", screen: "Home"), client: StubFeedbackClient(), build: nil)
        XCTAssertNil(bare.attachmentSummary, "nothing attached, no summary line")
    }

    func testScaledToMax1600() throws {
        let tall = try XCTUnwrap(FeedbackScreenshot.capture(UIWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 2000)), displayScale: 3))
        XCTAssertEqual(tall.size.width * tall.scale, 800, accuracy: 1)
        XCTAssertEqual(tall.size.height * tall.scale, 1600, accuracy: 1)

        let small = try XCTUnwrap(FeedbackScreenshot.capture(UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 600)), displayScale: 2))
        XCTAssertEqual(small.size.height * small.scale, 1200, accuracy: 1, "never scaled up")

        XCTAssertTrue(isJPEG(base64: FeedbackScreenshot.jpegBase64(tall)))
    }

    func testNoWindowMeansNoScreenshot() {
        XCTAssertNil(FeedbackScreenshot.capture(nil))
        XCTAssertNil(FeedbackScreenshot.capture(UIWindow(frame: .zero)), "a window with no size has nothing to show")
    }
}

/// `isAvailable()` against `URLProtocol` mocks: only a 404 means the feature is missing.
final class FeedbackAvailabilityHTTPTests: APIClientTestCase {
    func testNotFoundMeansUnavailable() async {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/feedback")
            return apiTestJSONResponse(#"{"error":"not found"}"#, for: request, status: 404)
        }

        let isAvailable = await APIClientFeedbackAdapter(apiClient: client).isAvailable()

        XCTAssertFalse(isAvailable)
    }

    func testServerErrorStillCountsAsAvailable() async {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/feedback")
            return apiTestJSONResponse(#"{"error":"boom"}"#, for: request, status: 500)
        }

        let isAvailable = await APIClientFeedbackAdapter(apiClient: client).isAvailable()

        XCTAssertTrue(isAvailable)
    }
}

private actor StubFeedbackClient: FeedbackDataClient {
    private(set) var created: [FeedbackCreate] = []
    private(set) var availabilityChecks = 0
    private var available = true
    private var createError: Error?
    private var holdsCreates = false
    private var heldCreate: CheckedContinuation<Void, Never>?
    private var createWaiter: CheckedContinuation<Void, Never>?

    func fail(with error: Error) { createError = error }
    func setAvailable(_ value: Bool) { available = value }
    func holdCreates() { holdsCreates = true }

    func releaseCreates() {
        holdsCreates = false
        heldCreate?.resume()
        heldCreate = nil
    }

    /// Returns once a create has reached the server.
    func waitForCreate() async {
        guard created.isEmpty else { return }
        await withCheckedContinuation { createWaiter = $0 }
    }

    func list() async throws -> [FeedbackEntry] { [] }
    func plan(id: String) async throws -> String { "" }

    func create(_ body: FeedbackCreate) async throws -> FeedbackEntry {
        created.append(body)
        createWaiter?.resume()
        createWaiter = nil
        if holdsCreates { await withCheckedContinuation { heldCreate = $0 } }
        if let createError { throw createError }
        return try FeedbackDecoding.decode(FeedbackEntry.self, from: Data(#"{"id":"fb-1","status":"new"}"#.utf8))
    }

    func decide(id: String, _ decision: FeedbackDecision) async throws -> FeedbackEntry {
        try FeedbackDecoding.decode(FeedbackEntry.self, from: Data(#"{"id":"\#(id)"}"#.utf8))
    }

    func isAvailable() async -> Bool {
        availabilityChecks += 1
        return available
    }
}
