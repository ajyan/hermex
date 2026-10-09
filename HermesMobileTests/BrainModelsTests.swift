import XCTest
import Foundation
@testable import HermesMobile

final class BrainModelsTests: XCTestCase {
    private let pageJSON = #"""
    {
      "item": {"module": "wiki", "id": "wiki/virtues.md", "title": "Virtues", "subtitle": "Notes", "date": "2026-01-02",
               "tags": ["ethics"], "preview": "Short preview", "kind": "note", "badge": "A", "extra": 1},
      "content": "# Virtues\n\nBody text.",
      "links": [{"label": "Courage", "module": "wiki", "id": "wiki/courage.md"}],
      "backlinks": [{"module": "journal", "id": "j/1.md", "title": "Day one", "snippet": "mentions virtues"}],
      "further": [{"module": "articles", "id": "a/2.md", "title": "Essay", "reason": "shared tag"}],
      "prev": {"module": "wiki", "id": "wiki/a.md", "title": "A"},
      "next": null,
      "highlights": [{"text": "Be brave", "note": "remember"}, {"text": "No note"}]
    }
    """#

    func testPageDecodesFullShape() throws {
        let page = try JSONDecoder().decode(BrainPage.self, from: Data(pageJSON.utf8))
        XCTAssertEqual(page.item.module, .wiki)
        XCTAssertEqual(page.item.id, "wiki/virtues.md")
        XCTAssertEqual(page.item.tags, ["ethics"])
        XCTAssertEqual(page.content, "# Virtues\n\nBody text.")
        XCTAssertEqual(page.links.first?.title, "Courage")
        XCTAssertEqual(page.links.first?.snippet, "")
        XCTAssertEqual(page.backlinks.first?.snippet, "mentions virtues")
        XCTAssertEqual(page.further.first?.reason, "shared tag")
        XCTAssertEqual(page.prev?.id, "wiki/a.md")
        XCTAssertNil(page.next)
        XCTAssertEqual(page.highlights.map(\.text), ["Be brave", "No note"])
        XCTAssertEqual(page.highlights.last?.note, nil)
    }

    func testPageRoundTripsThroughJSON() throws {
        let page = try JSONDecoder().decode(BrainPage.self, from: Data(pageJSON.utf8))
        let data = try JSONEncoder().encode(page)
        XCTAssertEqual(try JSONDecoder().decode(BrainPage.self, from: data), page)
    }

    func testPageDecodesFacts() throws {
        let json = #"""
        {"item": {"module": "people", "id": "crm/contacts/Ada.md", "title": "Ada"},
         "facts": [{"label": "Last contacted", "value": "2026-10-01"},
                   {"label": "Birthday", "value": "1815-12-10"},
                   {"label": 3}]}
        """#
        let page = try JSONDecoder().decode(BrainPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.facts, [BrainFact(label: "Last contacted", value: "2026-10-01"),
                                    BrainFact(label: "Birthday", value: "1815-12-10"),
                                    BrainFact(label: "", value: "")])
        let data = try JSONEncoder().encode(page)
        XCTAssertEqual(try JSONDecoder().decode(BrainPage.self, from: data), page)
        let bare = try JSONDecoder().decode(BrainPage.self, from: Data(pageJSON.utf8))
        XCTAssertEqual(bare.facts, [])
    }

    func testDecodeToleratesMissingFieldsAndUnknownModule() throws {
        let json = #"""
        {"items": [{"module": "people", "id": "p1", "title": "Ada"},
                   {"module": "goals", "id": "g1", "title": "Skip me"},
                   {"module": "wiki", "id": "w1", "title": "Page"}],
         "tags": [{"tag": "x", "count": 2}], "next_cursor": 40}
        """#
        let list = try JSONDecoder().decode(BrainList.self, from: Data(json.utf8))
        XCTAssertEqual(list.items.map(\.id), ["p1", "w1"])
        XCTAssertEqual(list.items[0].tags, [])
        XCTAssertEqual(list.items[0].preview, "")
        XCTAssertEqual(list.groups, [])
        XCTAssertEqual(list.tags, [BrainTagCount(tag: "x", count: 2)])
        XCTAssertEqual(list.nextCursor, 40)
    }

    func testSearchAndGraphDecode() throws {
        let search = #"{"groups": [{"module": "wiki", "total": 3, "items": [{"module": "wiki", "id": "w", "title": "T", "snippet": "S"}]}, {"module": "goals", "total": 1, "items": []}]}"#
        let result = try JSONDecoder().decode(BrainSearchResult.self, from: Data(search.utf8))
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].total, 3)
        XCTAssertEqual(result.groups[0].items[0].snippet, "S")

        let graph = #"{"nodes": [{"module": "wiki", "id": "a", "title": "A", "weight": 2}], "edges": [{"a": "a", "b": "b"}]}"#
        let decoded = try JSONDecoder().decode(BrainGraph.self, from: Data(graph.utf8))
        XCTAssertEqual(decoded.nodes[0].weight, 2)
        XCTAssertEqual(decoded.edges, [BrainGraphEdge(a: "a", b: "b")])
    }

    func testBrainLinkParsesPercentEncodedID() throws {
        let url = try XCTUnwrap(URL(string: "brain://wiki/wiki%2Fvirtues.md"))
        let ref = BrainLink.ref(from: url)
        XCTAssertEqual(ref?.0, .wiki)
        XCTAssertEqual(ref?.1, "wiki/virtues.md")
        XCTAssertNil(BrainLink.ref(from: try XCTUnwrap(URL(string: "https://x"))))
        XCTAssertNil(BrainLink.ref(from: try XCTUnwrap(URL(string: "brain://goals/x"))))
    }

    func testEndpointQueryItems() {
        XCTAssertEqual(Endpoint.brainList(module: "wiki", tag: nil, cursor: nil).queryItems,
                       [URLQueryItem(name: "module", value: "wiki")])
        XCTAssertEqual(Endpoint.brainList(module: "wiki", tag: "a", cursor: 5).queryItems,
                       [URLQueryItem(name: "module", value: "wiki"), URLQueryItem(name: "tag", value: "a"), URLQueryItem(name: "cursor", value: "5")])
        XCTAssertEqual(Endpoint.brainSearch(query: "ada l", module: nil).queryItems,
                       [URLQueryItem(name: "q", value: "ada l")])
        XCTAssertEqual(Endpoint.brainPage(module: "wiki", id: "x.md").queryItems,
                       [URLQueryItem(name: "module", value: "wiki"), URLQueryItem(name: "id", value: "x.md")])
        XCTAssertEqual(Endpoint.brainModules.queryItems, [])
        XCTAssertEqual(Endpoint.brainGraph(module: "wiki", id: "x").path, "/api/brain/graph")
    }
}
