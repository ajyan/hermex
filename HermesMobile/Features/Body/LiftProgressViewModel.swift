import Foundation
import Observation

/// One lift's page (board 3): its weight over time and each session. The plan supplies the
/// "Push · 4 × 6–8" line; if it can't be read the page just leaves that line out.
@MainActor
@Observable
final class LiftProgressViewModel {
    private(set) var state: BrainLoadState<BodyLift> = .loading
    private(set) var subtitle: String?

    @ObservationIgnored private let client: BodyDataClient
    @ObservationIgnored private let id: String
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private var generation = 0

    init(client: BodyDataClient, id: String, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.id = id
        self.onAPIError = onAPIError
    }

    /// Loads the lift. A refresh that fails (other than a 404) keeps what's on screen.
    func load() async {
        generation += 1
        let token = generation
        async let plan = try? client.plan()
        do {
            let lift = try await client.lift(id: id)
            let plan = await plan
            guard token == generation, !Task.isCancelled else { return }
            state = .loaded(lift)
            subtitle = plan.flatMap { LiftProgressCopy.subtitle(id: id, plan: $0) } ?? subtitle
        } catch {
            guard token == generation, !(error is CancellationError), (error as? URLError)?.code != .cancelled,
                  !Task.isCancelled else { return }
            onAPIError(error)
            let notFound = (error as? APIError)?.isNotFound ?? false
            if case .loaded = state, !notFound { return }
            state = notFound ? .unavailable : .failed(error.localizedDescription)
        }
    }
}

/// The words and numbers a lift's page composes from the server's values.
enum LiftProgressCopy {
    /// "Push · 4 × 6–8" for the lift with this id in the plan; nil when the plan doesn't have it.
    static func subtitle(id: String, plan: BodyPlan) -> String? {
        for (day, exercises) in plan.days {
            if let exercise = exercises.first(where: { $0.id == id }) {
                return "\(PlanEditCopy.dayTitle(day)) · \(PlanEditCopy.prescription(exercise))"
            }
        }
        return nil
    }

    /// The points that have a weight, oldest first, with their dates; bodyweight, band and cable
    /// lifts have none and show no chart.
    static func weighted(_ series: [BodyLiftPoint]) -> [(date: Date, weight: Double)] {
        series.compactMap { point in
            guard let weight = point.weight, let date = localNoon(point.date) else { return nil }
            return (date, weight)
        }
    }

    /// A session's calendar day as noon in the phone's time zone, so the chart labels it with that
    /// same day wherever the phone is.
    private static func localNoon(_ iso: String) -> Date? {
        let parts = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// One line on the change since the first session: "Up 35 lb since Nov 9.", "Holding at 145 lb
    /// since Nov 9.", "First session Nov 9."; nil without a weight to compare.
    static func change(_ series: [BodyLiftPoint], unit: String) -> String? {
        let points = series.filter { $0.weight != nil }
        guard let first = points.first, let firstWeight = first.weight, let last = points.last,
              let lastWeight = last.weight else { return nil }
        let since = PlanEditCopy.shortDate(first.date)
        guard points.count > 1 else { return "First session \(since)." }
        let delta = lastWeight - firstWeight
        let suffix = unit == "lb_each" ? "lb each" : "lb"
        if delta > 0 { return "Up \(BodyFormat.number(delta)) \(suffix) since \(since)." }
        if delta < 0 { return "Down \(BodyFormat.number(-delta)) \(suffix) since \(since)." }
        return "Holding at \(BodyFormat.weightLabel(unit: unit, weight: lastWeight)) since \(since)."
    }

    /// What VoiceOver reads for the chart: "Working weight by session: 145 lb on Nov 23, 150 lb on Dec 4".
    static func chartSummary(_ series: [BodyLiftPoint], unit: String) -> String {
        let steps = series.compactMap { point -> String? in
            guard let weight = point.weight else { return nil }
            return "\(BodyFormat.weightLabel(unit: unit, weight: weight)) on \(PlanEditCopy.shortDate(point.date))"
        }
        return "Working weight by session: " + steps.joined(separator: ", ")
    }
}
