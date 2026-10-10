import XCTest
@testable import HermesMobile

final class BrainArticleDigestTests: XCTestCase {
    private let article = """
    ## One-paragraph gist
    A guide to **gateways**: the [front desk](brain://wiki/wiki%2Fhotels.md) for services.

    ## Key ideas
    1. **Validate early** — reject bad requests at the edge.
    2. **Route by table**: the gateway maps paths to services.
       It stays stateless.
    3. **Cache sparingly**. Only for idempotent reads.
    4. Plain item without a bold lead

    ## Best quotes
    > "The front desk at a luxury hotel."

    > First line of a long quote
    > continues here.

    ## Connections
    - [[gone]] and [Systems](brain://wiki/wiki%2Fsystems.md)

    ## One takeaway for Andrew
    Start with the gateway when the interviewer says microservices.
    """

    func testParsesTheSummaryOutline() throws {
        let digest = try XCTUnwrap(BrainArticleDigest.parse(article))
        XCTAssertEqual(digest.gist, "A guide to **gateways**: the [front desk](brain://wiki/wiki%2Fhotels.md) for services.")
        XCTAssertEqual(digest.ideas.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(digest.ideas[0].headline, "Validate early")
        XCTAssertEqual(digest.ideas[0].detail, "reject bad requests at the edge.")
        XCTAssertEqual(digest.ideas[1].headline, "Route by table")
        XCTAssertEqual(digest.ideas[1].detail, "the gateway maps paths to services.\nIt stays stateless.")
        XCTAssertEqual(digest.ideas[2].detail, "Only for idempotent reads.")
        XCTAssertEqual(digest.ideas[3].headline, "Plain item without a bold lead")
        XCTAssertEqual(digest.ideas[3].detail, "")
        XCTAssertEqual(digest.quotes, ["The front desk at a luxury hotel.", "First line of a long quote continues here."])
        XCTAssertEqual(digest.takeaway, "Start with the gateway when the interviewer says microservices.")
        XCTAssertEqual(digest.otherSections.map(\.title), ["Connections"])
        XCTAssertNil(digest.ideasMarkdown)
    }

    func testUnnumberedKeyIdeasFallBackToMarkdown() throws {
        let page = "## One-paragraph gist\nGist.\n\n## Key ideas (deep)\n- a bullet\n- another\n"
        let digest = try XCTUnwrap(BrainArticleDigest.parse(page))
        XCTAssertTrue(digest.ideas.isEmpty)
        XCTAssertEqual(digest.ideasMarkdown, "- a bullet\n- another")
    }

    func testPagesOutsideTheOutlineStayPlain() {
        XCTAssertNil(BrainArticleDigest.parse("Just some notes.\n\n## Thoughts\nMore."))
        XCTAssertNil(BrainArticleDigest.parse("## One-paragraph gist\nOnly a gist."))
        XCTAssertNil(BrainArticleDigest.parse(""))
    }

    func testTakeawayVariantsAndExtraSectionsKeepOrder() throws {
        let page = "## The question\nWhy?\n\n## One-paragraph gist\nG.\n\n## Key ideas\n1. **A** — b\n\n## Takeaway for Andrew (interview prep)\nDo it.\n"
        let digest = try XCTUnwrap(BrainArticleDigest.parse(page))
        XCTAssertEqual(digest.takeaway, "Do it.")
        XCTAssertEqual(digest.otherSections.map(\.title), ["The question"])
    }

    func testPlainPreviewDropsMarkdown() {
        XCTAssertEqual(
            BrainArticleDigest.plainPreview("Use **bold**, *italic*, `code` and [a link](brain://wiki/x).\nNext line."),
            "Use bold, italic, code and a link. Next line."
        )
        XCTAssertEqual(BrainArticleDigest.plainPreview("snake_case_name stays"), "snake_case_name stays")
    }

    func testReaderUsesTheDigestOnlyForArticlesAndVideoNotes() {
        func page(_ module: BrainModuleID, kind: String) -> BrainPage {
            BrainPage(item: BrainItem(module: module, id: "x", title: "T", kind: kind),
                      content: article, links: [], backlinks: [], further: [], prev: nil, next: nil, highlights: [])
        }
        XCTAssertNotNil(BrainReaderLayout.digest(for: page(.articles, kind: "article")))
        XCTAssertNotNil(BrainReaderLayout.digest(for: page(.highlights, kind: "video")))
        XCTAssertNil(BrainReaderLayout.digest(for: page(.wiki, kind: "concept")))
        XCTAssertNil(BrainReaderLayout.digest(for: page(.journal, kind: "day")))
    }

    func testLongGistsFoldAndChannelTagsHide() {
        XCTAssertFalse(BrainArticleDigest.isLong("A short gist."))
        XCTAssertTrue(BrainArticleDigest.isLong(String(repeating: "word ", count: 61)))
        XCTAssertEqual(BrainReaderLayout.displayTags(["email", "system-design", "YouTube", "ai"]), ["system-design", "ai"])
    }
}
