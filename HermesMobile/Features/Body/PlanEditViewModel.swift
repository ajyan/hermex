import Foundation
import Observation

/// The plan editor (board 4): the whole `plan.yaml` as a document he edits in memory and saves in
/// one request. The server validates it and answers a 400 with the reason, which stays on screen
/// next to his edits.
@MainActor
@Observable
final class PlanEditViewModel {
    enum Phase: Equatable { case loading, loaded, unavailable, failed(String) }

    private(set) var phase: Phase = .loading
    /// The plan with his edits.
    private(set) var plan = BodyPlan()
    private(set) var saveError: String?
    private(set) var isSaving = false

    @ObservationIgnored private var original = BodyPlan()
    @ObservationIgnored private let client: BodyDataClient
    @ObservationIgnored private let onAPIError: (Error) -> Void

    init(client: BodyDataClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.onAPIError = onAPIError
    }

    /// True when the plan differs from what the server last sent.
    var dirty: Bool { plan != original }

    /// The days he can edit, in screen order: the warm-up, then the rotation.
    var dayKeys: [String] {
        let rotation = plan.rotation.filter { plan.days[$0] != nil }
        return (plan.days["warmup"] != nil ? ["warmup"] : []) + rotation.filter { $0 != "warmup" }
    }

    func exercises(day: String) -> [BodyPlanExercise] { plan.days[day] ?? [] }

    /// The day the editor opens on: the first workout day, else the warm-up.
    var defaultDay: String { dayKeys.first { $0 != "warmup" } ?? dayKeys.first ?? "" }

    /// `selected` when it is a day in the plan, else the default, so the screen never edits a day
    /// that isn't there (before the first load, or after a retry).
    func resolvedDay(_ selected: String) -> String { dayKeys.contains(selected) ? selected : defaultDay }

    // MARK: Load

    /// Loads the plan once; edits already on screen are never replaced.
    func load() async {
        if phase == .loaded { return }
        do {
            let loaded = try await client.plan()
            guard !Task.isCancelled, phase != .loaded else { return }
            plan = loaded
            original = loaded
            phase = .loaded
        } catch {
            guard !(error is CancellationError), (error as? URLError)?.code != .cancelled, !Task.isCancelled else { return }
            onAPIError(error)
            phase = (error as? APIError)?.isNotFound == true ? .unavailable : .failed(error.localizedDescription)
        }
    }

    // MARK: Edits

    /// Reorders one day's exercises (the offsets are positions in the day).
    func move(day: String, from source: IndexSet, to destination: Int) {
        guard var list = plan.days[day] else { return }
        list.move(fromOffsets: source, toOffset: destination)
        edit { $0.days[day] = list }
    }

    /// Reorders within one section of a day, which the screen lists as its own group. The section's
    /// exercises keep the day positions they had; only which exercise sits in which of them changes.
    func move(day: String, section: BodySection, from source: IndexSet, to destination: Int) {
        guard var list = plan.days[day] else { return }
        let slots = list.indices.filter { list[$0].section == section }
        var inSection = slots.map { list[$0] }
        inSection.move(fromOffsets: source, toOffset: destination)
        for (slot, exercise) in zip(slots, inSection) { list[slot] = exercise }
        edit { $0.days[day] = list }
    }

    /// Adds `exercise` to the end of a day under a new id made from its name, unique across the
    /// whole plan (the server rejects a repeated id). Returns the id, or nil when `day` isn't a day
    /// in the plan.
    @discardableResult
    func add(day: String, exercise: BodyPlanExercise) -> String? {
        guard plan.days[day] != nil else { return nil }
        let id = uniqueID(for: exercise.name)
        let added = exercise.withID(id)
        edit { plan in
            var list = plan.days[day] ?? []
            // Stay with its own section's group: after the last exercise of that section, else at the end.
            let insertAt = list.lastIndex { $0.section == added.section }.map { $0 + 1 } ?? list.count
            list.insert(added, at: insertAt)
            plan.days[day] = list
        }
        return id
    }

    func remove(day: String, id: String) {
        guard plan.days[day]?.contains(where: { $0.id == id }) == true else { return }
        edit { $0.days[day]?.removeAll { $0.id == id } }
    }

    func update(day: String, id: String, _ change: (inout BodyPlanExercise) -> Void) {
        guard let index = plan.days[day]?.firstIndex(where: { $0.id == id }) else { return }
        edit { change(&$0.days[day]![index]) }
    }

    /// Sets a phase's start (`end` false) or its last day (`end` true), as an ISO date.
    func setPhase(_ name: String, end: Bool, to date: Date) {
        guard var spec = plan.phases[name] else { return }
        let iso = PlanEditCopy.iso(date)
        if end { spec.end = iso } else { spec.start = iso }
        edit { $0.phases[name] = spec }
    }

    private func edit(_ change: (inout BodyPlan) -> Void) {
        change(&plan)
        saveError = nil
    }

    private func uniqueID(for name: String) -> String {
        let taken = Set(plan.days.values.flatMap { $0.map(\.id) })
        let base = PlanEditCopy.slug(name)
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    // MARK: Save

    /// Sends the whole plan. On a server rejection `saveError` holds its message and the edits stay.
    func save() async throws {
        guard dirty, !isSaving else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let saved = try await client.savePlan(plan)
            plan = saved
            original = saved
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                onAPIError(error)
                saveError = (error as? APIError)?.serverMessage ?? error.localizedDescription
            }
            throw error
        }
    }
}

extension BodyPlanExercise {
    /// A new exercise for the editor: 3 sets of 8 to 12 reps in pounds, with no weight yet.
    static func draft(name: String, section: BodySection = .main) -> BodyPlanExercise {
        BodyPlanExercise(
            id: "", name: name, section: section, sets: 3, reps: [8, 12], holdS: nil, distanceYd: nil,
            big: false, newborn: false, hinge: false, perSide: false, rampSets: nil, goalReps: nil,
            alternates: nil, alternateWeekly: nil, load: BodyPlanLoad(unit: "lb"))
    }

    init(id: String, name: String, section: BodySection, sets: Int, reps: [Int]?, holdS: Int?, distanceYd: Int?,
         big: Bool, newborn: Bool, hinge: Bool, perSide: Bool, rampSets: Int?, goalReps: [Int]?,
         alternates: [String]?, alternateWeekly: String?, load: BodyPlanLoad) {
        self.id = id
        self.name = name
        self.section = section
        self.sets = sets
        self.reps = reps
        self.holdS = holdS
        self.distanceYd = distanceYd
        self.big = big
        self.newborn = newborn
        self.hinge = hinge
        self.perSide = perSide
        self.rampSets = rampSets
        self.goalReps = goalReps
        self.alternates = alternates
        self.alternateWeekly = alternateWeekly
        self.load = load
    }

    func withID(_ id: String) -> BodyPlanExercise {
        BodyPlanExercise(
            id: id, name: name, section: section, sets: sets, reps: reps, holdS: holdS, distanceYd: distanceYd,
            big: big, newborn: newborn, hinge: hinge, perSide: perSide, rampSets: rampSets, goalReps: goalReps,
            alternates: alternates, alternateWeekly: alternateWeekly, load: load)
    }
}

/// The words and small conversions the plan editor and a lift's page share.
enum PlanEditCopy {
    /// "Incline bench" becomes "incline-bench"; a name with no letters or digits becomes "exercise".
    static func slug(_ name: String) -> String {
        let words = name.lowercased().split { !($0.isLetter || $0.isNumber) }
        return words.isEmpty ? "exercise" : words.joined(separator: "-")
    }

    /// "Warm-up" for the warm-up day, else the day capitalized.
    static func dayTitle(_ day: String) -> String { day == "warmup" ? "Warm-up" : day.capitalized }

    /// "3 × 6–8", "3 × 10 s", or "3 × 40 yd": what one exercise asks of each set.
    static func prescription(_ exercise: BodyPlanExercise) -> String {
        if let reps = exercise.reps, reps.count == 2 {
            return reps[0] == reps[1] ? "\(exercise.sets) × \(reps[0])" : "\(exercise.sets) × \(reps[0])–\(reps[1])"
        }
        if let hold = exercise.holdS { return "\(exercise.sets) × \(hold) s" }
        if let distance = exercise.distanceYd { return "\(exercise.sets) × \(distance) yd" }
        return "\(exercise.sets) sets"
    }

    /// "3 × 6–8 · 75 lb" for a row in the editor.
    static func summary(_ exercise: BodyPlanExercise) -> String {
        let weight = exercise.load.build.map { BodyFormat.weightLabel(unit: exercise.load.unit, weight: $0) }
            ?? (["bw", "band", "cable"].contains(exercise.load.unit)
                ? BodyFormat.weightLabel(unit: exercise.load.unit, weight: nil) : nil)
        return [prescription(exercise), weight].compactMap { $0 }.joined(separator: " · ")
    }

    static func unitTitle(_ unit: String) -> String {
        switch unit {
        case "lb": "Pounds"
        case "lb_each": "Pounds, each hand"
        case "bw": "Bodyweight"
        case "band": "Band"
        case "cable": "Light cable"
        default: unit
        }
    }

    static let units = ["lb", "lb_each", "bw", "band", "cable"]

    /// What a typed weight means: a number (nil when the field is empty), or not a weight at all.
    /// A comma works as the decimal point; negatives are not weights.
    static func parseWeight(_ text: String) -> (isValid: Bool, value: Double?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if trimmed.isEmpty { return (true, nil) }
        guard let value = Double(trimmed), value >= 0, value.isFinite else { return (false, nil) }
        return (true, value)
    }

    /// True when the unit has a number to type.
    static func hasWeight(_ unit: String) -> Bool { unit == "lb" || unit == "lb_each" }

    /// "Build until Dec 27", "Starts Nov 23": one line for a phase.
    static func phaseLine(_ spec: BodyPhaseSpec) -> String {
        if let end = spec.end { return "\(shortDate(spec.start)) – \(shortDate(end))" }
        return "From \(shortDate(spec.start))"
    }

    /// "2026-11-09" reads "Nov 9"; the input unchanged when it isn't a date.
    static func shortDate(_ iso: String) -> String {
        guard let date = parse(iso) else { return iso }
        return shortFormatter.string(from: date)
    }

    static func parse(_ iso: String) -> Date? { isoFormatter.date(from: iso) }

    static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }

    /// The plan's dates are calendar days, so both formatters read and write them in UTC.
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()
}
