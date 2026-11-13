import Foundation
import Observation
import SwiftUI

// MARK: - Models

/// One state on the Status screen: a tile's, a day's, or the whole screen's. The server says
/// `ok`, `warn` or `down`; a day can be `none` (nothing recorded) and the whole screen `stale`
/// (the checks stopped). Anything unknown reads as `warn`, so a new state never shows as fine.
enum AtlasStatusLevel: String, Decodable, Equatable, Sendable {
    case ok, warn, down, stale, none

    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(Self.init(rawValue:)) ?? .warn
    }

    /// Worse states sort first.
    var severity: Int {
        switch self {
        case .down: 3
        case .stale: 2
        case .warn: 1
        case .ok, .none: 0
        }
    }
}

/// What `GET /api/atlas/status` answers (`api/vault_status.py` on this user's webui fork): the
/// watcher's and health checks' verdicts from the vault ledger, grouped into six tiles. Every
/// field decodes tolerantly; stock servers answer 404.
struct AtlasStatus: Decodable, Equatable, Sendable {
    var checkedAt: Date?
    var overall: AtlasStatusLevel
    var stale: Stale?
    var headline: String
    var summary: String?
    var tiles: [Tile]
    var fixed: [Fix]

    struct Stale: Decodable, Equatable, Sendable {
        var what: String
        var since: Date?
        var text: String
    }

    struct Tile: Decodable, Equatable, Identifiable, Sendable {
        var id: String
        var title: String
        var state: AtlasStatusLevel
        /// Seven days, oldest first, today last.
        var days: [AtlasStatusLevel]
        var fact: String?
        var problems: [Problem]
        var checks: [Check]
    }

    struct Problem: Decodable, Equatable, Sendable {
        var state: AtlasStatusLevel
        var text: String
        var since: Date?
    }

    struct Check: Decodable, Equatable, Sendable {
        var name: String
        var value: String
        var state: AtlasStatusLevel
    }

    struct Fix: Decodable, Equatable, Sendable {
        var tile: String
        var text: String
        var at: Date?
    }

    func tile(_ id: String) -> Tile? { tiles.first { $0.id == id } }

    static func decode(_ data: Data) throws -> AtlasStatus {
        try JSONDecoder().decode(AtlasStatus.self, from: data)
    }
}

private enum AtlasStatusKeys: String, CodingKey {
    case checkedAt = "checked_at", overall, stale, headline, summary, tiles, fixed
    case what, since, text, id, title, state, days, fact, problems, checks, name, value, tile, at
}

private extension KeyedDecodingContainer where Key == AtlasStatusKeys {
    func string(_ key: Key) -> String { (try? decodeIfPresent(String.self, forKey: key)) ?? "" }
    func optionalString(_ key: Key) -> String? {
        guard let value = try? decodeIfPresent(String.self, forKey: key), !value.isEmpty else { return nil }
        return value
    }
    func level(_ key: Key) -> AtlasStatusLevel { (try? decodeIfPresent(AtlasStatusLevel.self, forKey: key)) ?? .warn }
    func date(_ key: Key) -> Date? { optionalString(key).flatMap(AtlasStatusCopy.date) }
    func list<Value: Decodable>(_ key: Key) -> [Value] {
        ((try? decodeIfPresent([PrepLossy<Value>].self, forKey: key)) ?? []).compactMap(\.value)
    }
}

extension AtlasStatus {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AtlasStatusKeys.self)
        checkedAt = c.date(.checkedAt)
        overall = c.level(.overall)
        stale = try? c.decodeIfPresent(Stale.self, forKey: .stale)
        headline = c.string(.headline)
        summary = c.optionalString(.summary)
        tiles = c.list(.tiles)
        fixed = c.list(.fixed)
    }
}

extension AtlasStatus.Stale {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AtlasStatusKeys.self)
        what = c.string(.what)
        since = c.date(.since)
        text = c.string(.text)
    }
}

extension AtlasStatus.Tile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AtlasStatusKeys.self)
        id = c.string(.id)
        guard !id.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "no id") }
        title = c.optionalString(.title) ?? id.capitalized
        state = c.level(.state)
        days = (try? c.decodeIfPresent([AtlasStatusLevel].self, forKey: .days)) ?? []
        fact = c.optionalString(.fact)
        problems = c.list(.problems)
        checks = c.list(.checks)
    }
}

extension AtlasStatus.Problem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AtlasStatusKeys.self)
        state = c.level(.state)
        text = c.string(.text)
        since = c.date(.since)
    }
}

extension AtlasStatus.Check {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AtlasStatusKeys.self)
        name = c.string(.name)
        value = c.string(.value)
        state = c.level(.state)
    }
}

extension AtlasStatus.Fix {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AtlasStatusKeys.self)
        tile = c.string(.tile)
        text = c.string(.text)
        at = c.date(.at)
    }
}

// MARK: - Copy

/// The Status screen's words and colors. Color is only ever the semantic status color, beside a word.
enum AtlasStatusCopy {
    static func word(_ level: AtlasStatusLevel) -> String {
        switch level {
        case .down: "Needs you"
        case .warn: "Look this week"
        case .ok: "OK"
        case .stale: "Checks stopped"
        case .none: "No data"
        }
    }

    static func color(_ level: AtlasStatusLevel) -> Color {
        switch level {
        case .down: .hxDanger
        case .warn, .stale: .hxWarning
        case .ok: .hxSuccess
        case .none: .hxTextSecondary
        }
    }

    static func symbol(_ level: AtlasStatusLevel) -> String {
        switch level {
        case .down: "exclamationmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .stale: "clock.badge.exclamationmark"
        case .ok, .none: "checkmark.circle.fill"
        }
    }

    /// The drawer bar's note: "All good" with no mark, else how many tiles need something.
    static func drawerNote(_ status: AtlasStatus) -> AtlasStatusDrawerNote {
        if status.overall == .stale { return AtlasStatusDrawerNote(text: "Checks stopped", level: .stale) }
        let down = status.tiles.filter { $0.state == .down }.count
        if down > 0 { return AtlasStatusDrawerNote(text: down == 1 ? "1 needs you" : "\(down) need you", level: .down) }
        let warn = status.tiles.filter { $0.state == .warn }.count
        if warn > 0 { return AtlasStatusDrawerNote(text: "\(warn) to look at", level: .warn) }
        return AtlasStatusDrawerNote(text: "All good", level: nil)
    }

    /// "Checked just now", "Checked 4 min ago", "Checked 2 h ago".
    static func checked(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "Checked just now" }
        if minutes < 60 { return "Checked \(minutes) min ago" }
        return "Checked \(minutes / 60) h ago"
    }

    /// When a problem began: "Since today 8:26 AM", "Since yesterday 8:26 AM", "Since Thu 8:23 AM",
    /// "Since Nov 2".
    static func since(_ date: Date?, now: Date, calendar: Calendar = .current) -> String? {
        guard let date else { return nil }
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Since today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Since yesterday \(time)"
        }
        if now.timeIntervalSince(date) < 6 * 86_400 {
            return "Since \(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return "Since \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// A fix's line under it: "Disk · yesterday 8:24 PM".
    static func fixed(_ fix: AtlasStatus.Fix, title: String, now: Date, calendar: Calendar = .current) -> String {
        guard let at = fix.at else { return title }
        let time = at.formatted(date: .omitted, time: .shortened)
        let day = calendar.isDate(at, inSameDayAs: now) ? "today" : "yesterday"
        return "\(title) · \(day) \(time)"
    }

    /// One letter per day for the seven days ending `now`, oldest first ("S S M T W T F").
    static func letters(now: Date, calendar: Calendar = .current) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).reversed().map { back in
            let day = calendar.date(byAdding: .day, value: -back, to: now) ?? now
            return symbols[calendar.component(.weekday, from: day) - 1]
        }
    }

    /// VoiceOver for a tile row: "App, needs you, night-chain keeps failing. Last 7 days: OK 5 days, needs you 2 days."
    static func accessibility(_ tile: AtlasStatus.Tile) -> String {
        var parts = ["\(tile.title), \(word(tile.state).lowercased())"]
        if let fact = tile.fact { parts.append(fact) }
        var line = parts.joined(separator: ", ")
        let counts = [AtlasStatusLevel.ok, .warn, .down, .none].compactMap { level -> String? in
            let n = tile.days.filter { $0 == level }.count
            guard n > 0 else { return nil }
            return "\(word(level).lowercased()) \(n) \(n == 1 ? "day" : "days")"
        }
        if !counts.isEmpty { line += ". Last 7 days: " + counts.joined(separator: ", ") }
        return line + "."
    }

    /// The words Ask Atlas starts a chat with.
    static func ask(_ tile: AtlasStatus.Tile) -> String {
        (["Status says \(tile.title) needs attention:"] + tile.problems.map { "- \($0.text)" }).joined(separator: "\n")
    }

    static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// The drawer's Status bar: its note, and the mark beside it (nil when all is well).
struct AtlasStatusDrawerNote: Equatable, Sendable {
    var text: String
    var level: AtlasStatusLevel?
}

// MARK: - Client

protocol AtlasStatusClient: Sendable {
    func status() async throws -> AtlasStatus
}

struct APIClientAtlasStatusAdapter: AtlasStatusClient {
    let apiClient: APIClient

    func status() async throws -> AtlasStatus {
        let data = try await apiClient.sendData(endpoint: .atlasStatus, method: "GET")
        do { return try AtlasStatus.decode(data) } catch { throw APIError.decoding(underlying: error) }
    }
}

// MARK: - View models

enum AtlasStatusScreenState: Equatable {
    case loading
    /// The server has no Status (a stock webui answers 404).
    case unavailable
    case failed(String)
    case loaded(AtlasStatus)
}

@MainActor
@Observable
final class AtlasStatusViewModel {
    private(set) var state: AtlasStatusScreenState = .loading
    /// True when the last refresh failed while an older answer stays on screen.
    private(set) var refreshFailed = false

    private let client: any AtlasStatusClient
    private let onAPIError: (Error) -> Void
    private var generation = 0

    init(client: any AtlasStatusClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.onAPIError = onAPIError
    }

    /// Loads the status. A failed refresh keeps what's on screen; a 404 means this server has none.
    func load() async {
        generation += 1
        let token = generation
        do {
            let status = try await client.status()
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(status)
            refreshFailed = false
        } catch {
            guard token == generation, !Task.isCancelled, !(error is CancellationError) else { return }
            onAPIError(error)
            let notFound = (error as? APIError)?.isNotFound ?? false
            if notFound { state = .unavailable; return }
            if case .loaded = state { refreshFailed = true; return }
            state = .failed(error.localizedDescription)
        }
    }
}

/// The drawer's Status bar for one server. Refreshed when the drawer opens; the drawer never
/// waits on it. Hidden until the first answer, and on a server without Status.
@MainActor
@Observable
final class AtlasStatusDrawerModel {
    private(set) var note: AtlasStatusDrawerNote?

    @ObservationIgnored private let client: any AtlasStatusClient
    @ObservationIgnored private let minimumInterval: TimeInterval
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(client: any AtlasStatusClient, minimumInterval: TimeInterval = 60) {
        self.client = client
        self.minimumInterval = minimumInterval
    }

    func refreshIfStale(now: Date = Date()) {
        guard refreshTask == nil else { return }
        if let lastRefresh, now.timeIntervalSince(lastRefresh) < minimumInterval { return }
        refreshTask = Task { [weak self] in
            await self?.refresh(now: now)
            self?.refreshTask = nil
        }
    }

    /// A failed read keeps the note shown; a 404 hides the bar.
    func refresh(now: Date = Date()) async {
        do {
            let status = try await client.status()
            guard !Task.isCancelled else { return }
            note = AtlasStatusCopy.drawerNote(status)
        } catch {
            if (error as? APIError)?.isNotFound ?? false { note = nil }
        }
        lastRefresh = now
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
