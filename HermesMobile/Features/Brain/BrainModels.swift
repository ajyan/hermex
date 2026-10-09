import Foundation

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
struct BrainRef: Codable, Hashable, Sendable {
    let module: BrainModuleID
    let id: String
    let title: String
    let snippet: String
    let reason: String

    private enum CodingKeys: String, CodingKey { case module, id, title, snippet, reason }
    private enum LabelKey: String, CodingKey { case label }

    init(module: BrainModuleID, id: String, title: String = "", snippet: String = "", reason: String = "") {
        self.module = module
        self.id = id
        self.title = title
        self.snippet = snippet
        self.reason = reason
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

struct BrainPage: Codable, Hashable, Sendable {
    let item: BrainItem
    let content: String
    let links: [BrainRef]
    let backlinks: [BrainRef]
    let further: [BrainRef]
    let prev: BrainRef?
    let next: BrainRef?
    let highlights: [BrainHighlight]

    private enum CodingKeys: String, CodingKey {
        case item, content, links, backlinks, further, prev, next, highlights
    }

    init(item: BrainItem, content: String = "", links: [BrainRef] = [], backlinks: [BrainRef] = [],
         further: [BrainRef] = [], prev: BrainRef? = nil, next: BrainRef? = nil,
         highlights: [BrainHighlight] = []) {
        self.item = item
        self.content = content
        self.links = links
        self.backlinks = backlinks
        self.further = further
        self.prev = prev
        self.next = next
        self.highlights = highlights
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

    private enum CodingKeys: String, CodingKey { case module, id, title, weight }

    init(module: BrainModuleID, id: String, title: String = "", weight: Int = 0) {
        self.module = module
        self.id = id
        self.title = title
        self.weight = weight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        module = try c.decode(BrainModuleID.self, forKey: .module)
        id = c.string(.id)
        title = c.string(.title)
        weight = c.int(.weight)
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
