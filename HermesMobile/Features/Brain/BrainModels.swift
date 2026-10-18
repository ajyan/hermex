import Foundation
import SwiftUI

// Models for the Brain module API (`/api/brain/{modules,list,page,search,home}`).
// Every model is `Codable` so the module screens can cache them as JSON, and every
// field decodes tolerantly: missing or mistyped values fall back to a default and
// elements from an unknown module are dropped at the array level.

/// The five Brain modules. An unknown raw value fails to decode; arrays of module
/// content skip such elements via `BrainLossy`.
enum BrainModuleID: String, CaseIterable, Codable, Hashable, Sendable {
    case people, wiki, articles, journal, highlights, letters
}

/// A snake_case field read as written. `APIClient` decodes with `.convertFromSnakeCase`, so
/// models key these in camelCase; this covers a plain decoder (tests) reading the server's
/// raw JSON. The cache round-trips the camelCase key.
private func brainSnakeInt(_ decoder: Decoder, _ key: String) -> Int? {
    guard let key = BrainRawKey(stringValue: key),
          let raw = try? decoder.container(keyedBy: BrainRawKey.self)
    else { return nil }
    return try? raw.decodeIfPresent(Int.self, forKey: key)
}

private struct BrainRawKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Decodes an element or yields nil, so one bad element never fails its array.
private struct BrainLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    func string(_ key: Key) -> String {
        (try? decodeIfPresent(String.self, forKey: key)) ?? ""
    }

    func int(_ key: Key) -> Int {
        (try? decodeIfPresent(Int.self, forKey: key)) ?? 0
    }

    func strings(_ key: Key) -> [String] {
        (try? decodeIfPresent([String].self, forKey: key)) ?? []
    }

    /// An array that drops elements which fail to decode (e.g. an unknown module).
    func lossy<Value: Decodable>(_ type: Value.Type, _ key: Key) -> [Value] {
        ((try? decodeIfPresent([BrainLossy<Value>].self, forKey: key)) ?? []).compactMap(\.value)
    }

    func optional<Value: Decodable>(_ type: Value.Type, _ key: Key) -> Value? {
        try? decodeIfPresent(Value.self, forKey: key)
    }
}

struct BrainModule: Codable, Hashable, Sendable {
    let id: BrainModuleID
    let title: String
    let count: Int
    let subtitle: String

    private enum CodingKeys: String, CodingKey { case id, title, count, subtitle }

    init(id: BrainModuleID, title: String = "", count: Int = 0, subtitle: String = "") {
        self.id = id
        self.title = title
        self.count = count
        self.subtitle = subtitle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(BrainModuleID.self, forKey: .id)
        title = c.string(.title)
        count = c.int(.count)
        subtitle = c.string(.subtitle)
    }
}

/// `GET /api/brain/modules` envelope.
struct BrainModulesResponse: Decodable, Sendable {
    let modules: [BrainModule]

    private enum CodingKeys: String, CodingKey { case modules }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modules = c.lossy(BrainModule.self, .modules)
    }
}

struct BrainItem: Codable, Identifiable, Hashable, Sendable {
    let module: BrainModuleID
    let id: String
    let title: String
    let subtitle: String
    let date: String
    let tags: [String]
    let preview: String
    let kind: String
    let badge: String
    /// People only: the front matter's `relationship_type` (lowercased), for the list's filter.
    let relationshipType: String?

    private enum CodingKeys: String, CodingKey {
        case module, id, title, subtitle, date, tags, preview, kind, badge, relationshipType
    }

    init(module: BrainModuleID, id: String, title: String = "", subtitle: String = "", date: String = "",
         tags: [String] = [], preview: String = "", kind: String = "", badge: String = "",
         relationshipType: String? = nil) {
        self.module = module
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.date = date
        self.tags = tags
        self.preview = preview
        self.kind = kind
        self.badge = badge
        self.relationshipType = relationshipType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        module = try c.decode(BrainModuleID.self, forKey: .module)
        id = c.string(.id)
        title = c.string(.title)
        subtitle = c.string(.subtitle)
        date = c.string(.date)
        tags = c.strings(.tags)
        preview = c.string(.preview)
        kind = c.string(.kind)
        badge = c.string(.badge)
        relationshipType = c.optional(String.self, .relationshipType)
    }
}

/// One reference to a Brain item: a link, backlink, unlinked mention, further-reading
/// entry, search hit, or prev/next neighbor. Links arrive with `label` instead of `title`.
/// `tags` is the target item's tags, so a ref's cover takes the same hue as the page.
/// `snippet` is a link's target preview, or the text around a mention; `mention` is the
/// words in `snippet` that name the page, for highlighting.
struct BrainRef: Codable, Hashable, Sendable {
    let module: BrainModuleID
    let id: String
    let title: String
    let snippet: String
    let reason: String
    let tags: [String]
    let mention: String

    private enum CodingKeys: String, CodingKey { case module, id, title, snippet, reason, tags, mention }
    private enum LabelKey: String, CodingKey { case label }

    init(module: BrainModuleID, id: String, title: String = "", snippet: String = "", reason: String = "",
         tags: [String] = [], mention: String = "") {
        self.module = module
        self.id = id
        self.title = title
        self.snippet = snippet
        self.reason = reason
        self.tags = tags
        self.mention = mention
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        module = try c.decode(BrainModuleID.self, forKey: .module)
        id = c.string(.id)
        let decodedTitle = c.string(.title)
        if decodedTitle.isEmpty, let label = try? decoder.container(keyedBy: LabelKey.self) {
            title = label.string(.label)
        } else {
            title = decodedTitle
        }
        snippet = c.string(.snippet)
        reason = c.string(.reason)
        tags = c.strings(.tags)
        mention = c.string(.mention)
    }
}

/// Where a page sits in its hub: the hub, the page's place among the hub's pages, and its
/// neighbours there. `index` is nil when the page isn't one of the hub's pages (a hub set
/// by front matter it doesn't link with), and then `prev` and `next` are nil too.
struct BrainHubContext: Codable, Hashable, Sendable {
    let ref: BrainRef
    let index: Int?
    let count: Int
    let prev: BrainRef?
    let next: BrainRef?

    private enum CodingKeys: String, CodingKey { case ref, index, count, prev, next }

    init(ref: BrainRef, index: Int? = nil, count: Int = 0, prev: BrainRef? = nil, next: BrainRef? = nil) {
        self.ref = ref
        self.index = index
        self.count = count
        self.prev = prev
        self.next = next
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decode(BrainRef.self, forKey: .ref)
        index = c.optional(Int.self, .index)
        count = c.int(.count)
        prev = c.optional(BrainRef.self, .prev)
        next = c.optional(BrainRef.self, .next)
    }
}

struct BrainHighlight: Codable, Hashable, Sendable {
    let text: String
    let note: String?

    private enum CodingKeys: String, CodingKey { case text, note }

    init(text: String, note: String? = nil) {
        self.text = text
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.string(.text)
        note = c.optional(String.self, .note)
    }
}

/// One labelled fact on a person page ("Birthday", "1815-12-10"). Values are raw.
struct BrainFact: Codable, Hashable, Sendable {
    let label: String
    let value: String

    private enum CodingKeys: String, CodingKey { case label, value }

    init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = c.string(.label)
        value = c.string(.value)
    }
}

/// One dated entry in a person's encounter log. `bullets` are the entry's lines, `body` the raw markdown.
struct BrainEncounter: Codable, Hashable, Sendable {
    let id: String
    let date: String
    let title: String?
    let bullets: [String]
    let body: String

    private enum CodingKeys: String, CodingKey { case id, date, title, bullets, body }

    init(id: String, date: String, title: String? = nil, bullets: [String] = [], body: String = "") {
        self.id = id
        self.date = date
        self.title = title
        self.bullets = bullets
        self.body = body
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        date = c.string(.date)
        title = c.optional(String.self, .title)
        bullets = c.strings(.bullets)
        body = c.string(.body)
    }
}

/// A labelled group of profile lines on a person page ("Family", ["sister Mina"]).
struct BrainProfileSection: Codable, Hashable, Sendable {
    let label: String
    let items: [String]

    private enum CodingKeys: String, CodingKey { case label, items }

    init(label: String, items: [String] = []) {
        self.label = label
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = c.string(.label)
        items = c.strings(.items)
    }
}

/// A journal day that names the person: the day's snippet and the name it matched.
struct BrainJournalMention: Codable, Hashable, Sendable {
    let id: String
    let date: String
    let snippet: String
    let mention: String

    private enum CodingKeys: String, CodingKey { case id, date, snippet, mention }

    init(id: String, date: String, snippet: String = "", mention: String = "") {
        self.id = id
        self.date = date
        self.snippet = snippet
        self.mention = mention
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        date = c.string(.date)
        snippet = c.string(.snippet)
        mention = c.string(.mention)
    }
}

/// The structured view of a person page the server builds: encounters, profile, open questions,
/// leftover markdown, and journal mentions. Dates are ISO `YYYY-MM-DD` strings.
struct BrainPerson: Codable, Hashable, Sendable {
    let encounters: [BrainEncounter]
    let profile: [BrainProfileSection]
    let questions: [String]
    let other: String
    let lastSeen: String?
    let nextBirthday: String?
    let journal: [BrainJournalMention]
    /// A short recap of where things stand with the person; nil until the nightly digest writes one.
    let catchup: String?
    /// Up to three open threads to pick up next time.
    let threads: [String]
    /// Days seen per calendar month, oldest first, ending with this month (12 when present).
    let rhythm: [Int]

    private enum CodingKeys: String, CodingKey {
        case encounters, profile, questions, other, journal, lastSeen, nextBirthday, catchup, threads, rhythm
    }

    init(encounters: [BrainEncounter] = [], profile: [BrainProfileSection] = [], questions: [String] = [],
         other: String = "", lastSeen: String? = nil, nextBirthday: String? = nil,
         journal: [BrainJournalMention] = [], catchup: String? = nil, threads: [String] = [], rhythm: [Int] = []) {
        self.encounters = encounters
        self.profile = profile
        self.questions = questions
        self.other = other
        self.lastSeen = lastSeen
        self.nextBirthday = nextBirthday
        self.journal = journal
        self.catchup = catchup
        self.threads = threads
        self.rhythm = rhythm
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        encounters = c.lossy(BrainEncounter.self, .encounters)
        profile = c.lossy(BrainProfileSection.self, .profile)
        questions = c.strings(.questions)
        other = c.string(.other)
        lastSeen = c.optional(String.self, .lastSeen)
        nextBirthday = c.optional(String.self, .nextBirthday)
        journal = c.lossy(BrainJournalMention.self, .journal)
        catchup = c.optional(String.self, .catchup)
        threads = c.lossy(String.self, .threads)
        rhythm = c.lossy(Int.self, .rhythm)
    }
}

struct BrainPage: Codable, Hashable, Sendable {
    let item: BrainItem
    let content: String
    let links: [BrainRef]
    let backlinks: [BrainRef]
    let further: [BrainRef]
    let prev: BrainRef?
    let next: BrainRef?
    let highlights: [BrainHighlight]
    /// Person pages only: present frontmatter facts, in server order.
    let facts: [BrainFact]
    /// Items that name this page without linking to it (the first few), and how many there are.
    let unlinked: [BrainRef]
    let unlinkedCount: Int
    /// The page's place in its parent hub, for the trail and the pager.
    let hub: BrainHubContext?
    /// People pages only: the structured encounters/profile view; nil for other pages or older servers.
    let person: BrainPerson?

    private enum CodingKeys: String, CodingKey {
        case item, content, links, backlinks, further, prev, next, highlights, facts, unlinked, hub, unlinkedCount, person
    }

    init(item: BrainItem, content: String = "", links: [BrainRef] = [], backlinks: [BrainRef] = [],
         further: [BrainRef] = [], prev: BrainRef? = nil, next: BrainRef? = nil,
         highlights: [BrainHighlight] = [], facts: [BrainFact] = [], unlinked: [BrainRef] = [],
         unlinkedCount: Int? = nil, hub: BrainHubContext? = nil, person: BrainPerson? = nil) {
        self.item = item
        self.content = content
        self.links = links
        self.backlinks = backlinks
        self.further = further
        self.prev = prev
        self.next = next
        self.highlights = highlights
        self.facts = facts
        self.unlinked = unlinked
        self.unlinkedCount = unlinkedCount ?? unlinked.count
        self.hub = hub
        self.person = person
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(BrainItem.self, forKey: .item)
        content = c.string(.content)
        links = c.lossy(BrainRef.self, .links)
        backlinks = c.lossy(BrainRef.self, .backlinks)
        further = c.lossy(BrainRef.self, .further)
        prev = c.optional(BrainRef.self, .prev)
        next = c.optional(BrainRef.self, .next)
        highlights = c.lossy(BrainHighlight.self, .highlights)
        facts = c.lossy(BrainFact.self, .facts)
        unlinked = c.lossy(BrainRef.self, .unlinked)
        unlinkedCount = max(c.optional(Int.self, .unlinkedCount) ?? brainSnakeInt(decoder, "unlinked_count") ?? 0,
                            unlinked.count)
        hub = c.optional(BrainHubContext.self, .hub)
        person = c.optional(BrainPerson.self, .person)
    }
}

struct BrainTagCount: Codable, Hashable, Sendable {
    let tag: String
    let count: Int

    private enum CodingKeys: String, CodingKey { case tag, count }

    init(tag: String, count: Int = 0) {
        self.tag = tag
        self.count = count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = c.string(.tag)
        count = c.int(.count)
    }
}

/// A titled run of item ids (e.g. a journal month); absent for people and articles.
struct BrainGroup: Codable, Hashable, Sendable {
    let title: String
    let ids: [String]

    private enum CodingKeys: String, CodingKey { case title, ids }

    init(title: String, ids: [String] = []) {
        self.title = title
        self.ids = ids
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.string(.title)
        ids = c.strings(.ids)
    }
}

struct BrainList: Codable, Hashable, Sendable {
    let items: [BrainItem]
    let tags: [BrainTagCount]
    let groups: [BrainGroup]
    let nextCursor: Int?

    private enum CodingKeys: String, CodingKey {
        case items, tags, groups, nextCursor
    }

    init(items: [BrainItem] = [], tags: [BrainTagCount] = [], groups: [BrainGroup] = [], nextCursor: Int? = nil) {
        self.items = items
        self.tags = tags
        self.groups = groups
        self.nextCursor = nextCursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.lossy(BrainItem.self, .items)
        tags = c.lossy(BrainTagCount.self, .tags)
        groups = c.lossy(BrainGroup.self, .groups)
        nextCursor = c.optional(Int.self, .nextCursor) ?? brainSnakeInt(decoder, "next_cursor")
    }
}

struct BrainSearchGroup: Codable, Hashable, Sendable {
    let module: BrainModuleID
    let total: Int
    let items: [BrainRef]

    private enum CodingKeys: String, CodingKey { case module, total, items }

    init(module: BrainModuleID, total: Int = 0, items: [BrainRef] = []) {
        self.module = module
        self.total = total
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        module = try c.decode(BrainModuleID.self, forKey: .module)
        items = c.lossy(BrainRef.self, .items)
        total = (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? items.count
    }
}

struct BrainSearchResult: Codable, Hashable, Sendable {
    let groups: [BrainSearchGroup]

    private enum CodingKeys: String, CodingKey { case groups }

    init(groups: [BrainSearchGroup] = []) { self.groups = groups }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = c.lossy(BrainSearchGroup.self, .groups)
    }
}

/// One card in the Brain home's daily deck: a short piece of the library with where it came from.
/// `index` and `count` place an idea among its page's ideas; both nil for the other kinds.
struct BrainBite: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case idea, quote, highlight, takeaway, unknown }

    let id: String
    let kind: Kind
    let text: String
    let detail: String?
    let ref: BrainRef
    let byline: String
    let index: Int?
    let count: Int?

    private enum CodingKeys: String, CodingKey { case id, kind, text, detail, ref, byline, index, count }

    init(id: String, kind: Kind, text: String, detail: String? = nil, ref: BrainRef,
         byline: String = "", index: Int? = nil, count: Int? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.detail = detail
        self.ref = ref
        self.byline = byline
        self.index = index
        self.count = count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (c.optional(String.self, .kind)).flatMap(Kind.init(rawValue:)) ?? .unknown
        text = c.string(.text)
        detail = c.optional(String.self, .detail)
        ref = try c.decode(BrainRef.self, forKey: .ref)
        byline = c.string(.byline)
        index = c.optional(Int.self, .index)
        count = c.optional(Int.self, .count)
    }
}

/// `GET /api/brain/home[?batch=n]`: one batch of the daily deck. A server still sending the old
/// hubs/recent/rediscover shape decodes as an empty deck.
struct BrainHome: Codable, Hashable, Sendable {
    let bites: [BrainBite]
    let batch: Int
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey { case bites, batch, hasMore }

    init(bites: [BrainBite] = [], batch: Int = 0, hasMore: Bool = false) {
        self.bites = bites
        self.batch = batch
        self.hasMore = hasMore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bites = c.lossy(BrainBite.self, .bites).filter { $0.kind != .unknown }
        batch = c.int(.batch)
        hasMore = (c.optional(Bool.self, .hasMore)) ?? false
    }

    var isEmpty: Bool { bites.isEmpty }
}

/// `GET /api/brain/people/home`: the People screen's sections, each already ordered by the server.
/// An older server answers 404 and the screen shows only Everyone.
struct BrainPeopleHome: Codable, Hashable, Sendable {
    let due: [BrainPersonRow]
    let birthdays: [BrainPersonRow]
    let recent: [BrainPersonRow]

    private enum CodingKeys: String, CodingKey { case due, birthdays, recent }

    init(due: [BrainPersonRow] = [], birthdays: [BrainPersonRow] = [], recent: [BrainPersonRow] = []) {
        self.due = due
        self.birthdays = birthdays
        self.recent = recent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        due = c.lossy(BrainPersonRow.self, .due)
        birthdays = c.lossy(BrainPersonRow.self, .birthdays)
        recent = c.lossy(BrainPersonRow.self, .recent)
    }
}

/// One person in a People section. `lastSeen` and `nextBirthday` are ISO days; `headline` is the
/// newest encounter's title or first bullet; `cadenceDays` is their usual gap between visits.
struct BrainPersonRow: Codable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let lastSeen: String?
    let headline: String?
    let cadenceDays: Int?
    let nextBirthday: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, lastSeen, headline, cadenceDays, nextBirthday
    }

    init(id: String, title: String, subtitle: String = "", lastSeen: String? = nil, headline: String? = nil,
         cadenceDays: Int? = nil, nextBirthday: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.lastSeen = lastSeen
        self.headline = headline
        self.cadenceDays = cadenceDays
        self.nextBirthday = nextBirthday
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.string(.title)
        subtitle = c.string(.subtitle)
        lastSeen = c.optional(String.self, .lastSeen)
        headline = c.optional(String.self, .headline)
        cadenceDays = c.optional(Int.self, .cadenceDays)
        nextBirthday = c.optional(String.self, .nextBirthday)
    }
}

/// In-app links inside Brain Markdown: `brain://<module>/<percent-encoded id>`.
enum BrainLink {
    static func ref(from url: URL) -> (BrainModuleID, String)? {
        guard url.scheme == "brain",
              let host = url.host,
              let module = BrainModuleID(rawValue: host)
        else { return nil }
        let path = String(url.path(percentEncoded: true).dropFirst())
        guard let id = path.removingPercentEncoding, !id.isEmpty else { return nil }
        return (module, id)
    }
}

extension BrainModuleID {
    /// The module's name when the server's `modules` list isn't at hand
    /// (search groups carry only the id).
    var defaultTitle: String {
        switch self {
        case .people: "People"
        case .wiki: "Wiki"
        case .articles: "Articles"
        case .journal: "Journal"
        case .highlights: "Highlights"
        case .letters: "Letters"
        }
    }
}

/// A screen inside the Brain, pushed on the shell's stack as
/// `ShellPushDestination.brainRoute(_:)`.
enum BrainRoute: Hashable, Sendable {
    /// One module's browsable list.
    case module(BrainModuleID)
    /// One page, by module and item id.
    case page(BrainModuleID, String)
    /// One page opened from a review bite; `idea` is the key idea the bite came from,
    /// which the article digest opens expanded and scrolled into view.
    case bite(BrainModuleID, String, idea: Int?)
    /// Every search result in one module.
    case searchAll(BrainModuleID, query: String)
    /// Today's review deck, full screen.
    case review
    /// A screen in the Prep module (the interview tutor).
    case prep(PrepRoute)
}

/// A screen in the Prep module: its home, one track's skill map, today's run, or one gap.
enum PrepRoute: Hashable, Sendable {
    case home
    case track(String)
    case run
    case gap(String)
    /// One course lesson to re-read.
    case lesson(String)
    /// A unit's boss, taken early.
    case testout(String)
    /// The optional critique run over passed units.
    case mock
    /// "One more round": up to five more recalls after the day's run.
    case bonus
    /// One behavioral story, drilled on its own.
    case story(String)
    /// A voice mock ladder's brief, with Start call.
    case mockLadder(PrepMockKind)
    /// One voice mock's result, by mock id. `unsent` is the grade request when it never got
    /// through, for the result's Send for grading.
    case mockResult(String, unsent: MockCallGrade? = nil)
}

/// Opens a Brain page on the shell's stack from outside Brain (a `brain://` link in a
/// chat reply), or the Brain home from a page's trail. A reference, like
/// `ChatDisclosureToggleAction`: the shell keeps one instance and refreshes its handlers,
/// so chat readers never see a new value.
final class OpenBrainRouteAction {
    var handler: ((BrainRoute) -> Void)?
    /// Shows the Brain home (`ShellNavigationState.showBrainHome`).
    var homeHandler: (() -> Void)?

    /// True when a shell is listening; without one, Brain links can't open.
    var isAvailable: Bool { handler != nil }

    func callAsFunction(_ route: BrainRoute) { handler?(route) }

    func openHome() { homeHandler?() }
}

struct OpenBrainRouteKey: EnvironmentKey {
    static let defaultValue = OpenBrainRouteAction()
}

extension EnvironmentValues {
    var openBrainRoute: OpenBrainRouteAction {
        get { self[OpenBrainRouteKey.self] }
        set { self[OpenBrainRouteKey.self] = newValue }
    }
}

extension BrainLink {
    enum ChatAction: Equatable {
        case open(BrainRoute)
        /// A `brain://` link that can't open (malformed, or no shell listening): swallow it
        /// rather than hand an unknown scheme to iOS.
        case discard
    }

    /// What a tapped link does in a chat reply; nil for any link that isn't `brain://`.
    static func chatAction(for url: URL, canOpen: Bool) -> ChatAction? {
        guard url.scheme == "brain" else { return nil }
        guard canOpen, let (module, id) = ref(from: url) else { return .discard }
        return .open(.page(module, id))
    }
}
