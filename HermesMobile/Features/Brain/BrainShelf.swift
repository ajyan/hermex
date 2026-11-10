import Foundation
import Observation

// The shelf for his writing (`GET /api/brain/shelf?kind=`): three read-only pages that grow
// with each answer filed from the Daily Brief. Models decode tolerantly, like `BrainModels.swift`;
// this route has no snake_case fields, so `.convertFromSnakeCase` and a plain decoder read it alike.

/// One page of the shelf. The raw value is the route's `kind`.
enum BrainShelfKind: String, CaseIterable, Codable, Hashable, Sendable {
    /// Letters to his daughter, oldest first: one book.
    case letters
    /// His answers on idea cards, newest first.
    case takes
    /// His answers on the Looking back cards, oldest first: a memoir.
    case memories

    var title: String {
        switch self {
        case .letters: "Letters"
        case .takes: "My takes"
        case .memories: "Memories"
        }
    }

    /// The paper its cards wear (DESIGN.md § The object key): each wears its Daily Brief card's.
    var paper: HermexPaper {
        switch self {
        case .letters: BrainModuleID.letters.paper
        case .takes, .memories: .knowledge
        }
    }

    /// The Daily Brief card's symbol, for the home row's tile.
    var symbolName: String {
        switch self {
        case .letters: BrainModuleID.letters.symbolName
        case .takes: DeckPalette.notes.symbol
        case .memories: DeckPalette.lookingBack.symbol
        }
    }

    /// The home row's line under the title.
    var subtitle: String {
        switch self {
        case .letters: "To her, from the first one on"
        case .takes: "Your answers on ideas"
        case .memories: "Your answers to Looking back"
        }
    }

    var emptyTitle: String {
        switch self {
        case .letters: "No letters yet"
        case .takes: "No takes yet"
        case .memories: "No memories yet"
        }
    }

    /// What will appear on the page, and from where.
    var emptyDescription: String {
        switch self {
        case .letters: "Each answer you file on the Daily Brief's Dad card appears here, oldest first."
        case .takes: "Each answer you file on a Daily Brief idea card appears here, newest first."
        case .memories: "Each answer you file on the Daily Brief's Looking back card appears here, oldest first."
        }
    }

    /// The header's count ("1 letter", "12 takes").
    func countLabel(_ count: Int) -> String {
        let noun: String
        switch self {
        case .letters: noun = count == 1 ? "letter" : "letters"
        case .takes: noun = count == 1 ? "take" : "takes"
        case .memories: noun = count == 1 ? "memory" : "memories"
        }
        return "\(count) \(noun)"
    }
}

private struct BrainShelfLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

private extension KeyedDecodingContainer {
    func shelfString(_ key: Key) -> String {
        ((try? decodeIfPresent(String.self, forKey: key)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The idea a take answered. `module` and `id` are nil when the idea has no Brain page
/// (or its module is one this build doesn't know); `title` still names it.
struct BrainShelfSource: Codable, Hashable, Sendable {
    let module: BrainModuleID?
    let id: String?
    let title: String

    private enum CodingKeys: String, CodingKey { case module, id, title }

    init(module: BrainModuleID? = nil, id: String? = nil, title: String = "") {
        self.module = module
        self.id = id
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        module = (try? c.decodeIfPresent(BrainModuleID.self, forKey: .module)) ?? nil
        let rawID = c.shelfString(.id)
        id = rawID.isEmpty ? nil : rawID
        title = c.shelfString(.title)
    }

    /// The idea's Brain page, when it has one.
    var route: BrainRoute? {
        guard let module, let id else { return nil }
        return .page(module, id)
    }
}

/// One thing he wrote. Missing fields are empty strings; `id` can repeat (several takes in one file).
struct BrainShelfEntry: Codable, Hashable, Sendable {
    let id: String
    /// An ISO day.
    let date: String
    let title: String
    /// Letters: when it was written (the countdown, or her age). Memories: who or what it is
    /// about. A weekly summing-up take: "Your take".
    let context: String
    /// The question he answered; on a take, the week's question.
    let prompt: String
    /// His words, plain text, paragraphs split by a blank line.
    let text: String
    /// Takes: the area's name.
    let group: String
    let source: BrainShelfSource?

    private enum CodingKeys: String, CodingKey { case id, date, title, context, prompt, text, group, source }

    init(id: String = "", date: String = "", title: String = "", context: String = "", prompt: String = "",
         text: String = "", group: String = "", source: BrainShelfSource? = nil) {
        self.id = id
        self.date = date
        self.title = title
        self.context = context
        self.prompt = prompt
        self.text = text
        self.group = group
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.shelfString(.id)
        date = c.shelfString(.date)
        title = c.shelfString(.title)
        context = c.shelfString(.context)
        prompt = c.shelfString(.prompt)
        text = c.shelfString(.text)
        group = c.shelfString(.group)
        source = (try? c.decodeIfPresent(BrainShelfSource.self, forKey: .source)) ?? nil
    }
}

/// `GET /api/brain/shelf` envelope, in the server's order.
struct BrainShelf: Codable, Equatable, Sendable {
    let kind: String
    let entries: [BrainShelfEntry]

    private enum CodingKeys: String, CodingKey { case kind, entries }

    init(kind: String = "", entries: [BrainShelfEntry] = []) {
        self.kind = kind
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.shelfString(.kind)
        entries = ((try? c.decodeIfPresent([BrainShelfLossy<BrainShelfEntry>].self, forKey: .entries)) ?? [])
            .compactMap(\.value)
    }
}

/// The shelf's pure decisions, kept out of the views so they can be tested.
enum BrainShelfLayout {
    /// One entry as its card shows it, built once per load.
    struct Card: Identifiable, Equatable {
        /// The entry's place, id and date: ids can repeat across takes in one file.
        let id: String
        /// The small line over the title, in the glow.
        let kicker: String
        let title: String
        /// The question he answered, when it isn't the title.
        let prompt: String
        /// His words.
        let text: String
        /// The idea's Brain page, its module, and what the chip that opens it says.
        let source: BrainRoute?
        let sourceModule: BrainModuleID?
        let sourceLabel: String

        /// VoiceOver's heading for the card: the kicker and the title.
        var accessibilityHeading: String {
            [kicker, title].filter { !$0.isEmpty }.joined(separator: ". ")
        }
    }

    static func cards(_ shelf: BrainShelf, kind: BrainShelfKind, locale: Locale = .current) -> [Card] {
        shelf.entries.enumerated().map { index, entry in
            card(entry, kind: kind, index: index, locale: locale)
        }
    }

    static func card(_ entry: BrainShelfEntry, kind: BrainShelfKind, index: Int, locale: Locale = .current) -> Card {
        let day = BrainStyle.displayDate(entry.date, locale: locale)
        let title: String
        var kicker: [String]
        switch kind {
        case .letters:
            // The day is the title; the kicker says when in her life it was written.
            title = first(entry.title, day, "Letter")
            kicker = [entry.context, day]
        case .takes:
            // The idea it answered leads; a weekly summing-up has none and says "Your take".
            title = first(entry.source?.title ?? "", entry.title, entry.context, "Your take")
            kicker = [entry.group, day]
        case .memories:
            title = first(entry.title, entry.prompt, day, "Memory")
            kicker = [entry.context, day]
        }
        // A letter titled with its own day ("November 5, 2026") doesn't repeat it above.
        kicker = kicker.filter { !$0.isEmpty && $0 != title && !(kind == .letters && $0 == day && !entry.title.isEmpty) }
        let route = entry.source?.route
        return Card(
            id: "\(index)|\(entry.id)|\(entry.date)",
            kicker: kicker.joined(separator: " · "),
            title: title,
            prompt: entry.prompt == title ? "" : entry.prompt,
            text: entry.text,
            source: route,
            sourceModule: route == nil ? nil : entry.source?.module,
            sourceLabel: route == nil ? "" : openLabel(entry.source?.module)
        )
    }

    private static func first(_ candidates: String...) -> String {
        candidates.first { !$0.isEmpty } ?? ""
    }

    /// What the chip under a take says: the kind of page the idea lives on.
    static func openLabel(_ module: BrainModuleID?) -> String {
        switch module {
        case .wiki: "Open the wiki page"
        case .articles: "Open the article"
        case .highlights: "Open the highlight"
        case .journal: "Open the journal day"
        case .people: "Open the person"
        case .letters: "Open the letter"
        case nil: ""
        }
    }

    /// One row of the Brain home's "Your writing" section.
    struct HomeRow: Identifiable, Equatable {
        let kind: BrainShelfKind
        /// How many entries the page holds; nil when the server hasn't said.
        let count: Int?
        var id: BrainShelfKind { kind }
    }

    /// The home's rows, in page order. Empty until any page has answered (now or from the saved
    /// copy), so a server without the shelf shows no section.
    static func homeRows(_ counts: [BrainShelfKind: Int]) -> [HomeRow] {
        guard !counts.isEmpty else { return [] }
        return BrainShelfKind.allCases.map { HomeRow(kind: $0, count: counts[$0]) }
    }

    /// Browse without the Letters module while the shelf has its Letters book: one Letters row.
    static func browseModules(_ modules: [BrainModule], showingShelf: Bool) -> [BrainModule] {
        showingShelf ? modules.filter { $0.id != .letters } : modules
    }
}

/// A 404 that says the server has no Brain at all. Any other 404 on this route is an older
/// fork without the shelf, which is an ordinary failure with a retry.
private func shelfHasNoBrain(_ error: Error) -> Bool {
    guard let apiError = error as? APIError, apiError.isNotFound else { return false }
    return apiError.serverMessage?.lowercased() == "brain not found"
}

/// The saved copy's cache kind; its id is the page's `kind`. `BrainCacheHandle` keys it by server.
private let shelfCacheKind = "shelf"

/// One shelf page.
@MainActor
@Observable
final class BrainShelfViewModel {
    let kind: BrainShelfKind
    private(set) var state: BrainLoadState<BrainShelf> = .loading
    /// The loaded entries as cards, built once per load, never while scrolling.
    private(set) var cards: [BrainShelfLayout.Card] = []
    private(set) var isShowingCachedCopy = false

    private let client: any BrainDataClient
    private let cache: BrainCacheHandle
    private let onAPIError: (Error) -> Void
    /// Bumped by every `load()`, so an older result never overwrites a newer one.
    private var generation = 0

    init(kind: BrainShelfKind, client: any BrainDataClient, cache: BrainCacheHandle,
         onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.kind = kind
        self.client = client
        self.cache = cache
        self.onAPIError = onAPIError
    }

    /// A page already loaded, for previews and screenshots: no network, no cache.
    convenience init(kind: BrainShelfKind, shelf: BrainShelf, cached: Bool = false) {
        self.init(kind: kind, client: BrainShelfNoClient(), cache: BrainCacheHandle(server: BrainShelfNoClient.server, context: nil))
        show(shelf, cached: cached)
    }

    private var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    func load() async {
        generation += 1
        let token = generation
        if !isLoaded { state = .loading }
        do {
            let fetched = try await client.shelf(kind: kind)
            guard !Task.isCancelled, token == generation else { return }
            show(fetched, cached: false)
            cache.store(fetched, kind: shelfCacheKind, id: kind.rawValue)
        } catch is CancellationError {
            // The screen went away; nothing to update.
        } catch {
            guard !Task.isCancelled, token == generation else { return }
            if shelfHasNoBrain(error) {
                cards = []
                isShowingCachedCopy = false
                state = .unavailable
            } else if isLoaded, !isShowingCachedCopy {
                // A failed refresh keeps the page already shown.
            } else if let saved = cache.load(BrainShelf.self, kind: shelfCacheKind, id: kind.rawValue) {
                show(saved, cached: true)
            } else {
                state = .failed(error.localizedDescription)
            }
            onAPIError(error)
        }
    }

    private func show(_ shelf: BrainShelf, cached: Bool) {
        if state != .loaded(shelf) {
            cards = BrainShelfLayout.cards(shelf, kind: kind)
            state = .loaded(shelf)
        }
        isShowingCachedCopy = cached
    }
}

/// The client behind a fixture page: every call fails, so a pull to refresh keeps the fixture.
private struct BrainShelfNoClient: BrainDataClient {
    static let server = URL(string: "https://fixture.invalid")!

    func modules() async throws -> [BrainModule] { throw CancellationError() }
    func list(module: BrainModuleID, tag: String?, cursor: Int?) async throws -> BrainList { throw CancellationError() }
    func page(module: BrainModuleID, id: String, hub: String?) async throws -> BrainPage { throw CancellationError() }
    func search(query: String, module: BrainModuleID?) async throws -> BrainSearchResult { throw CancellationError() }
    func home(batch: Int) async throws -> BrainHome { throw CancellationError() }
    func peopleHome() async throws -> BrainPeopleHome { throw CancellationError() }
    func shelf(kind: BrainShelfKind) async throws -> BrainShelf { throw CancellationError() }
    func logPerson(_ request: BrainPersonLogRequest) async throws -> BrainPersonLogResult { throw CancellationError() }
    func savePersonFacts(_ request: BrainPersonFactsRequest) async throws -> BrainPersonFactsResult { throw CancellationError() }
}

/// The Brain home's "Your writing" rows: how many entries each page holds. Best effort and
/// quiet: a server without the shelf never shows the section, and the pages report their own
/// errors. Each answer is saved, so a page opens offline even if it was never opened before.
@MainActor
@Observable
final class BrainShelfHomeViewModel {
    private(set) var rows: [BrainShelfLayout.HomeRow] = []

    private let client: any BrainDataClient
    private let cache: BrainCacheHandle
    private var generation = 0
    private var lastLoaded: Date?

    init(client: any BrainDataClient, cache: BrainCacheHandle) {
        self.client = client
        self.cache = cache
    }

    /// What the home's appear calls: skips the network while the last load is a few minutes old.
    func refreshIfStale(now: Date = .now, maxAge: TimeInterval = 300) async {
        if let lastLoaded, now.timeIntervalSince(lastLoaded) < maxAge { return }
        await load(now: now)
    }

    func load(now: Date = .now) async {
        generation += 1
        let token = generation
        let client = self.client
        let fetched = await withTaskGroup(of: (BrainShelfKind, BrainShelf?).self) { group in
            for kind in BrainShelfKind.allCases {
                group.addTask { (kind, try? await client.shelf(kind: kind)) }
            }
            var result: [BrainShelfKind: BrainShelf] = [:]
            for await (kind, shelf) in group { result[kind] = shelf }
            return result
        }
        guard !Task.isCancelled, token == generation else { return }
        var counts: [BrainShelfKind: Int] = [:]
        for kind in BrainShelfKind.allCases {
            if let shelf = fetched[kind] {
                counts[kind] = shelf.entries.count
                cache.store(shelf, kind: shelfCacheKind, id: kind.rawValue)
            } else if let saved = cache.load(BrainShelf.self, kind: shelfCacheKind, id: kind.rawValue) {
                counts[kind] = saved.entries.count
            }
        }
        let next = BrainShelfLayout.homeRows(counts)
        if next != rows { rows = next }
        if fetched.count == BrainShelfKind.allCases.count { lastLoaded = now }
    }
}
