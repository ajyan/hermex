import XCTest
import Foundation
@testable import HermesMobile

final class BrainModelsTests: XCTestCase {
    private let pageJSON = #"""
    {
      "item": {"module": "wiki", "id": "wiki/virtues.md", "title": "Virtues", "subtitle": "Notes", "date": "2026-01-02",
               "tags": ["ethics"], "preview": "Short preview", "kind": "note", "badge": "A", "extra": 1},
      "content": "# Virtues\n\nBody text.",
      "links": [{"label": "Courage", "module": "wiki", "id": "wiki/courage.md", "tags": ["ethics", "virtue"]}],
      "backlinks": [{"module": "journal", "id": "j/1.md", "title": "Day one", "snippet": "mentions virtues", "tags": []}],
      "further": [{"module": "articles", "id": "a/2.md", "title": "Essay", "reason": "shared tag", "tags": ["habits"]}],
      "prev": {"module": "wiki", "id": "wiki/a.md", "title": "A", "tags": "not-a-list"},
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
        XCTAssertEqual(page.links.first?.tags, ["ethics", "virtue"])
        XCTAssertEqual(page.backlinks.first?.tags, [])
        XCTAssertEqual(page.further.first?.tags, ["habits"])
        XCTAssertEqual(page.prev?.tags, [], "a mistyped tags value falls back to empty")
        XCTAssertNil(page.next)
        XCTAssertEqual(page.highlights.map(\.text), ["Be brave", "No note"])
        XCTAssertEqual(page.highlights.last?.note, nil)
    }

    func testPageRoundTripsThroughJSON() throws {
        let page = try JSONDecoder().decode(BrainPage.self, from: Data(pageJSON.utf8))
        let data = try JSONEncoder().encode(page)
        let decoded = try JSONDecoder().decode(BrainPage.self, from: data)
        XCTAssertEqual(decoded, page)
        XCTAssertEqual(decoded.links.first?.tags, ["ethics", "virtue"], "tags survive the cache round trip")
        XCTAssertEqual(decoded.further.first?.tags, ["habits"])
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
        let search = #"{"groups": [{"module": "wiki", "total": 3, "items": [{"module": "wiki", "id": "w", "title": "T", "snippet": "S", "tags": ["stoicism"]}, {"module": "wiki", "id": "u", "title": "U"}]}, {"module": "goals", "total": 1, "items": []}]}"#
        let result = try JSONDecoder().decode(BrainSearchResult.self, from: Data(search.utf8))
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].total, 3)
        XCTAssertEqual(result.groups[0].items[0].snippet, "S")
        XCTAssertEqual(result.groups[0].items[0].tags, ["stoicism"])
        XCTAssertEqual(result.groups[0].items[1].tags, [])

        let graph = #"{"nodes": [{"module": "wiki", "id": "a", "title": "A", "weight": 2, "tags": ["llm"]}, {"module": "wiki", "id": "b"}], "edges": [{"a": "a", "b": "b"}]}"#
        let decoded = try JSONDecoder().decode(BrainGraph.self, from: Data(graph.utf8))
        XCTAssertEqual(decoded.nodes[0].weight, 2)
        XCTAssertEqual(decoded.nodes[0].tags, ["llm"])
        XCTAssertEqual(decoded.nodes[1].tags, [])
        XCTAssertEqual(try JSONDecoder().decode(BrainGraph.self, from: JSONEncoder().encode(decoded)), decoded)
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

    func testSearchURLEncodesPlusAndSpace() throws {
        let base = try XCTUnwrap(URL(string: "https://brain.example"))
        let plus = Endpoint.brainSearch(query: "c++", module: nil).url(relativeTo: base)
        let plusQuery = try XCTUnwrap(URLComponents(url: plus, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        XCTAssertEqual(plusQuery, "q=c%2B%2B")
        let space = Endpoint.brainSearch(query: "ada l", module: "people").url(relativeTo: base)
        let spaceQuery = try XCTUnwrap(URLComponents(url: space, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        XCTAssertEqual(spaceQuery, "q=ada%20l&module=people")
        XCTAssertEqual(URLComponents(url: plus, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "c++",
                       "the encoded query still decodes back to the original value")
    }
}
