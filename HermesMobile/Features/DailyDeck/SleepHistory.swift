import Foundation

/// Where the vault's `tools/sleep_metrics.py` writes every night's Garmin numbers.
enum SleepHistoryPaths {
    static let history = "data/sleep/history.json"
}

/// The sleep screen's data: `data/sleep/history.json`. Nights are rows under one list of column
/// names (the server reads files of at most 400 KB), oldest first. Every field is optional:
/// older nights lack HRV, and a column the app doesn't know is ignored.
struct SleepHistory: Equatable {
    let nights: [SleepNight]
    /// Hypnograms for the last 30 nights that have one, by date.
    let stages: [String: [SleepStage]]

    var lastNight: SleepNight? { nights.last }

    func night(on date: String) -> SleepNight? {
        nights.last { $0.date == date }
    }

    static func decode(_ data: Data) throws -> SleepHistory {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let columns = raw.columns ?? []
        let nights = (raw.nights ?? []).compactMap { row -> SleepNight? in
            var fields: [String: SleepValue] = [:]
            for (column, value) in zip(columns, row) { fields[column] = value }
            return SleepNight(fields)
        }
        let stages = (raw.stages ?? [:]).mapValues { $0.compactMap(SleepStage.init) }.filter { !$0.value.isEmpty }
        return SleepHistory(nights: nights, stages: stages)
    }

    private struct Raw: Decodable {
        let columns: [String]?
        let nights: [[SleepValue]]?
        let stages: [String: [[SleepValue]]]?
    }
}

/// One cell of history.json: a number, a string, a list of either, or null.
enum SleepValue: Decodable, Equatable {
    case number(Double)
    case text(String)
    case list([SleepValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let number = try? c.decode(Double.self) { self = .number(number) }
        else if let text = try? c.decode(String.self) { self = .text(text) }
        else if let list = try? c.decode([SleepValue].self) { self = .list(list) }
        else { self = .null }
    }

    var number: Double? { if case .number(let n) = self { n } else { nil } }
    var text: String? { if case .text(let t) = self { t } else { nil } }
    var list: [SleepValue] { if case .list(let l) = self { l } else { [] } }
}

/// One night: Garmin's numbers and his own rating and note.
/// `date` is the morning the night ended ("2026-10-18"); `bed` and `wake` are local
/// "YYYY-MM-DDTHH:MM" wall-clock times.
struct SleepNight: Equatable, Identifiable {
    let date: String
    var hours: Double?
    var need: Double?
    var bed: String?
    var wake: String?
    var inBedMinutes: Double?
    var deepMinutes: Double?
    var lightMinutes: Double?
    var remMinutes: Double?
    var awakeMinutes: Double?
    var wakeUps: Double?
    var restingHR: Double?
    var hrv: Double?
    var hrvBand: ClosedRange<Double>?
    /// Garmin's read of HRV against his baseline: BALANCED, UNBALANCED, LOW or POOR.
    var hrvStatus: String?
    var respiration: Double?
    var spo2: Double?
    var sleepStress: Double?
    /// His 1–5 rating (very poor to very good) and note from the deck's sleep card.
    var quality: Int?
    var felt: String?
    var efficiency: Double?
    var flags: [String] = []

    var id: String { date }

    init(date: String) {
        self.date = date
    }

    init?(_ f: [String: SleepValue]) {
        guard let date = f["date"]?.text, Self.dayFormatter.date(from: date) != nil else { return nil }
        self.date = date
        hours = f["sleep_hours"]?.number
        need = f["sleep_need_hours"]?.number
        bed = f["bed"]?.text
        wake = f["wake"]?.text
        inBedMinutes = f["in_bed_min"]?.number
        deepMinutes = f["deep_min"]?.number
        lightMinutes = f["light_min"]?.number
        remMinutes = f["rem_min"]?.number
        awakeMinutes = f["awake_min"]?.number
        wakeUps = f["awake_count"]?.number
        restingHR = f["resting_hr"]?.number
        hrv = f["hrv"]?.number
        let band = (f["hrv_band"]?.list ?? []).compactMap(\.number)
        hrvBand = band.count == 2 && band[0] <= band[1] ? band[0]...band[1] : nil
        hrvStatus = f["hrv_status"]?.text
        respiration = f["respiration"]?.number
        spo2 = f["spo2"]?.number
        sleepStress = f["sleep_stress"]?.number
        quality = f["quality"]?.number.map { Int($0) }.flatMap { (1...5).contains($0) ? $0 : nil }
        felt = f["felt"]?.text.flatMap { $0.isEmpty ? nil : $0 }
        efficiency = f["efficiency"]?.number
        flags = (f["flags"]?.list ?? []).compactMap(\.text)
    }

    var day: Date? { Self.dayFormatter.date(from: date) }

    /// Minutes after noon for bed and wake, so 11 pm and 1 am sit on one axis.
    var bedClock: Double? { Self.clock(bed) }
    var wakeClock: Double? { Self.clock(wake) }

    static func clock(_ stamp: String?) -> Double? {
        guard let stamp, let date = stampFormatter.date(from: stamp) else { return nil }
        let parts = SleepTrend.utcCalendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return nil }
        return Double(((hour * 60 + minute - 12 * 60) % 1440 + 1440) % 1440)
    }

    static let dayFormatter: DateFormatter = fixed("yyyy-MM-dd")
    static let stampFormatter: DateFormatter = fixed("yyyy-MM-dd'T'HH:mm")

    private static func fixed(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}

/// One stretch of the night's hypnogram: minutes from falling asleep, its length, and the stage.
struct SleepStage: Equatable {
    enum Kind: String, CaseIterable {
        case awake, rem, light, deep

        var title: String {
            switch self {
            case .awake: "Awake"
            case .rem: "REM"
            case .light: "Light"
            case .deep: "Deep"
            }
        }
    }

    let start: Double
    let length: Double
    let kind: Kind

    init(start: Double, length: Double, kind: Kind) {
        self.start = start
        self.length = length
        self.kind = kind
    }

    init?(_ row: [SleepValue]) {
        guard row.count == 3, let start = row[0].number, let length = row[1].number, length > 0,
              let kind = row[2].text.flatMap(Kind.init(rawValue:))
        else { return nil }
        self.init(start: start, length: length, kind: kind)
    }
}

// MARK: Trends

/// A trend chart's span: the last week and month night by night, longer spans as weekly means.
enum SleepRange: String, CaseIterable, Identifiable {
    case week = "1W", month = "1M", sixMonths = "6M", year = "1Y"

    var id: String { rawValue }
    var days: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .sixMonths: 182
        case .year: 365
        }
    }

    var isWeekly: Bool { self == .sixMonths || self == .year }

    var periodName: String {
        switch self {
        case .week: "week"
        case .month: "month"
        case .sixMonths: "6 months"
        case .year: "year"
        }
    }
}

/// What a trend chart plots: the numbers that answer how long, how broken, how late, and how
/// the body coped.
enum SleepMetric: String, CaseIterable, Identifiable {
    case hours, wakeUps, window, hrv, restingHR

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hours: "Hours"
        case .wakeUps: "Wake-ups"
        case .window: "Bed & wake"
        case .hrv: "HRV"
        case .restingHR: "Resting HR"
        }
    }

    var unit: String {
        switch self {
        case .hours: " h"
        case .wakeUps, .window: ""
        case .hrv: " ms"
        case .restingHR: " bpm"
        }
    }

    func value(_ night: SleepNight) -> Double? {
        switch self {
        case .hours: night.hours
        case .wakeUps: night.wakeUps
        case .window: night.bedClock
        case .hrv: night.hrv
        case .restingHR: night.restingHR
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .hours: String(format: "%.1f h", value)
        case .window: SleepTrend.clockLabel(value)
        default: "\(Int(value.rounded()))\(unit)"
        }
    }
}

/// One bar on a trend chart: a night, or a week's mean on longer spans. `low` and `high` are
/// bed and wake (minutes after noon) for the sleep-window chart; `need` is the hours needed.
struct SleepPoint: Identifiable, Equatable {
    let date: Date
    let value: Double
    var low: Double?
    var high: Double?
    var need: Double?
    /// The night this bar is, on night-by-night spans.
    var night: String?

    var id: Date { date }
}

enum SleepTrend {
    /// The span's bars, oldest first, ending on `today`.
    static func points(_ nights: [SleepNight], metric: SleepMetric, range: SleepRange, today: Date) -> [SleepPoint] {
        let window = Self.nights(in: nights, range: range, endingOn: today, back: 0)
        let daily = window.sorted { $0.date < $1.date }.compactMap { night -> SleepPoint? in
            guard let day = night.day else { return nil }
            if metric == .window {
                guard let bed = night.bedClock, let wake = night.wakeClock else { return nil }
                return SleepPoint(date: day, value: bed, low: bed, high: wake, night: night.date)
            }
            guard let value = metric.value(night) else { return nil }
            return SleepPoint(date: day, value: value, need: metric == .hours ? night.need : nil, night: night.date)
        }
        guard range.isWeekly else { return daily }
        let calendar = utcCalendar
        let weeks = Dictionary(grouping: daily) { calendar.dateInterval(of: .weekOfYear, for: $0.date)?.start ?? $0.date }
        return weeks.keys.sorted().map { week in
            let bars = weeks[week] ?? []
            return SleepPoint(date: week, value: mean(bars.map(\.value)) ?? 0,
                              low: mean(bars.compactMap(\.low)), high: mean(bars.compactMap(\.high)),
                              need: mean(bars.compactMap(\.need)))
        }
    }

    /// The span's mean, and the change from the span before it (nil when either has no data).
    static func summary(_ nights: [SleepNight], metric: SleepMetric, range: SleepRange, today: Date) -> (average: Double?, change: Double?) {
        let now = mean(Self.nights(in: nights, range: range, endingOn: today, back: 0).compactMap(metric.value))
        let before = mean(Self.nights(in: nights, range: range, endingOn: today, back: 1).compactMap(metric.value))
        guard let now else { return (nil, nil) }
        return (now, before.map { now - $0 })
    }

    /// The nights in the span ending `back` spans before `today`.
    static func nights(in nights: [SleepNight], range: SleepRange, endingOn today: Date, back: Int) -> [SleepNight] {
        let calendar = utcCalendar
        let end = calendar.startOfDay(for: today).addingTimeInterval(-Double(back * range.days) * 86_400)
        let start = end.addingTimeInterval(-Double(range.days - 1) * 86_400)
        return nights.filter { night in
            guard let day = night.day else { return false }
            return day >= start && day <= end
        }
    }

    /// "11:05 pm" for minutes after noon.
    static func clockLabel(_ minutesAfterNoon: Double) -> String {
        let total = (Int(minutesAfterNoon.rounded()) + 12 * 60) % 1440
        let hour = total / 60, minute = total % 60
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", twelve, minute, hour < 12 ? "am" : "pm")
    }

    /// A day as `style` shows it, read in UTC like the history's dates.
    static func label(_ date: Date, _ style: (Date.FormatStyle) -> Date.FormatStyle) -> String {
        date.formatted(style(Date.FormatStyle(timeZone: utcCalendar.timeZone)))
    }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.firstWeekday = 2
        return calendar
    }()
}

// MARK: Against usual

/// What one night is read against: the means of the 30 nights before it, and for bed and wake
/// the median of the week before (with at least three to go on), the same usual the deck's sleep
/// card states. Bed and wake are minutes after noon, so 11 pm and 1 am sit either side of midnight.
struct SleepUsual: Equatable {
    var hours: Double?
    var bed: Double?
    var wake: Double?
    var wakeUps: Double?
    var awakeMinutes: Double?
    var efficiency: Double?
    var restingHR: Double?
    var respiration: Double?

    init() {}

    init(before date: String, in nights: [SleepNight]) {
        let prior = nights.filter { $0.date < date }.suffix(30)
        func mean(_ value: (SleepNight) -> Double?) -> Double? { SleepTrend.mean(prior.compactMap(value)) }
        hours = mean(\.hours)
        let week = prior.suffix(7)
        func median(_ value: (SleepNight) -> Double?) -> Double? {
            let values = week.compactMap(value).sorted()
            guard values.count >= 3 else { return nil }
            let mid = values.count / 2
            return (values.count.isMultiple(of: 2) ? (values[mid - 1] + values[mid]) / 2 : values[mid]).rounded()
        }
        bed = median(\.bedClock)
        wake = median(\.wakeClock)
        wakeUps = mean(\.wakeUps)
        awakeMinutes = mean(\.awakeMinutes)
        efficiency = mean(\.efficiency)
        restingHR = mean(\.restingHR)
        respiration = mean(\.respiration)
    }
}

/// One line of a night's readout: its value and how it sits against usual. `standsOut` marks a
/// value far enough from usual to matter, which the screen calls out in words and an icon.
struct SleepReading: Equatable {
    let label: String
    let value: String
    var note: String?
    var standsOut = false
}

struct SleepReadingGroup: Equatable {
    let title: String
    let readings: [SleepReading]
}

/// A night as three short lists (when, interruptions, body), each value against usual. How long
/// he slept is the screen's headline, so it isn't repeated here.
enum SleepReadout {
    static func groups(_ night: SleepNight, usual: SleepUsual) -> [SleepReadingGroup] {
        var when: [SleepReading] = []
        if let bed = night.bedClock { when.append(clock("Fell asleep", bed, usual: usual.bed)) }
        if let wake = night.wakeClock { when.append(clock("Woke", wake, usual: usual.wake)) }
        if let inBed = night.inBedMinutes { when.append(SleepReading(label: "In bed", value: duration(inBed / 60))) }

        var interruptions: [SleepReading] = []
        if let wakeUps = night.wakeUps {
            interruptions.append(SleepReading(label: "Wake-ups", value: whole(wakeUps),
                                              note: usual.wakeUps.map { "usually \(whole($0))" },
                                              standsOut: usual.wakeUps.map { wakeUps >= $0 + 2 } ?? false))
        }
        if let awake = night.awakeMinutes {
            interruptions.append(SleepReading(label: "Time awake", value: "\(whole(awake)) min",
                                              note: usual.awakeMinutes.map { "usually \(whole($0)) min" },
                                              standsOut: usual.awakeMinutes.map { awake >= $0 + 20 } ?? false))
        }
        if let efficiency = night.efficiency {
            interruptions.append(SleepReading(label: "Asleep while in bed", value: "\(whole(efficiency))%",
                                              note: usual.efficiency.map { "usually \(whole($0))%" },
                                              standsOut: usual.efficiency.map { efficiency <= $0 - 5 } ?? false))
        }

        var body: [SleepReading] = []
        if let hrv = night.hrv {
            let band = night.hrvBand.map { "normal \(whole($0.lowerBound))–\(whole($0.upperBound))" }
            let low = night.flags.contains("hrv_low") || night.hrvBand.map { hrv < $0.lowerBound } == true
            body.append(SleepReading(label: "HRV", value: "\(whole(hrv)) ms",
                                     note: low ? ["below normal", band].compactMap { $0 }.joined(separator: " · ") : band,
                                     standsOut: low))
        }
        if let restingHR = night.restingHR {
            body.append(SleepReading(label: "Resting heart rate", value: "\(whole(restingHR)) bpm",
                                     note: usual.restingHR.map { "usually \(whole($0))" },
                                     standsOut: usual.restingHR.map { restingHR >= $0 + 3 } ?? false))
        }
        if let breathing = night.respiration {
            let usualText = usual.respiration.map { String(format: "%.1f", $0) }
            let up = night.flags.contains("breathing_up") || usual.respiration.map { breathing >= $0 + 1 } == true
            body.append(SleepReading(label: "Breathing", value: String(format: "%.1f /min", breathing),
                                     note: up ? "up from \(usualText ?? "usual"), an early sign of illness"
                                         : usualText.map { "usually \($0)" },
                                     standsOut: up))
        }

        return [SleepReadingGroup(title: "When", readings: when),
                SleepReadingGroup(title: "Interruptions", readings: interruptions),
                SleepReadingGroup(title: "Body", readings: body)].filter { !$0.readings.isEmpty }
    }

    /// "5 h 24 m", "45 min", "8 h".
    static func duration(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) m"
    }

    /// A bed or wake time against usual: "2 h 13 m later than usual" (within half an hour is the
    /// usual time), standing out from 45 minutes.
    private static func clock(_ label: String, _ minutes: Double, usual: Double?) -> SleepReading {
        var reading = SleepReading(label: label, value: SleepTrend.clockLabel(minutes))
        guard let usual else { return reading }
        let diff = minutes - usual
        reading.note = abs(diff) < 30 ? "usual time" : "\(duration(abs(diff) / 60)) \(diff > 0 ? "later" : "earlier") than usual"
        reading.standsOut = abs(diff) >= 45
        return reading
    }

    private static func whole(_ value: Double) -> String { "\(Int(value.rounded()))" }
}
