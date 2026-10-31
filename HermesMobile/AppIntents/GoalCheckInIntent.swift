import AppIntents
import Foundation

/// "Check in a goal": checks a goal commitment in for the server's today from Siri, Shortcuts or
/// Spotlight, without opening Hermex. It runs in the app's process (a background launch when the
/// app isn't running), against the active server only, and refreshes the Goals widget after.
struct CheckInGoalIntent: AppIntent {
    static var title: LocalizedStringResource = "Check In a Goal"
    static var description = IntentDescription("Check a goal commitment in for today without opening Hermex.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Commitment")
    var commitment: GoalCommitmentEntity

    /// Ignored for a commitment counted by +1 (Outreach), which counts one more.
    @Parameter(title: "Check-in", default: .done)
    var status: GoalIntentStatus

    static var parameterSummary: some ParameterSummary {
        Summary("Check in \(\.$commitment) as \(\.$status)")
    }

    init() {}

    init(commitment: GoalCommitmentEntity, status: GoalIntentStatus = .done) {
        self.commitment = commitment
        self.status = status
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = try await GoalIntentCheckIns.checkIn(id: commitment.id, status: status.goalStatus)
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}

/// A goal commitment Siri and Shortcuts can name: "Stretch", under its goal.
struct GoalCommitmentEntity: AppEntity, Identifiable {
    /// "slug/commitment".
    let id: String
    /// The commitment's short name ("Stretch").
    let name: String
    /// Its goal's title without any parenthetical.
    let goal: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Goal commitment")
    }

    static var defaultQuery = GoalCommitmentQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(goal)")
    }
}

/// The active server's commitments, read live from `GET /api/goals` (an empty list when no webui
/// server is active, it can't be reached, or it has no Goals).
struct GoalCommitmentQuery: EntityStringQuery {
    func entities(for identifiers: [GoalCommitmentEntity.ID]) async throws -> [GoalCommitmentEntity] {
        let wanted = Set(identifiers)
        return await GoalIntentCheckIns.entities().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [GoalCommitmentEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return await GoalIntentCheckIns.entities().filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.goal.localizedCaseInsensitiveContains(query)
        }
    }

    func suggestedEntities() async throws -> [GoalCommitmentEntity] {
        await GoalIntentCheckIns.entities()
    }
}

/// How the intent checks a day commitment in.
enum GoalIntentStatus: String, AppEnum {
    case done, min, skip

    static var typeDisplayRepresentation: TypeDisplayRepresentation { TypeDisplayRepresentation(name: "Check-in") }

    static var caseDisplayRepresentations: [GoalIntentStatus: DisplayRepresentation] {
        [.done: "Done", .min: "2-minute version", .skip: "Skip"]
    }

    var goalStatus: GoalStatus { GoalStatus(rawValue: rawValue) ?? .done }
}

/// Why the intent couldn't check in, as Siri says it.
enum GoalIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case noServer, noGoals, unreachable, notFound, notSaved

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noServer: "Sign in to your Hermes server in Hermex first."
        case .noGoals: "This server doesn't have Goals."
        case .unreachable: "Couldn't reach your server. Open Hermex and try again."
        case .notFound: "That commitment isn't on your goals anymore."
        case .notSaved: "Couldn't save the check-in. Try again."
        }
    }
}

/// The intent's work against the active server, kept apart from App Intents so it can be tested
/// with a fake client.
enum GoalIntentCheckIns {
    /// The active server when it is a webui server, the only kind that can serve Goals.
    static func activeServer(_ registry: ServerRegistry = .shared) -> URL? {
        guard let account = registry.activeServer, account.kind == .webui else { return nil }
        return URL(string: account.urlString)
    }

    /// Every commitment of the active goals, in the server's order.
    static func entities(_ home: GoalsHome) -> [GoalCommitmentEntity] {
        home.goals.flatMap { goal in
            goal.week.commitments.map {
                GoalCommitmentEntity(id: "\(goal.slug)/\($0.id)", name: GoalsCopy.shortName($0.action),
                                     goal: GoalsCopy.shortTitle(goal.title))
            }
        }
    }

    static func entities(server: URL? = activeServer(),
                         client makeClient: (URL) -> GoalsDataClient = GoalsWidgetSync.client(for:)) async -> [GoalCommitmentEntity] {
        guard let server, let home = try? await makeClient(server).home() else { return [] }
        return entities(home)
    }

    /// Checks commitment `id` ("slug/commitment") in for the server's today, or counts one more on
    /// an item commitment, then hands the updated home to `onSaved` (by default the widget). A 409
    /// means the server's day turned since it was read, so it reads the new day and tries once more.
    /// Returns what Siri says.
    @MainActor
    static func checkIn(
        id: String,
        status: GoalStatus,
        server: URL? = activeServer(),
        client makeClient: (URL) -> GoalsDataClient = GoalsWidgetSync.client(for:),
        onSaved: ((URL, GoalsHome) -> Void)? = nil
    ) async throws -> String {
        guard let server else { throw GoalIntentError.noServer }
        guard let slash = id.firstIndex(of: "/") else { throw GoalIntentError.notFound }
        let slug = String(id[..<slash]), commitment = String(id[id.index(after: slash)...])
        let client = makeClient(server)
        var home = try await read(client)
        for attempt in 0..<2 {
            guard let g = home.goals.firstIndex(where: { $0.slug == slug }),
                  let row = home.goals[g].week.commitments.first(where: { $0.id == commitment })
            else { throw GoalIntentError.notFound }
            let request: GoalCheckInRequest = row.isItem
                ? .item(slug: slug, date: home.today, asOf: home.today, id: commitment, n: 1, note: nil)
                : .commitment(slug: slug, date: home.today, asOf: home.today, id: commitment, status: status)
            do {
                let result = try await client.checkIn(request, clientID: UUID().uuidString)
                home.goals[g] = result.goal
                home.streak = result.streak
                if let onSaved { onSaved(server, home) } else { GoalsWidgetSync.update(server: server, home: home) }
                return spoken(row, status: status)
            } catch {
                guard attempt == 0, case .http(409, _)? = error as? APIError else { throw GoalIntentError.notSaved }
                home = try await read(client)
            }
        }
        throw GoalIntentError.notSaved
    }

    /// "Stretch checked in for today."
    static func spoken(_ row: GoalCommitmentProgress, status: GoalStatus) -> String {
        let name = GoalsCopy.shortName(row.action)
        if row.isItem { return "One more \(name.lowercased()) counted for today." }
        switch status {
        case .min: return "\(name): 2-minute version logged for today."
        case .skip: return "\(name) skipped for today."
        default: return "\(name) checked in for today."
        }
    }

    private static func read(_ client: GoalsDataClient) async throws -> GoalsHome {
        do {
            return try await client.home()
        } catch {
            throw (error as? APIError)?.isNotFound == true ? GoalIntentError.noGoals : GoalIntentError.unreachable
        }
    }
}
