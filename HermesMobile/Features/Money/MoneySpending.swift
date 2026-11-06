import Foundation

/// `finance/data/money/spending.json`, written in the vault by `finance/sync/money_spending.py`
/// in the same run as the snapshot: this month by category against the usual, payday, what's
/// due, what looks off, money in and out, interest, each month back to twelve and the year so far
/// (`MoneySpendingHistory.swift`). Every field is optional on the wire.
struct MoneySpending: Decodable, Equatable {
    var asOf: Date?
    var historyStart: String?
    var month: Month?
    var payday: Payday?
    var due: [Due] = []
    var flags: [Flag] = []
    var cashFlow: [CashFlowMonth] = []
    var weeks: [Week] = []
    var interest: Interest?
    var accounts: [Account] = []
    var transactions: [Transaction] = [] {
        didSet { byID = Self.index(transactions) }
    }
    /// Each month the log covers, newest first. Empty in a file from before months were written.
    var months: [MonthDetail] = []
    var year: Year?
    private var byID: [String: Transaction] = [:]

    enum CodingKeys: String, CodingKey {
        case asOf, historyStart, month, payday, due, flags, cashFlow, weeks, interest, accounts, transactions, months, year
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asOf = (try? c.decodeIfPresent(String.self, forKey: .asOf)).flatMap { $0 }.flatMap(MoneyDates.timestamp)
        historyStart = try? c.decodeIfPresent(String.self, forKey: .historyStart)
        month = try? c.decodeIfPresent(Month.self, forKey: .month)
        payday = try? c.decodeIfPresent(Payday.self, forKey: .payday)
        due = c.lossyArray(Due.self, .due)
        flags = c.lossyArray(Flag.self, .flags)
        cashFlow = c.lossyArray(CashFlowMonth.self, .cashFlow)
        weeks = c.lossyArray(Week.self, .weeks)
        interest = try? c.decodeIfPresent(Interest.self, forKey: .interest)
        accounts = c.lossyArray(Account.self, .accounts)
        transactions = c.lossyArray(Transaction.self, .transactions)
        byID = Self.index(transactions)
        months = c.lossyArray(MonthDetail.self, .months)
        year = try? c.decodeIfPresent(Year.self, forKey: .year)
    }

    private static func index(_ rows: [Transaction]) -> [String: Transaction] {
        Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func decode(_ data: Data) throws -> MoneySpending {
        try MoneyDates.decoder.decode(MoneySpending.self, from: data)
    }

    func account(_ id: String?) -> Account? { accounts.first { $0.id == id } }

    /// The transactions behind a number, newest first, in the order the ids are listed.
    func transactions(_ ids: [String]) -> [Transaction] {
        ids.compactMap { byID[$0] }
    }

    /// The months to step through: `months`, or this month alone from an older file.
    var monthDetails: [MonthDetail] {
        if !months.isEmpty { return months }
        return month.map { [MonthDetail(current: $0)] } ?? []
    }

    struct Month: Decodable, Equatable {
        var start = ""
        var end = ""
        var spent = 0.0
        var income = 0.0
        var usual: Usual?
        var categories: [Category] = []

        enum CodingKeys: String, CodingKey { case start, end, spent, income, usual, categories }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = (try? c.decodeIfPresent(String.self, forKey: .start)) ?? ""
            end = (try? c.decodeIfPresent(String.self, forKey: .end)) ?? ""
            spent = (try? c.decodeIfPresent(Double.self, forKey: .spent)) ?? 0
            income = (try? c.decodeIfPresent(Double.self, forKey: .income)) ?? 0
            usual = try? c.decodeIfPresent(Usual.self, forKey: .usual)
            categories = c.lossyArray(Category.self, .categories)
        }
    }

    struct Usual: Decodable, Equatable {
        var spent: Double
        var months: Int
        /// The whole earlier months a finished month is compared with ("2026-07" to "2026-09").
        var from: String?
        var to: String?
    }

    struct Category: Decodable, Equatable, Identifiable {
        let key: String
        var name: String
        var amount: Double
        /// Nil until the log covers a full earlier month.
        var usual: Double?
        var count: Int
        var txns: [String]
        var id: String { key }

        enum CodingKeys: String, CodingKey { case key, name, amount, usual, count, txns }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? key.capitalized
            amount = (try? c.decodeIfPresent(Double.self, forKey: .amount)) ?? 0
            usual = try? c.decodeIfPresent(Double.self, forKey: .usual)
            count = (try? c.decodeIfPresent(Int.self, forKey: .count)) ?? 0
            txns = (try? c.decodeIfPresent([String].self, forKey: .txns)) ?? []
        }
    }

    struct Payday: Decodable, Equatable {
        var account: String?
        var last: String?
        var next: String
        var every: Int?
        var balance: Double?
        var due: [Due] = []
        var left: Double?

        enum CodingKeys: String, CodingKey { case account, last, next, every, balance, due, left }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            account = try? c.decodeIfPresent(String.self, forKey: .account)
            last = try? c.decodeIfPresent(String.self, forKey: .last)
            next = try c.decode(String.self, forKey: .next)
            every = try? c.decodeIfPresent(Int.self, forKey: .every)
            balance = try? c.decodeIfPresent(Double.self, forKey: .balance)
            due = c.lossyArray(Due.self, .due)
            left = try? c.decodeIfPresent(Double.self, forKey: .left)
        }
    }

    /// One expected bill. `estimate` marks an amount that moves, like a card autopay.
    struct Due: Decodable, Equatable, Identifiable {
        let day: String
        let name: String
        var amount: Double
        var account: String?
        var estimate = false
        var id: String { day + "|" + name + "|" + (account ?? "") }

        enum CodingKeys: String, CodingKey { case day, name, amount, account, estimate }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            day = try c.decode(String.self, forKey: .day)
            name = try c.decode(String.self, forKey: .name)
            amount = (try? c.decodeIfPresent(Double.self, forKey: .amount)) ?? 0
            account = try? c.decodeIfPresent(String.self, forKey: .account)
            estimate = (try? c.decodeIfPresent(Bool.self, forKey: .estimate)) ?? false
        }
    }

    /// Something worth a look. `question` is what Ask Atlas starts with.
    struct Flag: Decodable, Equatable, Identifiable {
        enum Kind: String { case twice, fee, creep, unusual, other }
        let kind: Kind
        let title: String
        var detail: String
        var amount: Double
        var day: String
        var question: String
        var txns: [String]
        var id: String { kind.rawValue + "|" + title + "|" + day }

        enum CodingKeys: String, CodingKey { case kind, title, detail, amount, day, question, txns }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0 }.flatMap(Kind.init) ?? .other
            title = try c.decode(String.self, forKey: .title)
            detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? ""
            amount = (try? c.decodeIfPresent(Double.self, forKey: .amount)) ?? 0
            day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? ""
            question = (try? c.decodeIfPresent(String.self, forKey: .question)) ?? title
            txns = (try? c.decodeIfPresent([String].self, forKey: .txns)) ?? []
        }

        var symbol: String {
            switch kind {
            case .twice: "square.on.square"
            case .fee: "exclamationmark.circle"
            case .creep: "arrow.up.right"
            case .unusual: "sparkle.magnifyingglass"
            case .other: "questionmark.circle"
            }
        }
    }

    struct CashFlowMonth: Decodable, Equatable, Identifiable {
        let month: String
        var `in`: Double
        var out: Double
        var partial: Bool
        var id: String { month }
        var kept: Double { self.in - out }
    }

    struct Week: Decodable, Equatable, Identifiable {
        let start: String
        var spent: Double
        var id: String { start }
    }

    struct Interest: Decodable, Equatable {
        var since: String?
        var total: Double
        var accounts: [InterestAccount]

        enum CodingKeys: String, CodingKey { case since, total, accounts }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            since = try? c.decodeIfPresent(String.self, forKey: .since)
            total = (try? c.decodeIfPresent(Double.self, forKey: .total)) ?? 0
            accounts = c.lossyArray(InterestAccount.self, .accounts)
        }
    }

    struct InterestAccount: Decodable, Equatable, Identifiable {
        let account: String
        var amount: Double
        var id: String { account }
    }

    struct Account: Decodable, Equatable, Identifiable {
        let id: String
        var name: String
        var kind: String?
        var last4: String?
        var balance: Double?
        var limit: Double?

        enum CodingKeys: String, CodingKey { case id, name, kind, last4, balance, limit }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
            last4 = try? c.decodeIfPresent(String.self, forKey: .last4)
            balance = try? c.decodeIfPresent(Double.self, forKey: .balance)
            limit = try? c.decodeIfPresent(Double.self, forKey: .limit)
        }

        /// "Sapphire Card ··1934": the name without its trailing digits, then the last four.
        var label: String {
            guard let last4 else { return name }
            let base = name.replacingOccurrences(of: #"\s*\d{4}\D*$"#, with: "", options: .regularExpression)
            return "\(base.isEmpty ? name : base) ··\(last4)"
        }
    }

    struct Transaction: Decodable, Equatable, Identifiable {
        let id: String
        let day: String
        var name: String
        var amount: Double
        var account: String?
        /// The spending group ("food"), which picks the row's color.
        var group: String?

        enum CodingKeys: String, CodingKey { case id, day, name, amount, account, group }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            day = try c.decode(String.self, forKey: .day)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
            amount = (try? c.decodeIfPresent(Double.self, forKey: .amount)) ?? 0
            account = try? c.decodeIfPresent(String.self, forKey: .account)
            group = try? c.decodeIfPresent(String.self, forKey: .group)
        }
    }
}

/// The questions Personal Finance answers, as Ask Atlas starts them.
enum MoneyQuestions {
    static let wentWhere = "Where did my money go this month?"
    static let moreThanUsual = "Is that more than usual?"
    static let missing = "Anything else I'm missing?"
    static let beforePayday = "So what's left before payday?"
    static let earnVsSpend = "Am I spending more than I make?"
    static let apr = "What's an APR, and what has mine cost me this year?"
    static let afford = "Can I afford a trip this spring?"
    static let save = "How much could I save each month?"

    static let all = [wentWhere, moreThanUsual, missing, beforePayday, earnVsSpend, apr, afford, save]
}

extension MoneyFormat {
    /// "$42.80": spending reads to the cent, unlike net worth.
    static func cents(_ value: Double, hidden: Bool) -> String {
        let sign = value < 0 ? "−" : ""
        return sign + (hidden ? mask : "$" + centsFormatter.string(from: NSNumber(value: abs(value)))!)
    }

    /// Against the usual: "$311 more than usual", "$59 less than usual", "about usual".
    static func versusUsual(_ value: Double, usual: Double, hidden: Bool) -> String {
        let gap = value - usual
        guard abs(gap) >= max(5, usual * 0.05) else { return "About usual" }
        return (hidden ? mask : amount(abs(gap), hidden: false)) + (gap > 0 ? " more than usual" : " less than usual")
    }

    private static let centsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()
}

extension MoneyPoint {
    /// "Oct 20" from "2026-10-20".
    static func label(day: String) -> String {
        dayFormatter.date(from: day).map { label($0) } ?? day
    }
}

extension KeyedDecodingContainer {
    /// An array where one bad element is skipped instead of failing the whole array.
    func lossyArray<Value: Decodable>(_ type: Value.Type, _ key: Key) -> [Value] {
        ((try? decodeIfPresent([MoneyLossyElement<Value>].self, forKey: key)) ?? []).compactMap(\.value)
    }
}

struct MoneyLossyElement<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Spending's words and small derivations, apart from the view so tests can read them.
enum MoneySpendingCopy {
    struct DotDay: Equatable {
        let day: String
        /// `DeckDot` state: a bill comes out ("done"), nothing ("ahead"), payday ("ask", the plus).
        let state: String
    }

    private static let utc = TimeZone(identifier: "UTC")!

    /// "Spent in October", from the month's first day.
    static func monthTitle(_ month: MoneySpending.Month?) -> String {
        guard let month, let start = MoneyPoint.dayFormatter.date(from: month.start) else { return "Spent this month" }
        return "Spent in " + start.formatted(Date.FormatStyle(timeZone: utc).month(.wide))
    }

    /// "October", from "2026-10".
    static func monthName(_ month: String) -> String {
        MoneyPoint.dayFormatter.date(from: month + "-01")
            .map { $0.formatted(Date.FormatStyle(timeZone: utc).month(.wide)) } ?? month
    }

    /// "Fri, Oct 30".
    static func weekdayLabel(_ day: String) -> String {
        MoneyPoint.dayFormatter.date(from: day)
            .map { $0.formatted(Date.FormatStyle(timeZone: utc).weekday(.abbreviated).month(.abbreviated).day()) } ?? day
    }

    /// "since Jun 20" when the log starts this year, else "since Jan 1".
    static func sinceLabel(_ day: String) -> String { "since " + MoneyPoint.label(day: day) }

    /// The headline's second line: against the same days of earlier months, or why there's no usual yet.
    static func usualLine(_ spending: MoneySpending, hidden: Bool) -> String {
        guard let month = spending.month else { return "" }
        guard let usual = month.usual else {
            return "No usual yet: the log starts \(MoneyPoint.label(day: spending.historyStart ?? month.start))"
        }
        let by = "by " + MoneyPoint.label(day: month.end)
        return MoneyFormat.versusUsual(month.spent, usual: usual.spent, hidden: hidden) + " " + by
    }

    /// Each day from tomorrow through payday (two weeks at most): a dot per day, filled when a bill comes out.
    static func daysUntil(_ payday: MoneySpending.Payday, today: String?) -> [DotDay] {
        guard let today, let start = MoneyPoint.dayFormatter.date(from: today),
              let end = MoneyPoint.dayFormatter.date(from: payday.next) else { return [] }
        let billDays = Set(payday.due.map(\.day))
        var out: [DotDay] = []
        var day = start
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        while out.count < 14, let next = calendar.date(byAdding: .day, value: 1, to: day), next <= end {
            day = next
            let key = MoneyPoint.dayFormatter.string(from: day)
            out.append(DotDay(day: key, state: key == payday.next ? "ask" : billDays.contains(key) ? "done" : "ahead"))
        }
        return out
    }

    static func dotsLabel(_ days: [DotDay]) -> String {
        let bills = days.filter { $0.state == "done" }.count
        return "\(days.count) days to payday, \(bills == 1 ? "1 day" : "\(bills) days") with a bill"
    }

    /// "Left after 4 bills" over the pay account's balance.
    static func leftLabel(_ payday: MoneySpending.Payday, _ spending: MoneySpending) -> String {
        let count = payday.due.count
        let account = spending.account(payday.account)?.label
        let bills = count == 0 ? "Left until payday" : "Left after \(count == 1 ? "1 bill" : "\(count) bills")"
        return account.map { "\(bills) in \($0)" } ?? bills
    }

    static func weeksValue(_ weeks: [MoneySpending.Week], hidden: Bool) -> String {
        guard let last = weeks.last, let high = weeks.max(by: { $0.spent < $1.spent }) else { return "" }
        return "This week \(MoneyFormat.amount(last.spent, hidden: hidden)). Highest \(MoneyFormat.amount(high.spent, hidden: hidden)), week of \(MoneyPoint.label(day: high.start))."
    }

    /// A flag's detail with its dollar amounts masked, the rest kept.
    static func masked(_ text: String) -> String {
        text.replacingOccurrences(of: #"\$[\d,]+(\.\d+)?"#, with: MoneyFormat.mask, options: .regularExpression)
    }

    static func footer(_ spending: MoneySpending) -> String {
        let since = spending.historyStart.map { " History goes back to \(MoneyPoint.label(day: $0)) and grows each day." } ?? ""
        return "Read-only, from the accounts SimpleFIN syncs each morning; pending charges aren't in yet.\(since) Atlas can get things wrong: ask which transactions are behind a number, and check important figures with your bank."
    }
}
