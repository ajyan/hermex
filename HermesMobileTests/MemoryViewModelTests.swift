import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class MemoryViewModelTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testSaveWritesSelectedSectionAndReloadsMemory() async throws {
        var requestPaths: [String] = []
        let client = makeClient { request in
            requestPaths.append(request.url?.path ?? "")

            if request.url?.path == "/api/memory/write" {
                XCTAssertEqual(request.httpMethod, "POST")
                let data = try XCTUnwrap(apiTestBodyData(from: request))
                let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                XCTAssertEqual(body?["section"] as? String, "soul")
                XCTAssertEqual(body?["content"] as? String, "# Updated Soul")

                return apiTestJSONResponse("""
                {
                  "ok": true,
                  "section": "soul",
                  "path": "/Users/test/.hermes/SOUL.md"
                }
                """, for: request)
            }

            XCTAssertEqual(request.url?.path, "/api/memory")
            return apiTestJSONResponse("""
            {
              "memory": "# Notes",
              "user": "# Profile",
              "soul": "# Updated Soul",
              "memory_mtime": 1770000000,
              "user_mtime": 1770000100,
              "soul_mtime": 1770000200
            }
            """, for: request)
        }
        let viewModel = MemoryViewModel(
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        let didSave = await viewModel.save(section: .soul, content: "# Updated Soul")

        XCTAssertTrue(didSave)
        XCTAssertEqual(requestPaths, ["/api/memory/write", "/api/memory"])
        XCTAssertEqual(viewModel.memoryText, "# Notes")
        XCTAssertEqual(viewModel.userText, "# Profile")
        XCTAssertEqual(viewModel.soulText, "# Updated Soul")
        XCTAssertEqual(viewModel.soulMtime, Date(timeIntervalSince1970: 1_770_000_200))
        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    @MainActor
    func testSaveSurfacesRejectedResponseWithoutReloading() async throws {
        var requestPaths: [String] = []
        let client = makeClient { request in
            requestPaths.append(request.url?.path ?? "")

            return apiTestJSONResponse("""
            {
              "ok": false,
              "error": "section rejected"
            }
            """, for: request)
        }
        let viewModel = MemoryViewModel(
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        let didSave = await viewModel.save(section: .memory, content: "# Notes")

        XCTAssertFalse(didSave)
        XCTAssertEqual(requestPaths, ["/api/memory/write"])
        XCTAssertEqual(viewModel.actionErrorMessage, "section rejected")
        XCTAssertFalse(viewModel.hasLoaded)
    }

    @MainActor
    func testLoadSurfacesProjectContextDocument() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory")

            return apiTestJSONResponse("""
            {
              "memory": "# Notes",
              "user": "# Profile",
              "soul": "# Soul",
              "project_context": "# Project rules",
              "project_context_name": "AGENTS.md",
              "project_context_workspace": "/Users/test/workspace",
              "project_context_mtime": 1770000300,
              "project_context_shadowed": [
                {
                  "name": "PROJECT.md",
                  "path": "/Users/test/PROJECT.md"
                }
              ],
              "external_notes_enabled": true
            }
            """, for: request)
        }
        let viewModel = MemoryViewModel(
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        await viewModel.load()

        XCTAssertTrue(viewModel.showsProjectContext)
        XCTAssertEqual(viewModel.projectContextText, "# Project rules")
        XCTAssertEqual(viewModel.projectContextName, "AGENTS.md")
        XCTAssertEqual(viewModel.projectContextWorkspace, "/Users/test/workspace")
        XCTAssertEqual(viewModel.projectContextMtime, Date(timeIntervalSince1970: 1_770_000_300))
        XCTAssertTrue(viewModel.isProjectContextShadowed)
        XCTAssertEqual(viewModel.isExternalNotesEnabled, true)
        XCTAssertEqual(viewModel.projectContextDetail, "AGENTS.md — /Users/test/workspace")
    }

    @MainActor
    func testProjectContextSectionHiddenWithoutFields() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory")

            return apiTestJSONResponse("""
            {
              "memory": "# Notes",
              "user": "# Profile",
              "soul": "# Soul"
            }
            """, for: request)
        }
        let viewModel = MemoryViewModel(
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        await viewModel.load()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertFalse(viewModel.showsProjectContext)
        XCTAssertFalse(viewModel.isProjectContextShadowed)
        XCTAssertNil(viewModel.projectContextDetail)
        XCTAssertNil(viewModel.isExternalNotesEnabled)
    }

    @MainActor
    func testProjectContextSectionHiddenForBlankDocumentAndDetailOmitsEmptyParts() async throws {
        // Upstream returns "" (not null) when no readable project-context file exists.
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/memory")

            return apiTestJSONResponse("""
            {
              "memory": "# Notes",
              "project_context": "  \\n ",
              "project_context_name": "",
              "project_context_workspace": "/Users/test/workspace",
              "project_context_shadowed": []
            }
            """, for: request)
        }
        let viewModel = MemoryViewModel(
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        await viewModel.load()

        XCTAssertFalse(viewModel.showsProjectContext)
        XCTAssertFalse(viewModel.isProjectContextShadowed)
        XCTAssertEqual(viewModel.projectContextDetail, "/Users/test/workspace")
    }

    @MainActor
    func testLoadFailureBeforeAnyContentSurfacesTheErrorAndStaysUnloaded() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"error": "boom"}"#, for: request, status: 500)
        }
        let viewModel = MemoryViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        await viewModel.load()

        XCTAssertFalse(viewModel.hasLoaded)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertEqual(viewModel.errorMessage, viewModel.lastError?.localizedDescription)
        XCTAssertEqual(viewModel.content(for: .memory), "")
        XCTAssertNil(viewModel.modifiedAt(for: .memory))
    }

    @MainActor
    func testReloadFailureKeepsLoadedContentAndARetryClearsTheError() async throws {
        var loadCount = 0
        let client = makeClient { request in
            loadCount += 1
            if loadCount == 2 { throw URLError(.timedOut) }
            return apiTestJSONResponse(##"{"memory": "# Notes", "memory_mtime": 1770000000}"##, for: request)
        }
        let viewModel = MemoryViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        await viewModel.load()
        await viewModel.load()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertEqual(viewModel.content(for: .memory), "# Notes")
        XCTAssertNotNil(viewModel.errorMessage)

        await viewModel.load()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testLoadedEmptySectionsReadAsBlankWithNoTimestamp() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(##"{"memory": "# Notes"}"##, for: request)
        }
        let viewModel = MemoryViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        await viewModel.load()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertEqual(viewModel.content(for: .user), "")
        XCTAssertEqual(viewModel.content(for: .soul), "")
        XCTAssertNil(viewModel.modifiedAt(for: .user))
        XCTAssertNil(viewModel.modifiedAt(for: .soul))
    }

    @MainActor
    func testSaveTransportFailureKeepsTheSavedContentAndSurfacesTheError() async throws {
        let client = makeClient { request in
            if request.url?.path == "/api/memory/write" { throw URLError(.notConnectedToInternet) }
            return apiTestJSONResponse(##"{"memory": "# Notes"}"##, for: request)
        }
        let viewModel = MemoryViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)
        await viewModel.load()

        let didSave = await viewModel.save(section: .memory, content: "# Edited")

        XCTAssertFalse(didSave)
        XCTAssertFalse(viewModel.isSaving)
        XCTAssertEqual(viewModel.content(for: .memory), "# Notes")
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertEqual(viewModel.actionErrorMessage, viewModel.lastError?.localizedDescription)
        // A failed save is an editor error, not a screen load error.
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testSaveRejectedWithoutAReasonUsesTheGenericMessage() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"ok": false}"#, for: request)
        }
        let viewModel = MemoryViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        let didSave = await viewModel.save(section: .user, content: "# Me")

        XCTAssertFalse(didSave)
        XCTAssertEqual(viewModel.actionErrorMessage, String(localized: "Could not save memory."))
    }

    /// The write landed but the refresh did not: the editor reports failure so the
    /// user does not see stale text presented as saved.
    @MainActor
    func testSaveWhoseRefreshFailsReportsFailureWithTheRefreshError() async throws {
        var requestPaths: [String] = []
        let client = makeClient { request in
            requestPaths.append(request.url?.path ?? "")
            if request.url?.path == "/api/memory/write" {
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            }
            throw URLError(.networkConnectionLost)
        }
        let viewModel = MemoryViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        let didSave = await viewModel.save(section: .soul, content: "# Soul")

        XCTAssertFalse(didSave)
        XCTAssertEqual(requestPaths, ["/api/memory/write", "/api/memory"])
        XCTAssertNotNil(viewModel.actionErrorMessage)
        XCTAssertFalse(viewModel.hasLoaded)
    }

    @MainActor
    func testClearActionErrorDismissesTheEditorError() async throws {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"ok": false, "error": "section rejected"}"#, for: request)
        }
        let viewModel = MemoryViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)
        _ = await viewModel.save(section: .memory, content: "x")
        XCTAssertEqual(viewModel.actionErrorMessage, "section rejected")

        viewModel.clearActionError()

        XCTAssertNil(viewModel.actionErrorMessage)
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        return APIClient(baseURL: URL(string: "https://example.test")!, session: session)
    }
}
