import XCTest
@testable import HermesMobile

final class SkillsViewModelTests: APIClientTestCase {
    @MainActor
    func testGroupedSkillsNormalizesBlankCategoriesAndSortsRows() {
        let groups = SkillsViewModel.groupedSkills(for: [
            SkillSummary(name: "zed", category: " coding ", description: nil, path: nil),
            SkillSummary(name: "Alpha", category: "coding", description: nil, path: nil),
            SkillSummary(name: "loose", category: "   ", description: nil, path: nil),
            SkillSummary(name: nil, category: nil, description: nil, path: nil)
        ])

        XCTAssertEqual(groups.map(\.category), ["coding", "Uncategorized"])
        XCTAssertEqual(groups.first?.skills.map(\.name), ["Alpha", "zed"])
        XCTAssertEqual(groups.last?.skills.map { $0.name ?? "Unnamed Skill" }, ["loose", "Unnamed Skill"])
    }

    @MainActor
    func testToggleSkillOptimisticallyUpdatesThenReloadsServerState() async throws {
        var paths: [String] = []
        var skillsLoadCount = 0
        let client = makeClient { request in
            paths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/skills":
                skillsLoadCount += 1
                let disabled = skillsLoadCount > 1
                return apiTestJSONResponse("""
                {"skills": [{"name": "swift-refactor", "category": "coding", "disabled": \(disabled)}]}
                """, for: request)
            case "/api/skills/toggle":
                let body = try apiTestJSONBody(from: request)
                XCTAssertEqual(body["name"] as? String, "swift-refactor")
                XCTAssertEqual(body["enabled"] as? Bool, false)
                return apiTestJSONResponse("""
                {"ok": true, "name": "swift-refactor", "enabled": false}
                """, for: request)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = SkillsViewModel(client: client)

        await model.load()
        await model.setSkill(try XCTUnwrap(model.skills.first), enabled: false)

        XCTAssertEqual(paths, ["/api/skills", "/api/skills/toggle", "/api/skills"])
        XCTAssertEqual(model.skills.first?.disabled, true)
        XCTAssertNil(model.lastError)
    }

    @MainActor
    func testToggleSkillRevertsOnFailure() async throws {
        var shouldFailToggle = false
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/skills":
                return apiTestJSONResponse("""
                {"skills": [{"name": "swift-refactor", "category": "coding", "disabled": false}]}
                """, for: request)
            case "/api/skills/toggle":
                shouldFailToggle = true
                throw URLError(.notConnectedToInternet)
            default:
                XCTFail("Unexpected path: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let model = SkillsViewModel(client: client)

        await model.load()
        await model.setSkill(try XCTUnwrap(model.skills.first), enabled: false)

        XCTAssertTrue(shouldFailToggle)
        XCTAssertEqual(model.skills.first?.disabled, false)
        XCTAssertNotNil(model.lastError)
    }

    @MainActor
    func testLoadFailureOnFirstLoadSurfacesErrorWithNoRows() async {
        let client = makeClient { request in
            apiTestJSONResponse(#"{"error": "boom"}"#, for: request, status: 500)
        }
        let model = SkillsViewModel(client: client)

        await model.load()

        XCTAssertTrue(model.skills.isEmpty)
        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(model.errorMessage, model.lastError?.localizedDescription)
    }

    @MainActor
    func testReloadFailureKeepsTheLastListAndARetryClearsTheError() async {
        var loadCount = 0
        let client = makeClient { request in
            loadCount += 1
            if loadCount == 2 { throw URLError(.notConnectedToInternet) }
            return apiTestJSONResponse("""
            {"skills": [{"name": "swift-refactor", "category": "coding"}]}
            """, for: request)
        }
        let model = SkillsViewModel(client: client)

        await model.load()
        await model.load()

        XCTAssertEqual(model.skills.map(\.name), ["swift-refactor"])
        XCTAssertNotNil(model.errorMessage)

        await model.load()

        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.skills.map(\.name), ["swift-refactor"])
    }

    @MainActor
    func testLoadWithoutASkillsArrayIsAnEmptyListNotAnError() async {
        let client = makeClient { request in
            apiTestJSONResponse("{}", for: request)
        }
        let model = SkillsViewModel(client: client)

        await model.load()

        XCTAssertTrue(model.skills.isEmpty)
        XCTAssertTrue(model.groupedSkills.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testSearchMatchesNameDescriptionCategoryAndTags() async {
        let client = makeClient { request in
            apiTestJSONResponse("""
            {"skills": [
              {"name": "swift-refactor", "category": "coding", "description": "Rename symbols"},
              {"name": "inbox-triage", "category": "email", "tags": ["Gmail"]},
              {"name": "notes", "category": "writing"}
            ]}
            """, for: request)
        }
        let model = SkillsViewModel(client: client)
        await model.load()

        func names(_ query: String) -> [String?] {
            model.filteredGroupedSkills(searchText: query).flatMap { $0.skills.map(\.name) }
        }

        XCTAssertEqual(names("  "), names(""))
        XCTAssertEqual(names("").count, 3)
        XCTAssertEqual(names("REFACTOR"), ["swift-refactor"])
        XCTAssertEqual(names("rename"), ["swift-refactor"])
        XCTAssertEqual(names("writing"), ["notes"])
        XCTAssertEqual(names("gmail"), ["inbox-triage"])
        XCTAssertTrue(model.filteredGroupedSkills(searchText: "nothing-matches").isEmpty)
    }

    @MainActor
    func testToggleFailureSurfacesTheErrorMessageAndClearsTheBusyState() async throws {
        let client = makeClient { request in
            if request.url?.path == "/api/skills/toggle" {
                return apiTestJSONResponse(#"{"error": "nope"}"#, for: request, status: 500)
            }
            return apiTestJSONResponse("""
            {"skills": [{"name": "swift-refactor", "disabled": true}]}
            """, for: request)
        }
        let model = SkillsViewModel(client: client)
        await model.load()

        await model.setSkill(try XCTUnwrap(model.skills.first), enabled: true)

        XCTAssertEqual(model.skills.first?.disabled, true)
        XCTAssertEqual(model.errorMessage, model.lastError?.localizedDescription)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.togglingSkillNames.isEmpty)
    }

    @MainActor
    func testToggleIgnoresASkillWithoutAName() async {
        var requestCount = 0
        let client = makeClient { request in
            requestCount += 1
            return apiTestJSONResponse("{}", for: request)
        }
        let model = SkillsViewModel(client: client)

        await model.setSkill(SkillSummary(name: "  ", category: nil, description: nil, path: nil), enabled: false)

        XCTAssertEqual(requestCount, 0)
        XCTAssertTrue(model.togglingSkillNames.isEmpty)
    }

    @MainActor
    func testSecondToggleWhileOneIsInFlightIsDropped() async throws {
        let toggleStarted = expectation(description: "toggle request reached the server")
        let releaseToggle = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var toggleCount = 0
        let client = makeClient { request in
            if request.url?.path == "/api/skills/toggle" {
                lock.withLock { toggleCount += 1 }
                toggleStarted.fulfill()
                releaseToggle.wait()
                return apiTestJSONResponse(#"{"ok": true}"#, for: request)
            }
            return apiTestJSONResponse("""
            {"skills": [{"name": "swift-refactor", "disabled": false}]}
            """, for: request)
        }
        let model = SkillsViewModel(client: client)
        await model.load()
        let skill = try XCTUnwrap(model.skills.first)

        let first = Task { await model.setSkill(skill, enabled: false) }
        await fulfillment(of: [toggleStarted])
        XCTAssertEqual(model.togglingSkillNames, ["swift-refactor"])

        await model.setSkill(skill, enabled: false)
        releaseToggle.signal()
        await first.value

        XCTAssertEqual(lock.withLock { toggleCount }, 1)
        XCTAssertTrue(model.togglingSkillNames.isEmpty)
    }
}
