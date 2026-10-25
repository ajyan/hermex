import Foundation
import Observation

/// A week's tile in the year of weeks.
enum WeekTileState: Equatable {
    /// Sealed: a record exists, with or without a photo.
    case reviewed(hasPhoto: Bool)
    /// Past and not sealed; `hasDeck` when its weekly deck waits unfiled.
    case unreviewed(hasDeck: Bool)
    case future
    /// The week containing today.
    case current
}

/// A prediction whose due day has come and that no later week has graded.
struct DuePrediction: Identifiable, Equatable {
    let id: String
    let text: String
    let due: String
    let probability: Int?
    /// The week that made it.
    let weekEnding: String
}

/// The look back over sealed weeks: which weeks have a record and a photo, the records themselves,
/// and the predictions still open. Everything reads through `sessionID`, a session in the active
/// server's brief workspace, and nothing is kept across servers.
@MainActor @Observable final class WeeksModel {
    nonisolated static let directory = "weekly-checkins"
    nonisolated static let recordReadsAtOnce = 6
    nonisolated static let photosDirectory = "weekly-checkins/photos"
    nonisolated static func recordPath(_ weekEnding: String) -> String { "\(directory)/\(weekEnding)-week-ending.json" }
    nonisolated static func photoPath(_ weekEnding: String) -> String { "\(photosDirectory)/\(weekEnding).jpg" }

    let server: URL
    let sessionID: String
    private let client: any DailyDeckDataClient
    /// The clock; tests pin it.
    let now: () -> Date

    /// Sundays with a week record.
    private(set) var recordDates: Set<String> = []
    /// Sundays with a photo of the week.
    private(set) var photoDates: Set<String> = []
    /// Sundays whose weekly deck is in `briefs/` and neither sealed (no record) nor filed by the v1 filer.
    private(set) var unfiledDecks: Set<String> = []
    /// Every listing has succeeded at least once since this model was made.
    private(set) var isLoaded = false
    /// Whether `photoDates` comes from a successful listing; until then a week's photo is unknown.
    private(set) var photosListed = false
    /// Set when the last `load()` couldn't read a folder; the sets keep what the last good read found.
    private(set) var loadError: String?
    /// Open predictions past their due day, soonest due first; filled by `loadDuePredictions()`.
    private(set) var duePredictions: [DuePrediction] = []
    /// Bumped on each photo change of a week, so its image reloads.
    private var photoVersions: [String: Int] = [:]
    @ObservationIgnored private var records: [String: WeekRecord] = [:]
    @ObservationIgnored private var allRecordsLoad: Task<Void, Never>?

    init(server: URL, client: any DailyDeckDataClient, sessionID: String, now: @escaping () -> Date = Date.init) {
        self.server = server
        self.client = client
        self.sessionID = sessionID
        self.now = now
    }

    /// Today, `yyyy-MM-dd`, in the device's time zone.
    var today: String { DailyDeckPaths.day(now(), calendar: Self.calendar) }

    /// The ISO week-based year of today.
    var currentYear: Int { Self.calendar.component(.yearForWeekOfYear, from: now()) }

    /// The ISO years with a sealed week, and this one, oldest first.
    var years: [Int] {
        let calendar = Self.calendar
        var years = Set(recordDates.compactMap { DailyDeckPaths.date(day: $0, calendar: calendar) }
            .map { calendar.component(.yearForWeekOfYear, from: $0) })
        years.insert(currentYear)
        return years.sorted()
    }

    func photoVersion(for weekEnding: String) -> Int { photoVersions[weekEnding] ?? 0 }

    /// Lists the records, the photos, and the briefs. A missing folder reads as empty; any other
    /// failure keeps that folder's last listing and sets `loadError`.
    func load() async {
        async let recordNames = names(in: Self.directory)
        async let photoNames = names(in: Self.photosDirectory)
        async let briefNames = names(in: DailyDeckPaths.directory)
        let (records, photos, briefs) = await (recordNames, photoNames, briefNames)
        if let records {
            recordDates = Set(records.compactMap { Self.sunday(in: $0, suffix: "-week-ending.json") })
        }
        if let photos {
            photoDates = Set(photos.compactMap { Self.sunday(in: $0, suffix: ".jpg") })
            photosListed = true
        }
        if let briefs {
            // A seal leaves a record and a v1 filing a `.weekly.filed.json`; saved answers alone are a
            // seal whose filer failed, so that deck still waits.
            let filedV1 = briefs.filter { $0.hasSuffix(".weekly.filed.json") }.map { String($0.dropLast(".weekly.filed.json".count)) }
            unfiledDecks = Set(DailyDeckViewModel.deckDates(in: briefs, kind: "weekly")).subtracting(recordDates).subtracting(filedV1)
        }
        let complete = records != nil && photos != nil && briefs != nil
        loadError = complete ? nil : "Some weeks couldn't be read just now."
        if complete { isLoaded = true }
    }

    /// A folder's names, `[]` when it doesn't exist, nil when it couldn't be read.
    private func names(in path: String) async -> [String]? {
        do {
            return try await client.entryNames(sessionID: sessionID, path: path)
        } catch let error as APIError where error.isNotFound && !error.isVanishedSession {
            return []
        } catch {
            return nil
        }
    }

    /// The week's record, read once and kept for this model; nil when it is missing or unreadable.
    func record(_ weekEnding: String) async -> WeekRecord? {
        if let cached = records[weekEnding] { return cached }
        guard let content = try? await client.fileContent(sessionID: sessionID, path: Self.recordPath(weekEnding)),
              let record = try? WeekRecord.decode(Data(content.utf8)) else { return nil }
        records[weekEnding] = record
        return record
    }

    /// The record when this model has already read it.
    func cachedRecord(_ weekEnding: String) -> WeekRecord? { records[weekEnding] }

    /// The photo at `path` (a `photoPath`), or nil when there is none or it can't be read.
    func photoData(path: String) async -> Data? {
        try? await client.rawFile(sessionID: sessionID, path: path)
    }

    /// The grade ("hit", "partly", "miss") a later week gave the prediction, or nil while it is open.
    func grade(for predictionID: String) async -> String? {
        await loadAllRecords()
        return records.values.lazy.flatMap(\.graded).first { $0.id == predictionID }?.grade
    }

    func loadDuePredictions() async {
        await loadAllRecords()
        duePredictions = Self.duePredictions(in: Array(records.values), today: today)
    }

    /// Reads every listed record not read yet, once at a time across callers.
    private func loadAllRecords() async {
        if let allRecordsLoad { return await allRecordsLoad.value }
        let missing = recordDates.subtracting(records.keys)
        let client = client, sessionID = sessionID
        let task = Task { @MainActor in
            let contents = await withTaskGroup(of: (String, String?).self) { group in
                // A few at a time, so a year of records doesn't flood the server.
                var pending = missing.makeIterator()
                func addNext() {
                    guard let week = pending.next() else { return }
                    group.addTask { (week, try? await client.fileContent(sessionID: sessionID, path: Self.recordPath(week))) }
                }
                for _ in 0..<Self.recordReadsAtOnce { addNext() }
                var contents: [(String, String?)] = []
                for await item in group {
                    contents.append(item)
                    addNext()
                }
                return contents
            }
            for case let (week, content?) in contents {
                if let record = try? WeekRecord.decode(Data(content.utf8)) { self.records[week] = record }
            }
        }
        allRecordsLoad = task
        await task.value
        allRecordsLoad = nil
    }

    /// Predictions due on or before `today` that no record has graded.
    nonisolated static func duePredictions(in records: [WeekRecord], today: String) -> [DuePrediction] {
        let graded = Set(records.flatMap(\.graded).compactMap(\.id))
        return records.compactMap { record -> DuePrediction? in
            guard let prediction = record.prediction, let id = prediction.id, let due = prediction.due,
                  let text = prediction.text, due <= today, !graded.contains(id) else { return nil }
            return DuePrediction(id: id, text: text, due: due, probability: prediction.probability, weekEnding: record.weekEnding)
        }
        .sorted { ($0.due, $0.id) < ($1.due, $1.id) }
    }

    // MARK: Photo

    /// Uploads `jpeg` as the week's photo; the week shows it only once the server has it.
    func setPhoto(_ jpeg: Data, for weekEnding: String) async throws {
        try await client.uploadWeekPhoto(weekEnding: weekEnding, jpeg: jpeg)
        photoChanged(weekEnding, hasPhoto: true)
    }

    /// Deletes the week's photo on the server; the week keeps it on any failure.
    func removePhoto(for weekEnding: String) async throws {
        try await client.deleteWeekPhoto(weekEnding: weekEnding)
        photoChanged(weekEnding, hasPhoto: false)
    }

    private func photoChanged(_ weekEnding: String, hasPhoto: Bool) {
        WeekPhotoCache.invalidate(server: server, sessionID: sessionID, path: Self.photoPath(weekEnding))
        if hasPhoto { photoDates.insert(weekEnding) } else { photoDates.remove(weekEnding) }
        photoVersions[weekEnding, default: 0] += 1
    }

    // MARK: Weeks

    /// ISO weeks, Monday to Sunday, as the vault numbers them, in the device's time zone.
    nonisolated static let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    /// The tiles of ISO year `year`: one per Sunday whose ISO week-based year is `year` (52 or 53).
    nonisolated static func tiles(year: Int, today: Date, records: Set<String>, photos: Set<String>,
                      decks: Set<String>) -> [(weekEnding: String, number: Int, state: WeekTileState)] {
        let calendar = calendar
        // January 4th is always in ISO week 1; its week ends on the Sunday on or after it.
        guard let fourth = calendar.date(from: DateComponents(year: year, month: 1, day: 4, hour: 12)) else { return [] }
        let current = weekEnding(containing: today, calendar: calendar)
        var tiles: [(weekEnding: String, number: Int, state: WeekTileState)] = []
        var sunday = sundayEnding(fourth, calendar: calendar)
        while calendar.component(.yearForWeekOfYear, from: sunday) == year {
            let week = DailyDeckPaths.day(sunday, calendar: calendar)
            let state: WeekTileState
            if records.contains(week) {
                state = .reviewed(hasPhoto: photos.contains(week))
            } else if week == current {
                state = .current
            } else if week > current {
                state = .future
            } else {
                state = .unreviewed(hasDeck: decks.contains(week))
            }
            tiles.append((week, calendar.component(.weekOfYear, from: sunday), state))
            guard let next = calendar.date(byAdding: .day, value: 7, to: sunday) else { break }
            sunday = next
        }
        return tiles
    }

    /// The Sunday, `yyyy-MM-dd`, that ends the ISO week containing `date`.
    nonisolated static func weekEnding(containing date: Date, calendar: Calendar = calendar) -> String {
        DailyDeckPaths.day(sundayEnding(date, calendar: calendar), calendar: calendar)
    }

    private nonisolated static func sundayEnding(_ date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        return calendar.date(byAdding: .day, value: (8 - weekday) % 7, to: date) ?? date
    }

    /// The date in a listed name ("2026-10-18-week-ending.json", "2026-10-18.jpg") when it is a
    /// Sunday; older check-ins dated other days have no tile.
    nonisolated static func sunday(in name: String, suffix: String) -> String? {
        guard name.hasSuffix(suffix) else { return nil }
        let day = String(name.dropLast(suffix.count))
        guard day.count == 10, let date = DailyDeckPaths.date(day: day, calendar: calendar),
              calendar.component(.weekday, from: date) == 1, DailyDeckPaths.day(date, calendar: calendar) == day
        else { return nil }
        return day
    }

    /// "Week 43 · Oct 19–25, 2026": the record's number, else the ISO week's, and the week's days.
    nonisolated static func weekLabel(weekEnding: String, number: Int?) -> String {
        let calendar = calendar
        guard let end = DailyDeckPaths.date(day: weekEnding, calendar: calendar),
              let start = calendar.date(byAdding: .day, value: -6, to: end) else { return number.map { "Week \($0)" } ?? weekEnding }
        let week = number ?? calendar.component(.weekOfYear, from: end)
        let month = Date.FormatStyle.dateTime.month(.abbreviated).day()
        let range: String
        if calendar.component(.year, from: start) != calendar.component(.year, from: end) {
            range = "\(dayLabel(start))–\(dayLabel(end))"
        } else if calendar.component(.month, from: start) != calendar.component(.month, from: end) {
            range = "\(start.formatted(month))–\(end.formatted(month)), \(calendar.component(.year, from: end))"
        } else {
            range = "\(start.formatted(month))–\(calendar.component(.day, from: end)), \(calendar.component(.year, from: end))"
        }
        return "Week \(week) · \(range)"
    }

    /// "Oct 24, 2027" for `2027-10-24`.
    nonisolated static func dayLabel(_ day: String) -> String {
        DailyDeckPaths.date(day: day, calendar: calendar).map(dayLabel) ?? day
    }

    private nonisolated static func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
