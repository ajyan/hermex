import Foundation
import Observation

private func workoutIsCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}

/// The live workout (board 2C): today's prescription as a `BodySession` he ticks through at the
/// gym. Every change saves the whole session, debounced and in order, so a slow response never
/// lands on top of newer taps and a failed save keeps everything on the phone.
@MainActor
@Observable
final class WorkoutViewModel {
    /// `finished`: the server answered 409, so this workout was already finished elsewhere and
    /// nothing more is sent.
    enum SaveStatus: Equatable { case saved, saving, failed, finished }
    /// A banner's offer: waiting for an answer, taken (showing Undo), or gone.
    enum Banner: Equatable { case hidden, asking, done }

    private(set) var state: BrainLoadState<BodySession> = .loading
    /// The open lift's index in `exercises`.
    private(set) var current = 0
    /// A big lift whose last work set was just ticked, waiting for "how many more could you have done?".
    private(set) var effortPrompt: Int?
    private(set) var saveStatus: SaveStatus = .saved
    /// Last night, when it was rough enough to offer dropping a set.
    private(set) var sleepOffer: BodySleepOffer?
    private(set) var sleepBanner: Banner = .hidden
    /// The hinge lifts the morning offer would move, by name.
    private(set) var hingeNames: [String] = []
    private(set) var hingeBanner: Banner = .hidden
    /// How long ago he woke, for the hinge offer's copy.
    private(set) var hingeMinutes: Int?
    /// Why the last `finish` didn't go through; cleared by the next one.
    private(set) var finishError: String?
    private(set) var isFinishing = false

    /// The day asked for (push, legs, pull), or nil for the next in the rotation.
    let day: String?

    @ObservationIgnored private let client: BodyDataClient
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var hingeIDs: Set<String> = []
    /// The set each lift lost to "Drop a set", by lift id, for Undo.
    @ObservationIgnored private var droppedSets: [String: BodySet] = [:]
    /// The lift order before "Move to the end", for Undo.
    @ObservationIgnored private var orderBeforeHinge: [String] = []
    /// Counts local changes; a save reports only when nothing changed while it was out.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sentGeneration = 0
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    /// The tail of the save chain: each save starts after the one before it has answered.
    @ObservationIgnored private var sendTask: Task<Void, Never>?

    init(client: BodyDataClient, day: String?, debounce: Duration = .milliseconds(400),
         onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.day = day
        self.debounce = debounce
        self.onAPIError = onAPIError
    }

    var session: BodySession? {
        if case .loaded(let session) = state { return session }
        return nil
    }

    // MARK: Load

    /// Loads today's prescription once; a workout already on screen is never replaced. Today's
    /// saved, unfinished workout comes back resumed, with its ticks.
    func load() async {
        switch state {
        case .loaded, .unavailable: return
        case .loading, .failed: break
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let prescription = try await client.prescription(day: day)
            guard !Task.isCancelled else { return }
            apply(prescription)
        } catch {
            guard !workoutIsCancellation(error), !Task.isCancelled else { return }
            onAPIError(error)
            state = (error as? APIError)?.isNotFound == true ? .unavailable : .failed(error.localizedDescription)
        }
    }

    private func apply(_ prescription: BodyPrescription) {
        let session = BodySession(
            id: prescription.id, day: prescription.day, phase: prescription.phase, deload: prescription.deload,
            exercises: prescription.exercises, trimmed: prescription.trimmed, movedHinge: prescription.movedHinge)
        current = Self.firstUnfinished(in: session.exercises, after: -1) ?? 0
        if !prescription.resumed, !prescription.trimmed, let offer = prescription.offers.sleep {
            sleepOffer = offer
            sleepBanner = .asking
        }
        let hinged = session.exercises.filter { $0.hinge && $0.section == .main }
        if prescription.offers.hinge, !prescription.resumed, !prescription.movedHinge, !hinged.isEmpty {
            hingeIDs = Set(hinged.map(\.id))
            hingeNames = hinged.map(\.name)
            hingeMinutes = prescription.offers.hingeMinutes
            hingeBanner = .asking
        }
        state = .loaded(session)
    }

    // MARK: Sets

    /// Ticks or unticks one set. Ticking a lift's last work set opens the next unfinished lift,
    /// or first asks how many reps were left when it's a big lift.
    func toggle(exercise e: Int, set s: Int) {
        guard let lift = lift(e), lift.sets.indices.contains(s) else { return }
        let wasComplete = Self.isComplete(lift)
        var completed = false
        mutate { session in
            session.exercises[e].sets[s].done.toggle()
            completed = !wasComplete && Self.isComplete(session.exercises[e])
        }
        // Once a work set the offer would drop from is ticked, it's too late to drop one; the warm-up
        // lifts come first and never count.
        if sleepBanner == .asking, lift.section.isTrimmable, lift.sets[s].kind == .work,
           self.lift(e)?.sets[s].done == true {
            sleepBanner = .hidden
        }
        if completed {
            if lift.big { effortPrompt = e } else { advance(from: e) }
        } else if effortPrompt == e, !Self.isComplete(self.lift(e) ?? lift) {
            effortPrompt = nil
        }
    }

    /// Sets one set's weight, committed from the weight editor; the lift's later unticked work sets
    /// follow a new weight, but never a cleared one.
    func setWeight(_ weight: Double?, exercise e: Int, set s: Int) {
        guard let lift = lift(e), lift.sets.indices.contains(s) else { return }
        let value = weight.map { max(0, $0) }
        mutate { session in
            let kind = session.exercises[e].sets[s].kind
            session.exercises[e].sets[s].weight = value
            guard kind == .work, value != nil else { return }
            for j in session.exercises[e].sets.indices where j > s {
                let later = session.exercises[e].sets[j]
                if later.kind == .work, !later.done { session.exercises[e].sets[j].weight = value }
            }
        }
    }

    /// Sets the count one set logs: reps, or seconds for a hold, or yards for a carry.
    func setReps(_ count: Int?, exercise e: Int, set s: Int) {
        guard let lift = lift(e), lift.sets.indices.contains(s) else { return }
        let value = count.map { max(0, $0) }
        mutate { session in
            switch BodyMeasure(lift) {
            case .reps: session.exercises[e].sets[s].reps = value
            case .hold: session.exercises[e].sets[s].holdS = value
            case .distance: session.exercises[e].sets[s].distanceYd = value
            }
        }
    }

    /// Adds a work set copying the lift's last one, unticked.
    func addSet(exercise e: Int) {
        guard let lift = lift(e) else { return }
        let last = lift.sets.last { $0.kind == .work } ?? BodySet()
        let set = BodySet(kind: .work, weight: last.weight, reps: last.reps, holdS: last.holdS, distanceYd: last.distanceYd)
        mutate { $0.exercises[e].sets.append(set) }
        if effortPrompt == e { effortPrompt = nil }
    }

    /// Removes the lift's last work set, never the only one.
    func removeSet(exercise e: Int) {
        guard let lift = lift(e), lift.workSets.count > 1,
              let last = lift.sets.lastIndex(where: { $0.kind == .work }) else { return }
        deleteSet(exercise: e, set: last)
    }

    /// Deletes one set: any warm-up set, or a work set when another remains.
    func deleteSet(exercise e: Int, set s: Int) {
        guard let lift = lift(e), Self.canDelete(set: s, of: lift) else { return }
        mutate { $0.exercises[e].sets.remove(at: s) }
        if effortPrompt == e, let after = self.lift(e), !Self.isComplete(after) { effortPrompt = nil }
    }

    static func canDelete(set s: Int, of lift: BodyExercise) -> Bool {
        guard lift.sets.indices.contains(s) else { return false }
        return lift.sets[s].kind == .warm || lift.workSets.count > 1
    }

    /// Opens a lift. A reps-left question nobody answered goes away.
    func open(exercise e: Int) {
        guard lift(e) != nil else { return }
        effortPrompt = nil
        current = e
    }

    /// Answers the big-lift question (3 means 3 or more) and opens the next lift.
    func setRepsLeft(_ left: Int) {
        guard let e = effortPrompt, lift(e) != nil else { return }
        mutate { $0.exercises[e].repsLeft = min(max(left, 0), 3) }
        effortPrompt = nil
        advance(from: e)
    }

    private func advance(from e: Int) {
        guard let exercises = session?.exercises else { return }
        current = Self.firstUnfinished(in: exercises, after: e) ?? Self.firstUnfinished(in: exercises, after: -1) ?? e
    }

    // MARK: Offers

    /// "Drop a set": the last work set of every main, superset and optional lift that has more than
    /// one. The warm-up, the finisher, warm-up sets and ticked sets stay.
    func acceptSleepOffer() {
        guard sleepBanner == .asking else { return }
        var dropped: [String: BodySet] = [:]
        mutate { session in
            for i in session.exercises.indices where session.exercises[i].section.isTrimmable {
                let lift = session.exercises[i]
                guard lift.workSets.count > 1, let last = lift.sets.lastIndex(where: { $0.kind == .work }),
                      !lift.sets[last].done else { continue }
                dropped[lift.id] = session.exercises[i].sets.remove(at: last)
            }
            session.trimmed = true
        }
        droppedSets = dropped
        sleepBanner = .done
    }

    /// Puts the dropped sets back, keeping every tap made since.
    func undoSleepOffer() {
        guard sleepBanner == .done else { return }
        let dropped = droppedSets
        mutate { session in
            for i in session.exercises.indices {
                if let set = dropped[session.exercises[i].id] { session.exercises[i].sets.append(set) }
            }
            session.trimmed = false
        }
        droppedSets = [:]
        sleepBanner = .hidden
    }

    /// "Keep them all": the offer goes away and nothing changes.
    func keepAllSets() {
        if sleepBanner == .asking { sleepBanner = .hidden }
    }

    /// Moves the hinge lifts to the end of the main work; the open lift stays open.
    func moveHinge() {
        guard hingeBanner == .asking, let before = session?.exercises else { return }
        let openID = before.indices.contains(current) ? before[current].id : nil
        let moves = { (lift: BodyExercise) in self.hingeIDs.contains(lift.id) && lift.section == .main }
        var order = before.filter { !moves($0) }
        let insertAt = (order.lastIndex { $0.section == .main }).map { $0 + 1 } ?? 0
        order.insert(contentsOf: before.filter(moves), at: insertAt)
        orderBeforeHinge = before.map(\.id)
        mutate { session in
            session.exercises = order
            session.movedHinge = true
        }
        reopen(openID, movedAway: openID.map(hingeIDs.contains) ?? false)
        hingeBanner = .done
    }

    /// Puts the lifts back in the plan's order.
    func undoMoveHinge() {
        guard hingeBanner == .done, let before = session?.exercises else { return }
        let openID = before.indices.contains(current) ? before[current].id : nil
        let rank = Dictionary(uniqueKeysWithValues: orderBeforeHinge.enumerated().map { ($1, $0) })
        let order = before.enumerated()
            .sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
        mutate { session in
            session.exercises = order
            session.movedHinge = false
        }
        reopen(openID, movedAway: false)
        hingeBanner = .hidden
    }

    /// "Keep the order": the offer goes away.
    func keepHingeOrder() {
        if hingeBanner == .asking { hingeBanner = .hidden }
    }

    /// After a reorder: the lift that was open stays open, unless it moved away to the end.
    private func reopen(_ id: String?, movedAway: Bool) {
        guard let exercises = session?.exercises else { return }
        effortPrompt = nil
        if !movedAway, let id, let index = exercises.firstIndex(where: { $0.id == id }) {
            current = index
        } else {
            current = Self.firstUnfinished(in: exercises, after: -1) ?? 0
        }
    }

    // MARK: Saving

    /// Sends anything unsaved now instead of after the debounce: on leaving the screen, going to the
    /// background, Finish, or tapping Retry after a failure.
    func saveNow() {
        debounceTask?.cancel()
        debounceTask = nil
        enqueueSend(retryingFailure: true)
    }

    /// Waits until every scheduled save has answered (Finish, and tests).
    func idle() async {
        while true {
            let debounce = debounceTask, send = sendTask
            await debounce?.value
            await send?.value
            if debounce == debounceTask, send == sendTask { return }
        }
    }

    private func mutate(_ change: (inout BodySession) -> Void) {
        guard case .loaded(var session) = state else { return }
        change(&session)
        state = .loaded(session)
        guard saveStatus != .finished else { return }
        generation += 1
        saveStatus = .saving
        debounceTask?.cancel()
        let delay = debounce
        // Holds the view model strongly, so a tap made just before leaving the screen still saves.
        debounceTask = Task {
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self.enqueueSend(retryingFailure: false)
        }
    }

    private func enqueueSend(retryingFailure: Bool) {
        guard saveStatus != .finished else { return }
        let previous = sendTask
        sendTask = Task {
            await previous?.value
            await self.sendNewest(retryingFailure: retryingFailure)
        }
    }

    /// Saves the newest session if it hasn't gone yet. A response reports only when nothing changed
    /// while it was out; the server's copy never replaces local state.
    private func sendNewest(retryingFailure: Bool) async {
        guard case .loaded(let snapshot) = state, saveStatus != .finished else { return }
        guard generation > sentGeneration || (retryingFailure && saveStatus == .failed) else { return }
        let token = generation
        sentGeneration = token
        saveStatus = .saving
        do {
            _ = try await client.save(snapshot)
            guard token == generation else { return }
            saveStatus = .saved
        } catch let error as APIError where error.isConflict {
            // Finished elsewhere (another device, or a finish whose answer was lost): stop for good.
            debounceTask?.cancel()
            saveStatus = .finished
        } catch {
            guard token == generation, !workoutIsCancellation(error) else { return }
            onAPIError(error)
            saveStatus = .failed
        }
    }

    // MARK: Finishing

    /// Sends the last sets, then closes the workout with the how-was-it check. Nil means it didn't
    /// go through and the workout stays open (`finishError` says why). After it succeeds nothing
    /// is saved again, because the server answers a finished session with 409.
    func finish(check: BodyCheck) async -> BodyFinishResult? {
        guard let id = session?.id, !isFinishing else { return nil }
        isFinishing = true
        finishError = nil
        defer { isFinishing = false }
        // An untouched fresh workout has never been saved, and finishing needs the session on the server.
        if generation == 0, sentGeneration == 0 { generation = 1 }
        saveNow()
        await idle()
        switch saveStatus {
        case .failed:
            finishError = "Couldn't save your sets first. Check the connection and try again."
            return nil
        case .finished:
            finishError = "This workout was already finished."
            return nil
        case .saved, .saving:
            break
        }
        do {
            let result = try await client.finish(id: id, check: check)
            debounceTask?.cancel()
            saveStatus = .finished
            return result
        } catch {
            guard !workoutIsCancellation(error) else { return nil }
            if (error as? APIError)?.isConflict == true {
                debounceTask?.cancel()
                saveStatus = .finished
                finishError = "This workout was already finished."
            } else {
                onAPIError(error)
                finishError = (error as? APIError)?.serverMessage ?? error.localizedDescription
            }
            return nil
        }
    }

    // MARK: Helpers

    private func lift(_ e: Int) -> BodyExercise? {
        guard let exercises = session?.exercises, exercises.indices.contains(e) else { return nil }
        return exercises[e]
    }

    /// Every work set ticked.
    static func isComplete(_ lift: BodyExercise) -> Bool {
        let work = lift.workSets
        return !work.isEmpty && work.allSatisfy(\.done)
    }

    private static func firstUnfinished(in exercises: [BodyExercise], after e: Int) -> Int? {
        exercises.indices.first { $0 > e && !isComplete(exercises[$0]) }
    }
}

private extension APIError {
    var isConflict: Bool {
        if case .http(409, _) = self { return true }
        return false
    }
}

/// What a lift's sets count: reps, seconds held, or yards carried.
enum BodyMeasure: Equatable {
    case reps, hold, distance

    init(_ lift: BodyExercise) {
        if lift.target.holdS != nil {
            self = .hold
        } else if lift.target.distanceYd != nil {
            self = .distance
        } else {
            self = .reps
        }
    }

    func count(_ set: BodySet) -> Int? {
        switch self {
        case .reps: set.reps
        case .hold: set.holdS
        case .distance: set.distanceYd
        }
    }

    func count(_ set: BodyLastSet) -> Int? {
        switch self {
        case .reps: set.reps
        case .hold: set.holdS
        case .distance: set.distanceYd
        }
    }
}
