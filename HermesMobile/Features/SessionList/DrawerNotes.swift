import Foundation
import Observation

/// The words of a drawer row's trailing note: what its section holds today, built from
/// what the section's own screen already reads. Nil means nothing to say, so no note.
enum DrawerNoteCopy {
    /// "Filed 7:42 AM" once today's morning answers are saved, "Ready" while today's deck
    /// waits, from the `briefs` folder listing.
    static func brief(_ entries: [WorkspaceEntry], today: String) -> String? {
        let answers = "\(today).morning.answers.json"
        if let filed = entries.first(where: { $0.name == answers }) {
            guard let modified = filed.modified else { return "Filed" }
            let time = Date(timeIntervalSince1970: modified).formatted(date: .omitted, time: .shortened)
            return "Filed \(time)"
        }
        return entries.contains { $0.name == "\(today).morning.json" } ? "Ready" : nil
    }

    /// "2 due": people due for a catch-up.
    static func people(_ home: BrainPeopleHome) -> String? {
        home.due.isEmpty ? nil : "\(home.due.count) due"
    }

    /// "Interview Thu" for the soonest booked interview: today, tomorrow, the weekday inside a
    /// week, the date beyond it.
    static func interview(_ pipeline: JobPipeline) -> String? {
        guard let next = pipeline.upcoming.first, next.inDays >= 0 else { return nil }
        switch next.inDays {
        case 0: return "Interview today"
        case 1: return "Interview tomorrow"
        case 2...6: return "Interview \(MealsCopy.weekday(next.on))"
        default: return "Interview \(DailyDeckPaths.label(next.on))"
        }
    }

    /// "37 due": Prep reviews waiting, shown when no interview is booked.
    static func reviews(_ home: PrepHome) -> String? {
        home.run.reviewsDue > 0 ? "\(home.run.reviewsDue) due" : nil
    }

    /// "Confirm the week" while a goal's week waits for its confirmation, else how many of
    /// today's commitments are still open ("2 left today").
    static func goals(_ home: GoalsHome) -> String? {
        if home.goals.contains(where: { $0.weekPending != nil }) { return "Confirm the week" }
        let open = home.goals
            .flatMap { $0.week.commitments.filter { $0.dueToday && !$0.isItem } }
            .filter { $0.effectiveStatus(home.today, today: home.today, yesterday: home.yesterday)?.isShown != true }
        return open.isEmpty ? nil : "\(open.count) left today"
    }

    /// "Legs done" after today's workout, else the next one in the rotation ("Legs next").
    static func body(_ home: BodyHome, today: String) -> String? {
        if let session = home.sessions.first(where: { $0.date == today }) {
            return "\(session.label.isEmpty ? session.day.capitalized : session.label) done"
        }
        guard let next = home.next else { return nil }
        return "\(next.label.isEmpty ? next.day.capitalized : next.label) next"
    }

    /// Tonight's main dish.
    static func meals(_ home: MealsHome) -> String? {
        guard let name = home.tonight?.main?.name, !name.isEmpty else { return nil }
        return name
    }
}

/// Reads one section's note. Throws when the read fails, so the model can keep the last note.
protocol DrawerNotesLoading: Sendable {
    func note(for section: DrawerSection, now: Date) async throws -> String?
}

/// Each section's note from one existing GET on `server`. Brain and Money have nothing cheap
/// to read (no "saved today" count; Money reads vault files and hides its amounts), so they
/// carry no note.
struct APIClientDrawerNotesLoader: DrawerNotesLoading {
    let server: URL
    var store = DailyDeckStore()

    func note(for section: DrawerSection, now: Date) async throws -> String? {
        let apiClient = APIClient(baseURL: server)
        switch section {
        case .dailyBrief:
            // The Brief's files are read through a session; one from an earlier day still
            // lists the folder. Without one there is nothing to read, and a note is never
            // worth creating a session for.
            guard let sessionID = store.latestSession(for: server)?.id else { return nil }
            let listing = try await apiClient.directoryList(sessionID: sessionID, path: DailyDeckPaths.directory)
            return DrawerNoteCopy.brief(listing.entries ?? [], today: DailyDeckPaths.day(now))
        case .people:
            return DrawerNoteCopy.people(try await APIClientBrainAdapter(apiClient: apiClient).peopleHome())
        case .interviewPrep:
            let pipeline = try? await APIClientJobPipelineAdapter(apiClient: apiClient).pipeline()
            if let note = pipeline.flatMap(DrawerNoteCopy.interview) { return note }
            return DrawerNoteCopy.reviews(try await APIClientPrepAdapter(apiClient: apiClient).home())
        case .goals:
            return DrawerNoteCopy.goals(try await APIClientGoalsAdapter(apiClient: apiClient).home())
        case .body:
            let home = try await APIClientBodyAdapter(apiClient: apiClient).home()
            return DrawerNoteCopy.body(home, today: BodyHomeCopy.localDay(now))
        case .meals:
            let home = try await APIClientMealsScreenAdapter(apiClient: apiClient).home(day: MealsCopy.localDay(now))
            return DrawerNoteCopy.meals(home)
        case .brain, .money:
            return nil
        }
    }
}

/// The drawer's notes for one server. The shell owns one per server and refreshes it when the
/// drawer opens; the drawer shows whatever is here and never waits on a read.
@MainActor
@Observable
final class DrawerNotesModel {
    private(set) var notes: [DrawerSection: String] = [:]

    @ObservationIgnored private let loader: DrawerNotesLoading
    @ObservationIgnored private let minimumInterval: TimeInterval
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(loader: DrawerNotesLoading, minimumInterval: TimeInterval = 60) {
        self.loader = loader
        self.minimumInterval = minimumInterval
    }

    /// Starts a background refresh unless one is running or one finished within the last minute.
    func refreshIfStale(now: Date = Date()) {
        guard refreshTask == nil else { return }
        if let lastRefresh, now.timeIntervalSince(lastRefresh) < minimumInterval { return }
        refreshTask = Task { [weak self] in
            await self?.refresh(now: now)
            self?.refreshTask = nil
        }
    }

    /// Reads every section at once. Each note lands as its read returns; a failed read keeps
    /// the note already shown, and a read with nothing to say clears it.
    func refresh(now: Date = Date()) async {
        let loader = loader
        await withTaskGroup(of: (DrawerSection, Result<String?, Error>).self) { group in
            for section in DrawerSection.allCases {
                group.addTask {
                    do { return (section, .success(try await loader.note(for: section, now: now))) }
                    catch { return (section, .failure(error)) }
                }
            }
            for await (section, result) in group {
                guard !Task.isCancelled, case .success(let note) = result, notes[section] != note else { continue }
                notes[section] = note
            }
        }
        lastRefresh = now
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
