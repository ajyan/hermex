import XCTest
@testable import HermesMobile

/// The job pipeline's wire shapes (`tools/job_pipeline.py` through `api/vault_jobs.py`), its request bodies,
/// and the models over a scripted client.
final class JobPipelineModelTests: XCTestCase {
    static let summaryJSON = #"""
    {"today": "2026-11-02",
     "upcoming": [{"id": "obin-ai-agentic-ai-engineer", "company": "Obin AI", "role": "Agentic AI Engineer",
                   "key": "first-round", "label": "First round", "on": "2026-11-10", "time": null, "in_days": 8},
                  {"bad": true}],
     "applications": [{"id": "rilla-senior-software-engineer", "company": "Rilla", "role": "Senior Software Engineer",
                       "via": "Paraform", "stage": "screen", "stage_name": "Recruiter screen", "outcome": null,
                       "since": "2026-10-19", "days": 14, "open": true, "step": 1, "next": null},
                      {"id": "via-robert-goffin", "company": null, "role": null, "via": "Robert Goffin",
                       "stage": "screen", "stage_name": "Recruiter screen", "outcome": null, "since": "2026-10-29",
                       "days": 4, "open": true, "step": 1, "next": null}],
     "closed": [],
     "stages": [{"id": "applied", "name": "Applied"}, {"id": "screen", "name": "Recruiter screen"},
                {"id": "technical", "name": "Technical"}, {"id": "onsite", "name": "Onsite"}, {"id": "offer", "name": "Offer"}],
     "metrics": {"added_week": 2, "booked": 2, "recent": 11, "replies": 4, "quiet": 3,
                 "quiet_names": ["Rilla", "InstaLILY", "Scale AI"], "future_field": 1}}
    """#

    static let detailJSON = #"""
    {"id": "obin-ai-agentic-ai-engineer", "company": "Obin AI", "role": "Agentic AI Engineer", "via": null,
     "stage": "screen", "stage_name": "Recruiter screen", "outcome": null, "since": "2026-11-02", "days": 0,
     "open": true, "step": 1, "next": {"key": "first-round", "label": "First round", "on": "2026-11-10", "time": null},
     "url": "https://jobs.example/obin", "comp": "$150–180K base", "location": "NYC hybrid",
     "also": [{"role": "Senior AI Engineer", "comp": "$200–280K base", "note": "Ask to be considered"}],
     "interviews": [{"key": "first-round", "label": "First round", "on": "2026-11-10", "time": null}],
     "timeline": [{"date": "2026-11-02", "text": "First round: booked for 2026-11-10", "note": false}],
     "onepager": {"for": "First round · Tue Nov 10", "pitch": "I build agent systems.",
                  "company": ["AI workers for credit"],
                  "proof": [{"need": "Agents and RAG", "proof": "0.812 → 0.913", "stories": [{"id": "s9", "name": "Retrieval quality"}]},
                            {"need": "GCP", "proof": "Bridge from K8s", "stories": [], "gap": true}],
                  "raise": {"role": "Senior AI Engineer", "when": "At the end",
                            "rows": [{"need": "Eval", "proof": "CI gate", "stories": [{"id": "s9", "name": "Retrieval quality"}]}]},
                  "questions": [{"text": "An agent you shipped", "stories": [{"id": "s10", "name": "600-agent reliability loop"}]}],
                  "ask": ["What breaks?"], "watch": ["Base below your bar"],
                  "sources": [{"title": "Posting", "url": "https://jobs.example/obin"}]},
     "plan": [{"id": "s9", "name": "Retrieval quality", "title": "Owning retrieval quality", "told": true},
              {"id": "s10", "name": "600-agent reliability loop", "title": null, "told": false}],
     "stages": [{"id": "applied", "name": "Applied"}, {"id": "screen", "name": "Recruiter screen"}]}
    """#

    func testSummaryDecodesTolerantly() throws {
        let p = try PrepDecoding.decode(JobPipeline.self, from: Data(Self.summaryJSON.utf8))
        XCTAssertEqual(p.upcoming.map(\.company), ["Obin AI"])  // the malformed slot is dropped
        XCTAssertEqual(p.upcoming[0].inDays, 8)
        XCTAssertEqual(p.applications.map(\.name), ["Rilla", "Via Robert Goffin"])
        XCTAssertEqual(p.applications[0].stageName, "Recruiter screen")
        XCTAssertEqual(p.metrics?.quietNames, ["Rilla", "InstaLILY", "Scale AI"])
        XCTAssertEqual(p.stages.count, 5)
    }

    func testDetailCarriesTheOnePagerAndPlan() throws {
        let app = try PrepDecoding.decode(JobApplication.self, from: Data(Self.detailJSON.utf8))
        XCTAssertEqual(app.row.id, "obin-ai-agentic-ai-engineer")
        XCTAssertEqual(app.row.next?.on, "2026-11-10")
        XCTAssertEqual(app.also.first?.role, "Senior AI Engineer")
        let page = try XCTUnwrap(app.onepager)
        XCTAssertEqual(page.forLabel, "First round · Tue Nov 10")
        XCTAssertEqual(page.proof.map(\.gap), [false, true])
        XCTAssertEqual(page.proof[0].stories, [JobStoryRef(id: "s9", name: "Retrieval quality")])
        XCTAssertEqual(page.raise?.rows.first?.stories.first?.id, "s9")
        XCTAssertEqual(page.questions.first?.stories.first?.name, "600-agent reliability loop")
        XCTAssertEqual(app.plan.map(\.told), [true, false])
    }

    func testAnApplicationWithoutAOnePagerDecodes() throws {
        let json = #"{"id": "x", "company": "X", "stage": "applied", "stage_name": "Applied", "since": "2026-11-02", "days": 0, "open": true, "step": 0, "onepager": null}"#
        let app = try PrepDecoding.decode(JobApplication.self, from: Data(json.utf8))
        XCTAssertNil(app.onepager)
        XCTAssertEqual(app.plan, [])
    }

    func testRequestBodies() {
        XCTAssertEqual(JobPipelineAction.close(id: "rilla", outcome: "rejected").request,
                       JobPipelineRequest(action: "stage", id: "rilla", stage: "closed", outcome: "rejected"))
        XCTAssertEqual(JobPipelineAction.interview(id: "obin", label: "First round", on: nil, key: "first-round").request,
                       JobPipelineRequest(action: "interview", id: "obin", label: "First round", on: nil, key: "first-round"))
        XCTAssertEqual(JobPipelineAction.add(company: nil, role: nil, via: "Dana", url: nil, stage: nil).request,
                       JobPipelineRequest(action: "add", via: "Dana"))
    }

    func testStageLineAndDay() throws {
        let p = try PrepDecoding.decode(JobPipeline.self, from: Data(Self.summaryJSON.utf8))
        XCTAssertEqual(JobCopy.stageLine(p.applications[0]), "Recruiter screen · 14 days")
        XCTAssertEqual(JobCopy.when(inDays: 1), "tomorrow")
        XCTAssertEqual(JobCopy.outcomeLabel("no_reply"), "No reply in 30 days")
    }

    @MainActor
    func testApplicationModelShowsWhatTheServerSaved() async throws {
        let app = try PrepDecoding.decode(JobApplication.self, from: Data(Self.detailJSON.utf8))
        let client = ScriptedJobClient(application: app)
        let model = JobApplicationModel(id: app.row.id, client: client)
        await model.load()
        guard case .loaded = model.state else { return XCTFail("not loaded") }
        let saved = await model.act(.stage(id: app.row.id, stage: "technical"))
        XCTAssertTrue(saved)
        XCTAssertEqual(client.requests.last, JobPipelineRequest(action: "stage", id: app.row.id, stage: "technical"))
        client.fails = true
        let failed = await model.act(.note(id: app.row.id, text: "hi"))
        XCTAssertFalse(failed)
        XCTAssertEqual(model.error, "Couldn't save. Try again.")
        guard case .loaded = model.state else { return XCTFail("a failed save must keep the page") }
    }
}

private final class ScriptedJobClient: JobPipelineDataClient, @unchecked Sendable {
    let application: JobApplication
    var requests: [JobPipelineRequest] = []
    var fails = false

    init(application: JobApplication) { self.application = application }

    func pipeline() async throws -> JobPipeline {
        try PrepDecoding.decode(JobPipeline.self, from: Data(JobPipelineModelTests.summaryJSON.utf8))
    }

    func application(_ id: String) async throws -> JobApplication { application }

    func act(_ request: JobPipelineRequest) async throws -> JobApplication {
        requests.append(request)
        if fails { throw APIError.http(statusCode: 500, body: "boom") }
        return application
    }
}
