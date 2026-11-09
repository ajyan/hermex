import XCTest
@testable import HermesMobile

/// The filing receipt: decode (`_filed`, the `filed` event), what each page opens, and Undo.
final class FilingReceiptTests: XCTestCase {
    private static let receiptJSON = """
    {"id":"fr_3f9c2a1b7d10","undone":false,"can_undo":true,
     "pages":[{"kind":"person","title":"Sam Rivera","detail":"Note, Nov 9","module":"people",
               "page_id":"crm/contacts/Sam Rivera.md","path":"crm/contacts/Sam Rivera.md","change":"updated"},
              {"kind":"journal","title":"Journal","detail":"Nov 9","module":"journal",
               "page_id":"journal/2026/11-November/2026-11-09.md","change":"created"}]}
    """

    // MARK: - Decoding

    func testReceiptDecodesWithThePlainAndTheSnakeCaseDecoder() throws {
        let plain = try JSONDecoder().decode(FilingReceipt.self, from: Data(Self.receiptJSON.utf8))
        let snake = JSONDecoder()
        snake.keyDecodingStrategy = .convertFromSnakeCase
        let converted = try snake.decode(FilingReceipt.self, from: Data(Self.receiptJSON.utf8))

        XCTAssertEqual(plain, converted)
        XCTAssertEqual(plain.id, "fr_3f9c2a1b7d10")
        XCTAssertTrue(plain.canUndo)
        XCTAssertFalse(plain.undone)
        XCTAssertEqual(plain.pages.map(\.label), ["Sam Rivera · Note, Nov 9", "Journal · Nov 9"])
        XCTAssertEqual(plain.pages.first?.pageID, "crm/contacts/Sam Rivera.md")
    }

    func testReceiptDecodesTolerantly() throws {
        let json = """
        {"pages":[{"kind":"hologram","title":"Work"}, "not a page", {"kind":"story","detail":"The eval loop"}],
         "future_field":{"x":1}}
        """
        let receipt = try JSONDecoder().decode(FilingReceipt.self, from: Data(json.utf8))

        XCTAssertNil(receipt.id)
        XCTAssertFalse(receipt.canUndo)
        XCTAssertEqual(receipt.pages.map(\.kind), [.note, .story])
        XCTAssertEqual(receipt.pages.map(\.label), ["Work", "The eval loop"])
        XCTAssertEqual(try JSONDecoder().decode(FilingReceipt.self, from: Data("{}".utf8)).pages, [])
    }

    func testReceiptSurvivesItsOwnEncoding() throws {
        let receipt = try JSONDecoder().decode(FilingReceipt.self, from: Data(Self.receiptJSON.utf8))
        let again = try JSONDecoder().decode(FilingReceipt.self, from: JSONEncoder().encode(receipt))
        XCTAssertEqual(receipt, again)
    }

    func testMessageDecodesItsReceipt() throws {
        let json = #"{"role":"assistant","content":"Saved.","messageId":"m1","_filed":\#(Self.receiptJSON)}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.filed?.pages.count, 2)

        let bare = try JSONDecoder().decode(
            ChatMessage.self,
            from: Data(#"{"role":"assistant","content":"Hi","_filed":"nonsense"}"#.utf8)
        )
        XCTAssertNil(bare.filed)
        XCTAssertEqual(bare.content, "Hi")
    }

    func testFiledStreamEventDecodes() throws {
        let event = SSEEventDecoder.decode(
            eventType: "filed",
            data: #"{"session_id":"session-abc","receipt":\#(Self.receiptJSON)}"#
        )
        guard case .filed(let payload) = event else {
            return XCTFail("Expected filed, got \(event)")
        }
        XCTAssertEqual(payload.sessionID, "session-abc")
        XCTAssertEqual(payload.receipt?.pages.count, 2)
    }

    func testFiledStreamEventWithNoReceiptIsIgnored() {
        XCTAssertEqual(SSEEventDecoder.decode(eventType: "filed", data: #"{"session_id":"s"}"#), .ignored)
        XCTAssertEqual(SSEEventDecoder.decode(eventType: "filed", data: "not json"), .ignored)
    }

    // MARK: - Papers and routes

    func testEachKindWearsItsPagesPaper() {
        XCTAssertEqual(FiledPageKind.person.paper, BrainModuleID.people.paper)
        XCTAssertEqual(FiledPageKind.journal.paper, BrainModuleID.journal.paper)
        XCTAssertEqual(FiledPageKind.wiki.paper, BrainModuleID.wiki.paper)
        XCTAssertEqual(FiledPageKind.letter.paper, BrainModuleID.letters.paper)
        XCTAssertEqual(FiledPageKind.story.paper, HermexPaper.prep)
        XCTAssertEqual(FiledPageKind.note.paper, HermexPaper.file)
    }

    func testAPageOpensItsBrainPageWhenItHasOne() {
        let person = FiledPage(kind: .person, title: "Sam Rivera", module: "people", pageID: "crm/contacts/Sam Rivera.md")
        XCTAssertEqual(person.route, .page(.people, "crm/contacts/Sam Rivera.md"))

        XCTAssertNil(FiledPage(kind: .note, title: "Work", path: "profile/work.md").route)
        XCTAssertNil(FiledPage(kind: .person, title: "Sam", module: "people").route)
        XCTAssertNil(FiledPage(kind: .wiki, title: "Evals", module: "attic", pageID: "wiki/evals.md").route)
        XCTAssertEqual(FiledPage(kind: .story, title: "Story bank").route, .prep(.home))
    }

    // MARK: - Undo

    func testUndoPostsTheReceiptAndDecodesTheAnswer() async throws {
        var body: [String: Any]?
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/filing/undo")
            XCTAssertEqual(request.httpMethod, "POST")
            body = try filingJSONBody(from: request)
            return filingJSONResponse(
                #"{"ok":true,"restored":2,"skipped":[],"receipt":{"id":"fr_1","undone":true,"can_undo":false,"pages":[]}}"#,
                for: request
            )
        }

        let response = try await client.undoFiling(sessionID: "session-abc", receiptID: "fr_1")

        XCTAssertEqual(body?["session_id"] as? String, "session-abc")
        XCTAssertEqual(body?["receipt_id"] as? String, "fr_1")
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.restored, 2)
        XCTAssertEqual(response.receipt?.undone, true)
    }

    @MainActor
    func testUndoMarksTheReceiptOnlyAfterTheServerAgrees() async throws {
        var undoRequests = 0
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/session":
                return filingJSONResponse(Self.sessionJSON, for: request)
            case "/api/filing/undo":
                undoRequests += 1
                return filingJSONResponse(
                    #"{"ok":true,"restored":2,"receipt":{"id":"fr_3f9c2a1b7d10","undone":true,"can_undo":false,"pages":[{"kind":"person","title":"Sam Rivera"}]}}"#,
                    for: request
                )
            default:
                return filingJSONResponse("{}", for: request)
            }
        }
        await viewModel.loadMessages()
        let reply = try XCTUnwrap(viewModel.messages.last)
        XCTAssertEqual(reply.filed?.undone, false)

        await viewModel.undoFiling(for: reply)

        XCTAssertEqual(undoRequests, 1)
        XCTAssertEqual(viewModel.messages.last?.filed?.undone, true)
        XCTAssertEqual(viewModel.messages.last?.filed?.canUndo, false)
        XCTAssertEqual(viewModel.messages.last?.content, "Saved.")
        XCTAssertTrue(viewModel.undoingFilingReceiptIDs.isEmpty)
        XCTAssertNil(viewModel.sendErrorMessage)

        // Already undone: nothing more is sent.
        await viewModel.undoFiling(for: try XCTUnwrap(viewModel.messages.last))
        XCTAssertEqual(undoRequests, 1)
    }

    @MainActor
    func testARefusedUndoLeavesTheReceiptAndSaysWhy() async throws {
        let viewModel = try makeViewModel { request in
            switch request.url?.path {
            case "/api/session":
                return filingJSONResponse(Self.sessionJSON, for: request)
            case "/api/filing/undo":
                return filingJSONResponse(
                    #"{"ok":false,"error":"These pages changed again after they were filed, so nothing was undone.","skipped":[]}"#,
                    statusCode: 409,
                    for: request
                )
            default:
                return filingJSONResponse("{}", for: request)
            }
        }
        await viewModel.loadMessages()
        let reply = try XCTUnwrap(viewModel.messages.last)

        await viewModel.undoFiling(for: reply)

        XCTAssertEqual(viewModel.messages.last?.filed, reply.filed)
        XCTAssertEqual(
            viewModel.sendErrorMessage,
            "These pages changed again after they were filed, so nothing was undone."
        )
        XCTAssertTrue(viewModel.undoingFilingReceiptIDs.isEmpty)
    }

    @MainActor
    func testTheFiledEventReachesTheReplyWhenDoneCarriesNoTranscript() async throws {
        let viewModel = try makeViewModel { request in
            request.url?.path == "/api/session"
                ? filingJSONResponse(Self.sessionWithoutReceiptJSON, for: request)
                : filingJSONResponse("{}", for: request)
        }
        await viewModel.loadMessages()
        XCTAssertNil(viewModel.messages.last?.filed)
        let receipt = try JSONDecoder().decode(FilingReceipt.self, from: Data(Self.receiptJSON.utf8))

        viewModel.streamCoordinatorApplyFiled(FiledStreamEvent(sessionID: "session-abc", receipt: receipt))
        XCTAssertNil(viewModel.messages.last?.filed, "The receipt waits for the turn to settle")
        _ = viewModel.streamCoordinatorApplyDone(DoneStreamEvent(usage: nil, session: nil))

        XCTAssertEqual(viewModel.messages.last?.filed, receipt)
        XCTAssertEqual(viewModel.messages.last?.content, "Saved.")
    }

    // MARK: - Helpers

    private static let sessionJSON = """
    {"session":{"session_id":"session-abc","title":"Log","messages":[
      {"role":"user","content":"Had coffee with Sam","messageId":"u1","timestamp":1},
      {"role":"assistant","content":"Saved.","messageId":"a1","timestamp":2,"_filed":\(receiptJSON)}]}}
    """

    private static let sessionWithoutReceiptJSON = """
    {"session":{"session_id":"session-abc","title":"Log","messages":[
      {"role":"user","content":"Had coffee with Sam","messageId":"u1","timestamp":1},
      {"role":"assistant","content":"Saved.","messageId":"a1","timestamp":2}]}}
    """

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        FilingMockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FilingMockURLProtocol.self]
        return APIClient(baseURL: URL(string: "https://example.test")!, session: URLSession(configuration: configuration))
    }

    @MainActor
    private func makeViewModel(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> ChatViewModel {
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(
            SessionSummary.self,
            from: Data(#"{"session_id":"session-abc","title":"Log","workspace":"/tmp/workspace","model":"gpt-5.4"}"#.utf8)
        )
        return ChatViewModel(
            session: session,
            server: server,
            client: makeClient(handler: handler),
            streamClient: ScriptedSSEStreamingClient(connectionScripts: []),
            approvalStreamClient: ScriptedSSEStreamingClient(connectionScripts: []),
            clarifyStreamClient: ScriptedSSEStreamingClient(connectionScripts: [])
        )
    }
}

private final class FilingMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func filingJSONResponse(_ json: String, statusCode: Int = 200, for request: URLRequest) -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(
        url: request.url ?? URL(string: "https://example.test")!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
    )!
    return (response, Data(json.utf8))
}

private func filingJSONBody(from request: URLRequest) throws -> [String: Any] {
    var data = request.httpBody
    if data == nil, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            collected.append(buffer, count: read)
        }
        data = collected
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
}
