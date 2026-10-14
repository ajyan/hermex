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

    func testSearchDecode() throws {
        let search = #"{"groups": [{"module": "wiki", "total": 3, "items": [{"module": "wiki", "id": "w", "title": "T", "snippet": "S", "tags": ["stoicism"]}, {"module": "wiki", "id": "u", "title": "U"}]}, {"module": "goals", "total": 1, "items": []}]}"#
        let result = try JSONDecoder().decode(BrainSearchResult.self, from: Data(search.utf8))
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].total, 3)
        XCTAssertEqual(result.groups[0].items[0].snippet, "S")
        XCTAssertEqual(result.groups[0].items[0].tags, ["stoicism"])
        XCTAssertEqual(result.groups[0].items[1].tags, [])

    }

    func testPageDecodesMentionsUnlinkedAndHub() throws {
        let json = #"""
        {"item": {"module": "wiki", "id": "wiki/anthropic.md", "title": "Anthropic"},
         "links": [{"module": "wiki", "id": "wiki/openai.md", "label": "OpenAI", "snippet": "The lab behind GPT."}],
         "backlinks": [{"module": "wiki", "id": "wiki/openai.md", "title": "OpenAI", "snippet": "and Anthropic define", "mention": "Anthropic"}],
         "unlinked": [{"module": "journal", "id": "j.md", "title": "Oct 6", "snippet": "read about anthropic", "mention": "anthropic"},
                      {"module": "goals", "id": "x"}],
         "unlinked_count": 13,
         "hub": {"ref": {"module": "wiki", "id": "wiki/career.md", "title": "Career"}, "index": 3, "count": 14,
                 "prev": {"module": "wiki", "id": "wiki/a.md", "title": "A"}, "next": null}}
        """#
        let page = try JSONDecoder().decode(BrainPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.links[0].title, "OpenAI")
        XCTAssertEqual(page.links[0].snippet, "The lab behind GPT.")
        XCTAssertEqual(page.backlinks[0].mention, "Anthropic")
        XCTAssertEqual(page.unlinked.map(\.id), ["j.md"], "an unknown module drops just that mention")
        XCTAssertEqual(page.unlinkedCount, 13)
        XCTAssertEqual(page.hub?.ref.id, "wiki/career.md")
        XCTAssertEqual(page.hub?.index, 3)
        XCTAssertEqual(page.hub?.count, 14)
        XCTAssertEqual(page.hub?.prev?.id, "wiki/a.md")
        XCTAssertNil(page.hub?.next)
        XCTAssertEqual(try JSONDecoder().decode(BrainPage.self, from: JSONEncoder().encode(page)), page)
    }

    /// `APIClient` decodes with `.convertFromSnakeCase`; snake_case fields must survive it.
    func testSnakeCaseFieldsDecodeThroughTheAPIClientDecoder() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let page = #"{"item": {"module": "wiki", "id": "w"}, "unlinked": [{"module": "wiki", "id": "u"}], "unlinked_count": 23}"#
        XCTAssertEqual(try decoder.decode(BrainPage.self, from: Data(page.utf8)).unlinkedCount, 23)
        let list = #"{"items": [], "next_cursor": 40}"#
        XCTAssertEqual(try decoder.decode(BrainList.self, from: Data(list.utf8)).nextCursor, 40)
    }

    private let personJSON = #"""
    {
      "encounters": [
        {"id": "2026-10-03#0", "date": "2026-10-03", "title": "Dinner",
         "bullets": ["met [Virtues](brain://wiki/wiki%2Fvirtues.md) fan", "talked about the move\n  to Lisbon next spring"],
         "body": "- met [Virtues](brain://wiki/wiki%2Fvirtues.md) fan\n- talked about the move\n  to Lisbon next spring"},
        {"id": "2026-06-05#0", "date": "2026-06-05", "title": null, "bullets": ["coffee near the park"],
         "body": "- coffee near the park"}
      ],
      "profile": [{"label": "Family", "items": ["sister Mina"]}, {"label": "Company", "items": ["Orbit Labs"]}],
      "questions": ["How is the move going?", "Did [Virtues](brain://wiki/wiki%2Fvirtues.md) come up again?"],
      "other": "",
      "last_seen": "2026-10-03",
      "next_birthday": "2026-12-24",
      "journal": [
        {"id": "journal/2026/10-October/2026-10-09.md", "date": "2026-10-09",
         "snippet": "Dara Quill texted about the move.", "mention": "Dara Quill"},
        {"id": "journal/2026/10-October/2026-10-08.md", "date": "2026-10-08",
         "snippet": "Lunch with Dara Quill downtown.", "mention": "Dara Quill"}
      ]
    }
    """#

    private var appDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func pageJSON(withPerson person: String) -> Data {
        Data(#"{"item": {"module": "people", "id": "people/dara.md"}, "content": "Dara", "person": \#(person)}"#.utf8)
    }

    func testPagePersonDecodes() throws {
        let page = try appDecoder.decode(BrainPage.self, from: pageJSON(withPerson: personJSON))
        let person = try XCTUnwrap(page.person)
        XCTAssertEqual(person.encounters.map(\.id), ["2026-10-03#0", "2026-06-05#0"])
        XCTAssertEqual(person.encounters[0].title, "Dinner")
        XCTAssertEqual(person.encounters[0].bullets.count, 2)
        XCTAssertTrue(person.encounters[0].body.hasPrefix("- met "))
        XCTAssertNil(person.encounters[1].title)
        XCTAssertEqual(person.profile, [BrainProfileSection(label: "Family", items: ["sister Mina"]),
                                        BrainProfileSection(label: "Company", items: ["Orbit Labs"])])
        XCTAssertEqual(person.questions.count, 2)
        XCTAssertEqual(person.other, "")
        XCTAssertEqual(person.lastSeen, "2026-10-03")
        XCTAssertEqual(person.nextBirthday, "2026-12-24")
        XCTAssertEqual(person.journal.map(\.date), ["2026-10-09", "2026-10-08"])
        XCTAssertEqual(person.journal[0].mention, "Dara Quill")
        XCTAssertEqual(person.journal[1].snippet, "Lunch with Dara Quill downtown.")
    }

    func testPageWithoutPersonDecodesNil() throws {
        let page = try appDecoder.decode(BrainPage.self, from: Data(pageJSON.utf8))
        XCTAssertNil(page.person)
        XCTAssertEqual(page.content, "# Virtues\n\nBody text.")
    }

    func testEncounterMissingFieldsDefault() throws {
        let encounter = try appDecoder.decode(BrainEncounter.self, from: Data(#"{"id":"x","date":"2026-01-01"}"#.utf8))
        XCTAssertNil(encounter.title)
        XCTAssertEqual(encounter.bullets, [])
        XCTAssertEqual(encounter.body, "")
    }

    /// The Brain cache stores pages with a plain encoder; a page cached before `person` existed
    /// still reads, and one with a person round-trips.
    func testPersonSurvivesCacheRoundTripAndOldCachedPageReads() throws {
        let page = try appDecoder.decode(BrainPage.self, from: pageJSON(withPerson: personJSON))
        let cached = try JSONEncoder().encode(page)
        XCTAssertEqual(try JSONDecoder().decode(BrainPage.self, from: cached), page)
        let old = try JSONEncoder().encode(try appDecoder.decode(BrainPage.self, from: Data(pageJSON.utf8)))
        XCTAssertNil(try JSONDecoder().decode(BrainPage.self, from: old).person)
    }

    func testOlderPageWithoutConnectionsStillDecodes() throws {
        let json = #"{"item": {"module": "wiki", "id": "w"}, "hub": {"ref": {"module": "goals", "id": "x"}}}"#
        let page = try JSONDecoder().decode(BrainPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.unlinked, [])
        XCTAssertEqual(page.unlinkedCount, 0)
        XCTAssertNil(page.hub, "a hub that can't decode is dropped, not the page")
        XCTAssertEqual(BrainRef(module: .wiki, id: "w").mention, "")
    }

    func testHomeDecodesBites() throws {
        let json = #"""
        {"bites": [
          {"id": "b1", "kind": "idea", "text": "T1", "detail": null, "byline": "Wiki",
           "ref": {"module": "wiki", "id": "wiki/a.md", "title": "A", "tags": ["x"]}, "index": 2, "count": 5},
          {"id": "b2", "kind": "quote", "text": "T2", "byline": "Ada",
           "ref": {"module": "articles", "id": "art/b.md", "title": "B", "tags": []}},
          {"id": "b3", "kind": "highlight", "text": "T3", "detail": "mine", "byline": "Book",
           "ref": {"module": "highlights", "id": "h/c.md", "title": "C", "tags": []}},
          {"id": "b4", "kind": "poem", "text": "T4", "byline": "?",
           "ref": {"module": "wiki", "id": "wiki/d.md", "title": "D", "tags": []}},
          {"id": "b5", "kind": "takeaway", "text": "T5", "byline": "Wiki",
           "ref": {"module": "wiki", "id": "wiki/e.md", "title": "E", "tags": []}}
         ], "batch": 1, "has_more": true}
        """#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let home = try decoder.decode(BrainHome.self, from: Data(json.utf8))
        XCTAssertEqual(home.bites.map(\.id), ["b1", "b2", "b3", "b5"], "unknown kinds drop, order holds")
        XCTAssertEqual(home.bites.map(\.kind), [.idea, .quote, .highlight, .takeaway])
        XCTAssertTrue(home.hasMore)
        XCTAssertEqual(home.batch, 1)
        XCTAssertEqual(home.bites[0].index, 2)
        XCTAssertEqual(home.bites[0].count, 5)
        XCTAssertNil(home.bites[0].detail)
        XCTAssertEqual(home.bites[0].ref.module, .wiki)
        XCTAssertEqual(home.bites[0].ref.tags, ["x"])
        XCTAssertEqual(home.bites[2].detail, "mine")
        XCTAssertFalse(home.isEmpty)
    }

    func testOldHomeShapeDecodesEmpty() throws {
        let json = #"""
        {"hubs": [{"ref": {"module": "wiki", "id": "wiki/career.md", "title": "Career"}, "count": 14}],
         "recent": [{"module": "wiki", "id": "wiki/a.md", "title": "A"}],
         "rediscover": [{"module": "wiki", "id": "wiki/old.md", "title": "Old"}]}
        """#
        let home = try JSONDecoder().decode(BrainHome.self, from: Data(json.utf8))
        XCTAssertTrue(home.bites.isEmpty)
        XCTAssertEqual(home.batch, 0)
        XCTAssertFalse(home.hasMore)
        XCTAssertTrue(home.isEmpty)
        XCTAssertTrue(try JSONDecoder().decode(BrainHome.self, from: Data("{}".utf8)).isEmpty)
    }

    func testHomeEndpointAddsBatchOnlyPastZero() {
        XCTAssertEqual(Endpoint.brainHome(batch: 0).path, "/api/brain/home")
        XCTAssertEqual(Endpoint.brainHome(batch: 0).queryItems, [])
        XCTAssertEqual(Endpoint.brainHome(batch: 2).queryItems, [URLQueryItem(name: "batch", value: "2")])
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
        XCTAssertEqual(Endpoint.brainPage(module: "wiki", id: "x.md", hub: nil).queryItems,
                       [URLQueryItem(name: "module", value: "wiki"), URLQueryItem(name: "id", value: "x.md")])
        XCTAssertEqual(Endpoint.brainPage(module: "wiki", id: "x.md", hub: "wiki/hub.md").queryItems,
                       [URLQueryItem(name: "module", value: "wiki"), URLQueryItem(name: "id", value: "x.md"),
                        URLQueryItem(name: "hub", value: "wiki/hub.md")])
        XCTAssertEqual(Endpoint.brainModules.queryItems, [])
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

    func testChatOpensValidBrainLinksAndLeavesOthersAlone() throws {
        let valid = try XCTUnwrap(URL(string: "brain://articles/email_ingest%2Fsummaries%2Fapi-gateway-summary.md"))
        XCTAssertEqual(BrainLink.chatAction(for: valid, canOpen: true),
                       .open(.page(.articles, "email_ingest/summaries/api-gateway-summary.md")))
        // No shell listening (e.g. a preview): swallow rather than hand brain:// to iOS.
        XCTAssertEqual(BrainLink.chatAction(for: valid, canOpen: false), .discard)
        XCTAssertEqual(BrainLink.chatAction(for: try XCTUnwrap(URL(string: "brain://goals/x.md")), canOpen: true), .discard)
        XCTAssertNil(BrainLink.chatAction(for: try XCTUnwrap(URL(string: "https://example.com")), canOpen: true))
        XCTAssertNil(BrainLink.chatAction(for: try XCTUnwrap(URL(string: "file:///tmp/a.swift")), canOpen: true))
    }

    func testOpenBrainRouteActionCallsItsHandler() {
        let action = OpenBrainRouteAction()
        XCTAssertFalse(action.isAvailable)
        var opened: [BrainRoute] = []
        action.handler = { opened.append($0) }
        action(.page(.wiki, "wiki/virtues.md"))
        XCTAssertTrue(action.isAvailable)
        XCTAssertEqual(opened, [.page(.wiki, "wiki/virtues.md")])
    }

    func testBiteCopy() {
        func bite(_ kind: BrainBite.Kind, _ module: BrainModuleID = .articles, id: String = "articles/a.md",
                  index: Int? = nil, count: Int? = nil) -> BrainBite {
            BrainBite(id: "x", kind: kind, text: "t", ref: BrainRef(module: module, id: id), index: index, count: count)
        }
        XCTAssertEqual(BrainBiteCopy.kicker(bite(.idea, index: 2, count: 5)), "Key idea · 2 of 5")
        XCTAssertEqual(BrainBiteCopy.kicker(bite(.idea)), "Key idea")
        XCTAssertEqual(BrainBiteCopy.kicker(bite(.idea, index: 2)), "Key idea")
        XCTAssertEqual(BrainBiteCopy.kicker(bite(.takeaway)), "Your takeaway")
        XCTAssertEqual(BrainBiteCopy.kicker(bite(.quote)), "Quote")
        XCTAssertEqual(BrainBiteCopy.kicker(bite(.highlight)), "Highlight")

        XCTAssertEqual(BrainBiteCopy.open(bite(.idea)), "Open the article")
        XCTAssertEqual(BrainBiteCopy.open(bite(.highlight, .highlights, id: "book:meditations")), "Open the book")
        XCTAssertEqual(BrainBiteCopy.open(bite(.idea, .highlights, id: "highlights/video.md")), "Open the note")
        XCTAssertEqual(BrainBiteCopy.open(bite(.quote, .wiki, id: "wiki/a.md")), "Open the note")

        XCTAssertEqual(bite(.idea).paper, .reading)
        XCTAssertEqual(bite(.takeaway).paper, .reading)
        XCTAssertEqual(bite(.quote).paper, .quote)
        XCTAssertEqual(bite(.highlight).paper, .book)

        XCTAssertEqual([.idea, .takeaway, .quote, .highlight].map { BrainBiteCopy.kind(bite($0)) },
                       ["Idea", "Takeaway", "Quote", "Highlight"])
        let titled = BrainBite(id: "y", kind: .idea, text: "t",
                               ref: BrainRef(module: .articles, id: "a.md", title: "The Bitter Lesson"), byline: "Rich Sutton")
        XCTAssertEqual(BrainBiteCopy.attribution(titled), "The Bitter Lesson · Rich Sutton")
        XCTAssertNil(BrainBiteCopy.attribution(bite(.idea)))
    }
}
