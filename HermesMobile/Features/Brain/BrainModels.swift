import Foundation
import SwiftUI

// Models for the Brain module API (`/api/brain/{modules,list,page,search,graph}`).
// Every model is `Codable` so the module screens can cache them as JSON, and every
// field decodes tolerantly: missing or mistyped values fall back to a default and
// elements from an unknown module are dropped at the array level.

/// The five Brain modules. An unknown raw value fails to decode; arrays of module
/// content skip such elements via `BrainLossy`.
enum BrainModuleID: String, CaseIterable, Codable, Hashable, Sendable {
    case people, wiki, articles, journal, highlights
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

    private enum CodingKeys: String, CodingKey {
        case module, id, title, subtitle, date, tags, preview, kind, badge
    }

    init(module: BrainModuleID, id: String, title: String = "", subtitle: String = "", date: String = "",
         tags: [String] = [], preview: String = "", kind: String = "", badge: String = "") {
        self.module = module
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.date = date
        self.tags = tags
        self.preview = preview
        self.kind = kind
        self.badge = badge
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
    }
}

/// One reference to a Brain item: a link, backlink, further-reading entry, search
/// hit, or prev/next neighbor. Links arrive with `label` instead of `title`.
/// `tags` is the target item's tags, so a ref's cover takes the same hue as the page.
struct BrainRef: Codable, Hashable, Sendable {
    let module: BrainModuleID
    let id: String
    let title: String
    let snippet: String
    let reason: String
    let tags: [String]

    private enum CodingKeys: String, CodingKey { case module, id, title, snippet, reason, tags }
    private enum LabelKey: String, CodingKey { case label }

    init(module: BrainModuleID, id: String, title: String = "", snippet: String = "", reason: String = "",
         tags: [String] = []) {
        self.module = module
        self.id = id
        self.title = title
        self.snippet = snippet
        self.reason = reason
        self.tags = tags
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

    private enum CodingKeys: String, CodingKey {
        case item, content, links, backlinks, further, prev, next, highlights, facts
    }

    init(item: BrainItem, content: String = "", links: [BrainRef] = [], backlinks: [BrainRef] = [],
         further: [BrainRef] = [], prev: BrainRef? = nil, next: BrainRef? = nil,
         highlights: [BrainHighlight] = [], facts: [BrainFact] = []) {
        self.item = item
        self.content = content
        self.links = links
        self.backlinks = backlinks
        self.further = further
        self.prev = prev
        self.next = next
        self.highlights = highlights
        self.facts = facts
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
        case items, tags, groups
        case nextCursor = "next_cursor"
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
        nextCursor = c.optional(Int.self, .nextCursor)
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

struct BrainGraphNode: Codable, Hashable, Sendable {
    let module: BrainModuleID
    let id: String
    let title: String
    let weight: Int
    let tags: [String]

    private enum CodingKeys: String, CodingKey { case module, id, title, weight, tags }

    init(module: BrainModuleID, id: String, title: String = "", weight: Int = 0, tags: [String] = []) {
        self.module = module
        self.id = id
        self.title = title
        self.weight = weight
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        module = try c.decode(BrainModuleID.self, forKey: .module)
        id = c.string(.id)
        title = c.string(.title)
        weight = c.int(.weight)
        tags = c.strings(.tags)
    }
}

struct BrainGraphEdge: Codable, Hashable, Sendable {
    let a: String
    let b: String

    private enum CodingKeys: String, CodingKey { case a, b }

    init(a: String, b: String) {
        self.a = a
        self.b = b
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        a = c.string(.a)
        b = c.string(.b)
    }
}

struct BrainGraph: Codable, Hashable, Sendable {
    let nodes: [BrainGraphNode]
    let edges: [BrainGraphEdge]

    private enum CodingKeys: String, CodingKey { case nodes, edges }

    init(nodes: [BrainGraphNode] = [], edges: [BrainGraphEdge] = []) {
        self.nodes = nodes
        self.edges = edges
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodes = c.lossy(BrainGraphNode.self, .nodes)
        edges = c.lossy(BrainGraphEdge.self, .edges)
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
    /// Every search result in one module.
    case searchAll(BrainModuleID, query: String)
    /// A screen in the Prep module (the interview tutor).
    case prep(PrepRoute)
}

/// A screen in the Prep module: its home, one track's skill map, or today's run.
enum PrepRoute: Hashable, Sendable {
    case home
    case track(String)
    case run
}

/// Opens a Brain page on the shell's stack from outside Brain (a `brain://` link in a
/// chat reply). A reference, like `ChatDisclosureToggleAction`: the shell keeps one
/// instance and refreshes `handler`, so chat readers never see a new value.
final class OpenBrainRouteAction {
    var handler: ((BrainRoute) -> Void)?

    /// True when a shell is listening; without one, Brain links can't open.
    var isAvailable: Bool { handler != nil }

    func callAsFunction(_ route: BrainRoute) { handler?(route) }
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
