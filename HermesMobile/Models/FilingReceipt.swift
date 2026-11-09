import Foundation

/// The kind of vault page a chat turn wrote. It picks the chip's paper (the Brain's paper for
/// that kind of page) and its symbol. Raw values are the receipt's `kind`.
enum FiledPageKind: String, Equatable, CaseIterable {
    case person, journal, wiki, story, letter, note

    /// An unknown or missing kind reads as a note.
    init(wire: String?) {
        self = wire.flatMap { FiledPageKind(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) } ?? .note
    }

    var paper: HermexPaper {
        switch self {
        case .person: BrainModuleID.people.paper
        case .journal: BrainModuleID.journal.paper
        case .wiki: BrainModuleID.wiki.paper
        case .letter: BrainModuleID.letters.paper
        case .story: .prep
        case .note: .file
        }
    }

    /// One page of this kind, for VoiceOver ("Sam Rivera, Person").
    var name: String {
        switch self {
        case .person: BrainModuleID.people.kindName
        case .journal: BrainModuleID.journal.kindName
        case .wiki: BrainModuleID.wiki.kindName
        case .letter: BrainModuleID.letters.kindName
        case .story: "Story"
        case .note: "Note"
        }
    }

    var symbol: String {
        switch self {
        case .person: "person"
        case .journal: BrainModuleID.journal.symbolName
        case .wiki: BrainModuleID.wiki.symbolName
        case .letter: BrainModuleID.letters.symbolName
        case .story: "target"
        case .note: "doc.text"
        }
    }
}

/// One page a chat turn wrote in the vault, shown as a chip under the reply.
struct FiledPage: Codable, Equatable, Identifiable {
    let kind: FiledPageKind
    let title: String?
    /// What was written there ("Catch-up, Nov 9").
    let detail: String?
    /// A `BrainModuleID` raw value; absent when the page can't be opened in the Brain.
    let module: String?
    /// The page's id inside `module`.
    let pageID: String?
    /// Vault-relative.
    let path: String?
    /// "created" or "updated".
    let change: String?

    /// Two entries can share a page (a note and a follow-up on one person), so the id takes
    /// every field.
    var id: String {
        [kind.rawValue, module, pageID, path, title, detail, change]
            .map { $0 ?? "" }
            .joined(separator: "|")
    }

    init(
        kind: FiledPageKind = .note,
        title: String? = nil,
        detail: String? = nil,
        module: String? = nil,
        pageID: String? = nil,
        path: String? = nil,
        change: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.module = module
        self.pageID = pageID
        self.path = path
        self.change = change
    }

    /// The chip's words: "title · detail" when both exist, else whichever does.
    var label: String {
        let parts = [title, detail].compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        return parts.joined(separator: " · ")
    }

    /// The Brain screen the chip opens, or nil when the page has none.
    var route: BrainRoute? {
        let moduleName = module?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if let moduleID = BrainModuleID(rawValue: moduleName), let pageID, !pageID.isEmpty {
            return .page(moduleID, pageID)
        }
        if kind == .story, moduleName.isEmpty {
            return .prep(.home)
        }
        return nil
    }

    // `pageID` is read under both spellings: the REST client decodes with
    // `.convertFromSnakeCase` (`pageId`), the SSE path and the cache with a plain decoder
    // (`page_id`). It is written as `page_id`.
    private enum CodingKeys: String, CodingKey {
        case kind, title, detail, module, path, change
        case pageID = "page_id"
        case pageIDCamel = "pageId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = FiledPageKind(wire: container.decodeLossyStringIfPresent(forKey: .kind))
        title = container.decodeLossyStringIfPresent(forKey: .title)
        detail = container.decodeLossyStringIfPresent(forKey: .detail)
        module = container.decodeLossyStringIfPresent(forKey: .module)
        pageID = container.decodeLossyStringIfPresent(forKey: .pageID)
            ?? container.decodeLossyStringIfPresent(forKey: .pageIDCamel)
        path = container.decodeLossyStringIfPresent(forKey: .path)
        change = container.decodeLossyStringIfPresent(forKey: .change)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(module, forKey: .module)
        try container.encodeIfPresent(pageID, forKey: .pageID)
        try container.encodeIfPresent(path, forKey: .path)
        try container.encodeIfPresent(change, forKey: .change)
    }
}

/// What a chat turn wrote in the vault (`_filed` on the turn's last assistant message, and the
/// `filed` stream event). Every field is optional on the wire, and a page that doesn't decode
/// is skipped, so one bad entry never drops the rest.
struct FilingReceipt: Codable, Equatable {
    let id: String?
    var undone: Bool
    var canUndo: Bool
    let pages: [FiledPage]

    init(id: String? = nil, undone: Bool = false, canUndo: Bool = false, pages: [FiledPage] = []) {
        self.id = id
        self.undone = undone
        self.canUndo = canUndo
        self.pages = pages
    }

    // `canUndo` under both spellings, like `FiledPage.pageID`. It is written as `can_undo`.
    private enum CodingKeys: String, CodingKey {
        case id, undone, pages
        case canUndo = "can_undo"
        case canUndoCamel = "canUndo"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyStringIfPresent(forKey: .id)
        undone = container.decodeLossyBoolIfPresent(forKey: .undone) ?? false
        canUndo = container.decodeLossyBoolIfPresent(forKey: .canUndo)
            ?? container.decodeLossyBoolIfPresent(forKey: .canUndoCamel)
            ?? false
        let items = (try? container.decodeIfPresent([Lossy].self, forKey: .pages)) ?? []
        pages = items.compactMap(\.page)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(undone, forKey: .undone)
        try container.encode(canUndo, forKey: .canUndo)
        try container.encode(pages, forKey: .pages)
    }

    private struct Lossy: Decodable {
        let page: FiledPage?
        init(from decoder: Decoder) throws { page = try? FiledPage(from: decoder) }
    }
}

/// `POST /api/filing/undo`'s answer: the receipt, now undone, and how many pages went back.
struct FilingUndoResponse: Decodable, Equatable {
    let ok: Bool?
    let receipt: FilingReceipt?
    let restored: Int?
    let error: String?

    private enum CodingKeys: String, CodingKey { case ok, receipt, restored, error }

    init(ok: Bool? = nil, receipt: FilingReceipt? = nil, restored: Int? = nil, error: String? = nil) {
        self.ok = ok
        self.receipt = receipt
        self.restored = restored
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = container.decodeLossyBoolIfPresent(forKey: .ok)
        receipt = try? container.decodeIfPresent(FilingReceipt.self, forKey: .receipt)
        restored = container.decodeLossyIntIfPresent(forKey: .restored)
        error = container.decodeLossyStringIfPresent(forKey: .error)
    }
}
