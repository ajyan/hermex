import Foundation
import Observation

private func workoutIsCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}

/// The live workout (board 2C): today's prescription as a `BodySession` he ticks through at the
/// gym, or a saved workout opened again by its id. Every change saves the whole session, debounced
/// and in order, so a slow response never lands on top of newer taps and a failed save keeps
/// everything on the phone.
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
    /// A lift whose last work set was just ticked, held open for what its card still asks: how many
    /// reps that set had left, and the coach's focus question. Answering them, or opening another
    /// lift, moves on.
    private(set) var effortPrompt: Int?
    /// The work set he just ticked, by its `uid`: the one "how many more could you have done?" is about.
    private(set) var askedSet: UUID?
    /// The body check, Baki's adjustments, and what their Undo needs. Changed only by the methods in
    /// WorkoutViewModel+Coach.swift.
    var coach = WorkoutCoachState()
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
    /// The saved workout this one reopens, instead of loading a prescription.
    let sessionID: String?

    @ObservationIgnored private let client: BodyDataClient
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let onAPIError: (Error) -> Void
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var hingeIDs: Set<String> = []
    /// The hinge offer was up when the body check took its lifts out; it comes back with them.
    @ObservationIgnored private var hingeOfferSuspended = false
    /// A saved workout opened again, by its id or because today's prescription came back closed.
    @ObservationIgnored private var isReopened = false
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
        self.sessionID = nil
        self.debounce = debounce
        self.onAPIError = onAPIError
    }

    /// Opens the saved workout `sessionID` again: a workout that saved itself, to add sets or say
    /// how it went. The server reopens it on the first save.
    init(client: BodyDataClient, sessionID: String, debounce: Duration = .milliseconds(400),
         onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.day = nil
        self.sessionID = sessionID
        self.debounce = debounce
        self.onAPIError = onAPIError
    }

    var session: BodySession? {
        if case .loaded(let session) = state { return session }
        return nil
    }

    // MARK: Load

    /// Loads today's prescription once, or the saved workout being reopened; a workout already on
    /// screen is never replaced. Today's saved, unfinished workout comes back resumed, with its ticks.
    func load() async {
        switch state {
        case .loaded, .unavailable: return
        case .loading, .failed: break
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let sessionID {
                let saved = try await client.session(id: sessionID)
                guard !Task.isCancelled else { return }
                apply(saved)
            } else {
                let prescription = try await client.prescription(day: day)
                guard !Task.isCancelled else { return }
                apply(prescription)
            }
        } catch {
            guard !workoutIsCancellation(error), !Task.isCancelled else { return }
            onAPIError(error)
            state = (error as? APIError)?.isNotFound == true ? .unavailable : .failed(error.localizedDescription)
        }
    }

    /// A saved workout opened again, with its ticks and numbers and no offers. Saving reopens it on
    /// the server, so the phone's copy stops calling it saved-by-itself. One he finished by hand
    /// stays closed: the server would answer every save with 409.
    private func apply(_ saved: BodySession) {
        var session = saved
        isReopened = true
        if saved.finished != nil, !saved.autoFinished { saveStatus = .finished }
        session.autoFinished = false
        current = Self.firstUnfinished(in: session.exercises, after: -1) ?? 0
        state = .loaded(session)
    }

    private func apply(_ prescription: BodyPrescription) {
        // A picked day whose workout closed itself today comes back as that saved workout. It opens
        // like any reopened one, so the first save reopens it instead of a fresh sheet replacing it.
        if let saved = prescription.saved, saved.finished != nil {
            apply(saved)
            return
        }
        // A resumed draft is the saved document itself, so everything logged in it stays.
        var session = prescription.saved ?? BodySession(
            id: prescription.id, day: prescription.day, phase: prescription.phase, deload: prescription.deload,
            exercises: prescription.exercises, trimmed: prescription.trimmed, movedHinge: prescription.movedHinge)
        session.adjustments = prescription.adjustments
        session.adjustmentAnswers = prescription.adjustmentAnswers
        session.bodyCheck = prescription.bodyCheck
        startCoach(for: session)
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

    /// Ticks or unticks one set. A ticked work set of a lift that counts reps asks how many more he
    /// could have done; an unticked set forgets its answer. Ticking a lift's last work set opens the
    /// next unfinished lift, once the card has nothing left to ask.
    func toggle(exercise e: Int, set s: Int) {
        guard let lift = lift(e), lift.sets.indices.contains(s) else { return }
        let wasComplete = Self.isComplete(lift)
        var completed = false
        mutate { session in
            session.exercises[e].sets[s].done.toggle()
            if !session.exercises[e].sets[s].done { session.exercises[e].sets[s].left = nil }
            completed = !wasComplete && Self.isComplete(session.exercises[e])
        }
        let uid = lift.sets[s].uid
        if self.lift(e)?.sets[s].done == true {
            if lift.sets[s].kind == .work, WorkoutCoach.asksRepsLeft(lift) { askedSet = uid }
        } else if askedSet == uid {
            askedSet = nil
        }
        // Once a work set the offer would drop from is ticked, it's too late to drop one; the warm-up
        // lifts come first and never count.
        if sleepBanner == .asking, lift.section.isTrimmable, lift.sets[s].kind == .work,
           self.lift(e)?.sets[s].done == true {
            sleepBanner = .hidden
        }
        if completed {
            didComplete(e)
        } else if effortPrompt == e, !Self.isComplete(self.lift(e) ?? lift) {
            effortPrompt = nil
        }
    }

    /// A lift just had its last work set ticked or its last open set removed. It stays open while its
    /// card still asks something (reps left on a set, the coach's focus question); with nothing to
    /// ask, the next lift opens.
    private func didComplete(_ e: Int) {
        guard let lift = lift(e) else { return }
        // Finished without a tick (its last open set was removed): the last set is the one to ask about.
        if WorkoutCoach.asksRepsLeft(lift), askedSet(in: lift) == nil,
           let last = lift.sets.last(where: { $0.kind == .work }), last.left == nil {
            askedSet = last.uid
        }
        if Self.waitsOnAnswer(lift, asked: askedSet(in: lift)) {
            effortPrompt = e
            current = e
        } else {
            advance(from: e)
        }
    }

    /// The place in `lift.sets` of the set the reps-left question is about, when it is one of this lift's.
    func askedSet(in lift: BodyExercise) -> Int? {
        guard let askedSet else { return nil }
        return lift.sets.firstIndex { $0.uid == askedSet }
    }

    /// A finished lift's card still has a question he hasn't answered.
    private static func waitsOnAnswer(_ lift: BodyExercise, asked: Int?) -> Bool {
        if let asked, lift.sets[asked].left == nil { return true }
        return WorkoutCoach.asksFocus(lift) && lift.focusCheck == nil
    }

    /// After an answer on a lift held open past its last set: with nothing left to ask, the next lift opens.
    private func advanceIfAnswered(_ e: Int) {
        guard effortPrompt == e, let lift = lift(e), Self.isComplete(lift),
              !Self.waitsOnAnswer(lift, asked: askedSet(in: lift)) else { return }
        effortPrompt = nil
        advance(from: e)
    }

    /// Sets one set's weight. Later work sets he hasn't ticked yet that still had the set's old
    /// weight follow the new one; a ticked set, a set given its own weight, and the warm-up sets
    /// keep theirs, and a cleared weight never carries forward.
    func setWeight(_ weight: Double?, exercise e: Int, set s: Int) {
        guard let lift = lift(e), lift.sets.indices.contains(s) else { return }
        let value = weight.map { max(0, $0) }
        mutate { session in
            let old = session.exercises[e].sets[s].weight
            session.exercises[e].sets[s].weight = value
            Self.carryForward(in: &session.exercises[e], from: s, changed: value != nil) { set in
                if set.weight == old { set.weight = value }
            }
        }
    }

    /// Sets the count one set logs: reps, or seconds for a hold, or yards for a carry. It carries
    /// to the later sets by the same rule as a weight.
    func setReps(_ count: Int?, exercise e: Int, set s: Int) {
        guard let lift = lift(e), lift.sets.indices.contains(s) else { return }
        let value = count.map { max(0, $0) }
        let path: WritableKeyPath<BodySet, Int?> = switch BodyMeasure(lift) {
        case .reps: \.reps
        case .hold: \.holdS
        case .distance: \.distanceYd
        }
        mutate { session in
            let old = session.exercises[e].sets[s][keyPath: path]
            session.exercises[e].sets[s][keyPath: path] = value
            Self.carryForward(in: &session.exercises[e], from: s, changed: value != nil) { set in
                if set[keyPath: path] == old { set[keyPath: path] = value }
            }
        }
    }

    /// The one rule for an edit carrying down a lift: from a work set, `apply` runs on each later
    /// work set that isn't ticked, and changes the ones that still had the old number.
    private static func carryForward(in lift: inout BodyExercise, from s: Int, changed: Bool,
                                     apply: (inout BodySet) -> Void) {
        guard changed, lift.sets[s].kind == .work else { return }
        for j in lift.sets.indices where j > s && lift.sets[j].kind == .work && !lift.sets[j].done {
            apply(&lift.sets[j])
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

    /// Deletes one set: any warm-up set, or a work set when another remains. Deleting the last open
    /// set completes the lift the same as ticking it would.
    func deleteSet(exercise e: Int, set s: Int) {
        guard let lift = lift(e), Self.canDelete(set: s, of: lift) else { return }
        mutate { $0.exercises[e].sets.remove(at: s) }
        guard let after = self.lift(e) else { return }
        if !Self.isComplete(lift), Self.isComplete(after) {
            didComplete(e)
        } else if effortPrompt == e, !Self.isComplete(after) {
            effortPrompt = nil
        }
    }

    /// Adds a set to every lift in `group` (a superset's round).
    func addRound(_ group: ClosedRange<Int>) {
        for e in group { addSet(exercise: e) }
    }

    /// Removes the last work set from every lift in `group` that has more than one.
    func removeRound(_ group: ClosedRange<Int>) {
        for e in group { removeSet(exercise: e) }
    }

    static func canDelete(set s: Int, of lift: BodyExercise) -> Bool {
        guard lift.sets.indices.contains(s) else { return false }
        return lift.sets[s].kind == .warm || lift.workSets.count > 1
    }

    /// Opens a lift. A question nobody answered goes away.
    func open(exercise e: Int) {
        guard lift(e) != nil else { return }
        effortPrompt = nil
        askedSet = nil
        current = e
    }

    /// Answers "how many more could you have done?" for the set he just ticked (3 means 3 or more),
    /// written on that set as `left`. A big lift's last set also sets the lift's `repsLeft`, which the
    /// server's progression reads. Never needed: the next set ticks with or without it.
    func setRepsLeft(_ left: Int) {
        guard let askedSet, let exercises = session?.exercises,
              let e = exercises.firstIndex(where: { lift in lift.sets.contains { $0.uid == askedSet } }),
              let s = exercises[e].sets.firstIndex(where: { $0.uid == askedSet }), exercises[e].sets[s].done else { return }
        let value = min(max(left, 0), 3)
        let isLast = exercises[e].sets.lastIndex { $0.kind == .work } == s
        mutate { session in
            session.exercises[e].sets[s].left = value
            if isLast, session.exercises[e].big { session.exercises[e].repsLeft = value }
        }
        advanceIfAnswered(e)
    }

    /// Answers the coach's focus question on a finished lift (`focus_check`, saved beside the lift's
    /// `coach` so history knows which focus it was for).
    func setFocusCheck(_ answer: BodyFocusAnswer, exercise e: Int) {
        guard let lift = lift(e), WorkoutCoach.asksFocus(lift), Self.isComplete(lift) else { return }
        mutate { $0.exercises[e].focusCheck = answer.rawValue }
        advanceIfAnswered(e)
    }

    /// Opens the next lift: an unfinished partner in the same superset first, then the next unfinished
    /// lift after it, wrapping to the start.
    private func advance(from e: Int) {
        guard let exercises = session?.exercises else { return }
        let group = Self.group(of: e, in: exercises)
        current = group.first { !Self.isComplete(exercises[$0]) }
            ?? Self.firstUnfinished(in: exercises, after: group.upperBound)
            ?? Self.firstUnfinished(in: exercises, after: -1) ?? e
    }

    // MARK: Something hurt

    /// Records that something hurt while the open lift was up, so the finish check starts from it.
    func logHurt(_ part: BodyPart, now: Date = .now) {
        guard let lift = lift(current) else { return }
        let hurt = BodyHurt(lift: lift.id, part: part, at: Self.localStamp(now))
        mutate { $0.hurts.append(hurt) }
    }

    /// Takes back one logged hurt (a mis-tap).
    func removeHurt(at index: Int) {
        guard session?.hurts.indices.contains(index) == true else { return }
        mutate { _ = $0.hurts.remove(at: index) }
    }

    /// The phone's local time as the server writes stamps, "2026-11-07T09:02:00".
    static func localStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: date)
    }

    // MARK: Offers

    /// "Drop a set": the last work set of every main, superset and optional lift that has more than
    /// one. The warm-up, the finisher, warm-up sets and ticked sets stay.
    func acceptSleepOffer() {
        guard sleepBanner == .asking else { return }
        var dropped: [String: BodySet] = [:]
        mutate { session in
            for i in session.exercises.indices {
                if let set = Self.dropLastSet(from: &session.exercises[i]) { dropped[session.exercises[i].id] = set }
            }
            session.trimmed = true
        }
        // The lifts the body check is holding lose theirs too, so they come back trimmed like the rest.
        for i in coach.removedLifts.indices {
            if let set = Self.dropLastSet(from: &coach.removedLifts[i]) { dropped[coach.removedLifts[i].id] = set }
        }
        droppedSets = dropped
        sleepBanner = .done
    }

    /// The rough-night trim for one lift: its last work set, when it is a main, superset or optional
    /// lift with more than one and that set isn't ticked.
    private static func dropLastSet(from lift: inout BodyExercise) -> BodySet? {
        guard lift.section.isTrimmable, lift.workSets.count > 1,
              let last = lift.sets.lastIndex(where: { $0.kind == .work }), !lift.sets[last].done else { return nil }
        return lift.sets.remove(at: last)
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
        for i in coach.removedLifts.indices {
            if let set = dropped[coach.removedLifts[i].id] { coach.removedLifts[i].sets.append(set) }
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
        var order = before.enumerated()
            .sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
        // A lift Baki's adjustment moved up after the hinge move stays moved.
        if let session { order = WorkoutCoach.reapplyingUsedMoves(order, in: session) }
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

    /// After the body check takes lifts out or puts them back: the hinge offer names only the hinge
    /// lifts still in the session, hides while there are none, and comes back with them.
    func refreshHingeOffer() {
        guard !hingeIDs.isEmpty, let exercises = session?.exercises else { return }
        let hinged = exercises.filter { hingeIDs.contains($0.id) && $0.section == .main }
        if hingeBanner == .asking, hinged.isEmpty {
            hingeBanner = .hidden
            hingeOfferSuspended = true
        } else if hingeOfferSuspended, !hinged.isEmpty {
            hingeBanner = .asking
            hingeOfferSuspended = false
        }
        if !hinged.isEmpty { hingeNames = hinged.map(\.name) }
    }

    /// After a reorder: the lift that was open stays open, unless it moved away to the end.
    func reopen(_ id: String?, movedAway: Bool) {
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

    /// Every change to the workout goes through here: it lands on screen at once and schedules the
    /// debounced save of the whole session.
    func mutate(_ change: (inout BodySession) -> Void) {
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
        // A reopened one is there already: untouched, it finishes as it stands and keeps its finish time.
        if !isReopened, generation == 0, sentGeneration == 0 { generation = 1 }
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

    func lift(_ e: Int) -> BodyExercise? {
        guard let exercises = session?.exercises, exercises.indices.contains(e) else { return nil }
        return exercises[e]
    }

    /// Every work set ticked.
    static func isComplete(_ lift: BodyExercise) -> Bool {
        let work = lift.workSets
        return !work.isEmpty && work.allSatisfy(\.done)
    }

    /// The lifts done together with `e`: its run of superset lifts, or just `e`.
    static func group(of e: Int, in exercises: [BodyExercise]) -> ClosedRange<Int> {
        guard exercises.indices.contains(e), exercises[e].section == .superset else { return e...e }
        var lo = e, hi = e
        while lo > 0, exercises[lo - 1].section == .superset { lo -= 1 }
        while hi < exercises.count - 1, exercises[hi + 1].section == .superset { hi += 1 }
        return lo...hi
    }

    /// A superset's set rows, round by round: each lift's warm-up sets first, then work set 1 of each
    /// lift, then set 2, so the lifts log back to back.
    static func pairedRows(_ exercises: [BodyExercise], group: ClosedRange<Int>) -> [WorkoutSetRef] {
        var warm: [WorkoutSetRef] = []
        var rounds: [[WorkoutSetRef]] = []
        for e in group {
            var round = 0
            for (s, set) in exercises[e].sets.enumerated() {
                let ref = WorkoutSetRef(exercise: e, set: s, id: set.uid)
                if set.kind == .warm { warm.append(ref); continue }
                if rounds.count <= round { rounds.append([]) }
                rounds[round].append(ref)
                round += 1
            }
        }
        return warm + rounds.flatMap { $0 }
    }

    private static func firstUnfinished(in exercises: [BodyExercise], after e: Int) -> Int? {
        exercises.indices.first { $0 > e && !isComplete(exercises[$0]) }
    }
}

/// One set row in a superset card: where the set lives, identified by the set's `uid`.
struct WorkoutSetRef: Identifiable, Equatable {
    let exercise: Int
    let set: Int
    let id: UUID
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
