import Foundation

/// `finance/data/money/snapshot.json`, written in the vault by `finance/sync/money_snapshot.py`.
/// Every field is optional on the wire so an older or newer script never breaks the screen.
struct MoneySnapshot: Decodable, Equatable {
    var asOf: Date?
    var slot: String?
    var netWorth: Double = 0
    var series: [MoneyPoint] = []
    var accounts: [MoneyAccount] = []
    var week: MoneyWeek?
    var stale: [MoneyStale] = []
    /// Accounts the last pull left out because their bank connection is failing; net worth
    /// still counts them at their last balance.
    var missing = 0
    var holdingsMissing = false

    enum CodingKeys: String, CodingKey { case asOf, slot, netWorth, series, accounts, week, stale, missing, holdingsMissing }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asOf = (try? c.decodeIfPresent(String.self, forKey: .asOf)).flatMap { $0 }.flatMap(MoneyDates.timestamp)
        slot = try? c.decodeIfPresent(String.self, forKey: .slot)
        netWorth = (try? c.decodeIfPresent(Double.self, forKey: .netWorth)) ?? 0
        series = c.lossy(MoneyPoint.self, .series)
        accounts = c.lossy(MoneyAccount.self, .accounts)
        week = try? c.decodeIfPresent(MoneyWeek.self, forKey: .week)
        stale = c.lossy(MoneyStale.self, .stale)
        missing = (try? c.decodeIfPresent(Int.self, forKey: .missing)) ?? 0
        holdingsMissing = (try? c.decodeIfPresent(Bool.self, forKey: .holdingsMissing)) ?? false
    }

    static func decode(_ data: Data) throws -> MoneySnapshot {
        try MoneyDates.decoder.decode(MoneySnapshot.self, from: data)
    }

    /// The day the series ends: the script's today, which ranges count back from.
    var lastDay: Date? { series.last?.date }

    /// The stale entry for an account: by id, else by name for snapshots written before ids.
    func staleEntry(for account: MoneyAccount) -> MoneyStale? {
        stale.first { $0.id.map { $0 == account.id } ?? ($0.name == account.name) }
    }
}

/// Decodes an element or yields nil, so one bad element never fails its array.
private struct MoneyLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    func lossy<Value: Decodable>(_ type: Value.Type, _ key: Key) -> [Value] {
        ((try? decodeIfPresent([MoneyLossy<Value>].self, forKey: key)) ?? []).compactMap(\.value)
    }
}

/// One day of net worth. `e` marks a day estimated from index history, before the first snapshot.
struct MoneyPoint: Decodable, Equatable, Identifiable {
    let d: String
    let v: Double
    var e = false
    let date: Date

    var id: String { d }

    init(d: String, v: Double, e: Bool = false) {
        self.d = d
        self.v = v
        self.e = e
        date = Self.dayFormatter.date(from: d) ?? .distantPast
    }

    enum CodingKeys: String, CodingKey { case d, v, e }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            d: try c.decode(String.self, forKey: .d),
            v: try c.decode(Double.self, forKey: .v),
            e: (try? c.decodeIfPresent(Bool.self, forKey: .e)) ?? false
        )
    }

    /// "Oct 5" or "Oct 5, 2026" for a day, read in UTC like the series.
    static func label(_ date: Date, withYear: Bool = false) -> String {
        let style = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).day()
        return date.formatted(withYear ? style.year() : style)
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

struct MoneyAccount: Decodable, Equatable, Identifiable {
    let id: String
    var name = ""
    var institution: String?
    var kind = "cash"
    var balance: Double = 0
    var change1w: Double = 0
    var tracks: String?
    var spark: [Double] = []

    // `convertFromSnakeCase` turns `change_1w` into `change1W`.
    enum CodingKeys: String, CodingKey { case id, name, institution, kind, balance, change1w = "change1W", tracks, spark }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        institution = try? c.decodeIfPresent(String.self, forKey: .institution)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "cash"
        balance = (try? c.decodeIfPresent(Double.self, forKey: .balance)) ?? 0
        change1w = (try? c.decodeIfPresent(Double.self, forKey: .change1w)) ?? 0
        tracks = try? c.decodeIfPresent(String.self, forKey: .tracks)
        spark = (try? c.decodeIfPresent([Double].self, forKey: .spark)) ?? []
    }

    /// The week's change as a percent of last week's balance; 0 when there was nothing.
    var percentChange1w: Double {
        let before = balance - change1w
        return before == 0 ? 0 : change1w / abs(before) * 100
    }

    /// A card or loan: shown as what's owed, its change as the debt's direction.
    var isDebt: Bool { kind == "credit" || kind == "loan" }

    /// "Investment · S&P 500", "Credit".
    var subtitle: String {
        [kind.prefix(1).uppercased() + kind.dropFirst(), tracks].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The last seven days, split into what the market did and everything else.
struct MoneyWeek: Decodable, Equatable {
    var start = ""
    var end = ""
    var change: Double = 0
    var market: Double = 0
    var cashFlow: Double = 0
    var indexes: [MoneyIndex] = []

    enum CodingKeys: String, CodingKey { case start, end, change, market, cashFlow, indexes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = (try? c.decodeIfPresent(String.self, forKey: .start)) ?? ""
        end = (try? c.decodeIfPresent(String.self, forKey: .end)) ?? ""
        change = (try? c.decodeIfPresent(Double.self, forKey: .change)) ?? 0
        market = (try? c.decodeIfPresent(Double.self, forKey: .market)) ?? 0
        cashFlow = (try? c.decodeIfPresent(Double.self, forKey: .cashFlow)) ?? 0
        indexes = (try? c.decodeIfPresent([MoneyIndex].self, forKey: .indexes)) ?? []
    }
}

struct MoneyIndex: Decodable, Equatable, Identifiable {
    let key: String
    var name = ""
    var symbol = ""
    var returnPct: Double = 0
    var exposure: Double = 0

    var id: String { key }

    enum CodingKeys: String, CodingKey { case key, name, symbol, returnPct, exposure }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? key
        symbol = (try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? ""
        returnPct = (try? c.decodeIfPresent(Double.self, forKey: .returnPct)) ?? 0
        exposure = (try? c.decodeIfPresent(Double.self, forKey: .exposure)) ?? 0
    }
}

struct MoneyStale: Decodable, Equatable {
    var id: String?
    var name = ""
    var ageDays: Double = 0

    enum CodingKeys: String, CodingKey { case id, name, ageDays }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        ageDays = (try? c.decodeIfPresent(Double.self, forKey: .ageDays)) ?? 0
    }
}

/// `finance/data/money/market.json`, written by Atlas from public index moves and news.
struct MoneyMarketNote: Decodable, Equatable {
    var window: MoneyWindow?
    var story: String?
    var drivers: [MoneyDriver] = []
    var writtenAt: Date?

    enum CodingKeys: String, CodingKey { case window, story, drivers, writtenAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        window = try? c.decodeIfPresent(MoneyWindow.self, forKey: .window)
        story = try? c.decodeIfPresent(String.self, forKey: .story)
        drivers = (try? c.decodeIfPresent([MoneyDriver].self, forKey: .drivers)) ?? []
        writtenAt = (try? c.decodeIfPresent(String.self, forKey: .writtenAt)).flatMap { $0 }.flatMap(MoneyDates.timestamp)
    }

    static func decode(_ data: Data) throws -> MoneyMarketNote {
        try MoneyDates.decoder.decode(MoneyMarketNote.self, from: data)
    }

    /// A note describes the snapshot's week only when their windows are the same days.
    func matches(_ week: MoneyWeek?) -> Bool {
        guard let week, let window else { return false }
        return window.start == week.start && window.end == week.end
    }
}

struct MoneyWindow: Decodable, Equatable {
    let start: String
    let end: String
}

struct MoneyDriver: Decodable, Equatable, Identifiable {
    var text = ""
    var source: String?
    var url: URL?

    var id: String { text }

    enum CodingKeys: String, CodingKey { case text, source, url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        url = (try? c.decodeIfPresent(String.self, forKey: .url)).flatMap { $0 }.flatMap(URL.init(string:))
    }
}

enum MoneyRange: String, CaseIterable, Identifiable {
    case week = "1W", month = "1M", quarter = "3M", year = "1Y", all = "All"

    var id: String { rawValue }

    /// What VoiceOver reads for the range's segment.
    var spokenName: String {
        switch self {
        case .week: "1 week"
        case .month: "1 month"
        case .quarter: "3 months"
        case .year: "1 year"
        case .all: "All time"
        }
    }

    var label: String {
        switch self {
        case .week: "this week"
        case .month: "past month"
        case .quarter: "past 3 months"
        case .year: "past year"
        case .all: "all time"
        }
    }

    /// The points on or after this range's first day, counted back from `today` (UTC days).
    func points(in series: [MoneyPoint], today: Date) -> [MoneyPoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start: Date? = switch self {
        case .week: calendar.date(byAdding: .day, value: -7, to: today)
        case .month: calendar.date(byAdding: .month, value: -1, to: today)
        case .quarter: calendar.date(byAdding: .month, value: -3, to: today)
        case .year: calendar.date(byAdding: .year, value: -1, to: today)
        case .all: nil
        }
        guard let start else { return series }
        let first = MoneyPoint.dayFormatter.string(from: start)
        return series.filter { $0.d >= first }
    }
}

struct MoneyChange: Equatable {
    let amount: Double
    let percent: Double

    static func between(_ points: [MoneyPoint]) -> MoneyChange {
        guard let first = points.first, let last = points.last, points.count > 1 else { return MoneyChange(amount: 0, percent: 0) }
        let amount = last.v - first.v
        return MoneyChange(amount: amount, percent: first.v == 0 ? 0 : amount / abs(first.v) * 100)
    }
}

/// Money's numbers as text. A hidden amount is always `$••••••`, so its width never hints at
/// its size; the sign stays because gain or loss is already shown in color.
enum MoneyFormat {
    static let mask = "$••••••"

    static func amount(_ value: Double, hidden: Bool) -> String {
        let sign = value < 0 ? "−" : ""
        return sign + (hidden ? mask : dollars(abs(value)))
    }

    static func signed(_ value: Double, hidden: Bool) -> String {
        (value < 0 ? "−" : "+") + (hidden ? mask : dollars(abs(value)))
    }

    static func percent(_ value: Double) -> String {
        (value < 0 ? "−" : "+") + String(format: "%.2f%%", abs(value))
    }

    /// "$184,320", or "$2,180 owed" for a card or loan.
    static func balance(_ account: MoneyAccount, hidden: Bool) -> String {
        account.isDebt ? amount(abs(account.balance), hidden: hidden) + " owed" : amount(account.balance, hidden: hidden)
    }

    /// An account's week, for its pill: "+$560" or "−$60"; for a card or loan the debt's
    /// direction, "↓ $20" (owe less) or "↑ $480" (owe more). Hidden amounts show percents.
    static func weekChange(_ account: MoneyAccount, hidden: Bool) -> String {
        let change = account.change1w
        guard change != 0 else { return "—" }
        guard account.isDebt else { return hidden ? percent(account.percentChange1w) : signed(change, hidden: false) }
        let size = hidden ? String(format: "%.2f%%", abs(account.percentChange1w)) : amount(abs(change), hidden: false)
        return (change > 0 ? "↓ " : "↑ ") + size
    }

    /// What VoiceOver reads for the pill: the arrows spelled out for a card or loan.
    static func weekChangeLabel(_ account: MoneyAccount, hidden: Bool) -> String {
        let change = account.change1w
        guard account.isDebt, change != 0 else { return change == 0 ? "No change this week" : weekChange(account, hidden: hidden) + " this week" }
        let size = hidden ? "" : " " + amount(abs(change), hidden: false)
        return "Owe\(size) \(change > 0 ? "less" : "more") this week"
    }

    /// "Last synced today", "yesterday", or "9 days ago", for an account whose balance is old.
    static func lastSynced(ageDays: Double) -> String {
        let days = Int(ageDays.rounded(.down))
        switch days {
        case ..<1: return "Last synced today"
        case 1: return "Last synced yesterday"
        default: return "Last synced \(days) days ago"
        }
    }

    /// "+$1.8k" for thousands, "+$340" below.
    static func compact(_ value: Double, hidden: Bool) -> String {
        let sign = value < 0 ? "−" : "+"
        if hidden { return sign + mask }
        let magnitude = abs(value)
        if magnitude >= 1000 {
            let thousands = (magnitude / 100).rounded() / 10
            let text = thousands == thousands.rounded() ? String(Int(thousands)) : String(format: "%.1f", thousands)
            return "\(sign)$\(text)k"
        }
        return sign + dollars(magnitude)
    }

    private static func dollars(_ value: Double) -> String {
        "$" + formatter.string(from: NSNumber(value: value.rounded()))!
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = 0
        return f
    }()
}

enum MoneyDates {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static func timestamp(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let date = f.date(from: s) { return date }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
