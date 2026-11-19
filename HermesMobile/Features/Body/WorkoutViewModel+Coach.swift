import Foundation

/// What the body check and Baki's adjustments keep on the phone while a workout is open: the
/// banner's state, the lifts taken out (so they can come back as they were), and what each used
/// adjustment's Undo needs. None of it is sent; the session document carries the answers.
struct WorkoutCoachState: Equatable {
    /// "How's your body today?": asking, answered with a sore area (its line), or gone.
    var bodyCheckBanner: WorkoutViewModel.Banner = .hidden
    /// The lifts a sore area took out of today's session, for Put them back.
    var removedLifts: [BodyExercise] = []
    /// The lift ids in order before those lifts were taken out.
    var orderBeforeBodyCheck: [String] = []
    /// False on a saved workout opened again, which shows no offers.
    var asksAdjustments = false
    /// How to put back each adjustment he used, by its id. Empty on a resumed workout.
    var undo: [String: WorkoutAdjustmentUndo] = [:]
}

/// What a used adjustment changed: the lift a moved lift followed before (nil when it was first),
/// or the reps the capped set had.
enum WorkoutAdjustmentUndo: Equatable {
    case move(after: String?)
    case cap(reps: Int?)
}

// The body check before a workout and Baki's adjustments. Each change goes through `mutate`, so it
// saves with the whole session like a tick does.
extension WorkoutViewModel {
    /// Sets up the banners for a fresh or resumed workout. The body check asks only before the
    /// first tick, on a server that says what each lift loads; a resumed workout shows its answer.
    func startCoach(for session: BodySession) {
        coach = WorkoutCoachState(asksAdjustments: true)
        if let check = session.bodyCheck {
            coach.bodyCheckBanner = check.bodyArea == nil ? .hidden : .done
        } else if WorkoutCoach.offersBodyCheck(session.exercises),
                  !session.exercises.contains(where: { $0.sets.contains(where: \.done) }) {
            coach.bodyCheckBanner = .asking
        }
    }

    // MARK: The body check

    /// The answered check as one line; nil while it asks, and after "All good".
    var bodyCheckLine: String? {
        guard let session, let check = session.bodyCheck, let area = check.bodyArea else { return nil }
        return WorkoutCoach.bodyCheckLine(
            area: area, score: check.score, removed: coach.removedLifts.map(\.name),
            removedCount: check.removed.count,
            loaded: session.exercises.contains { WorkoutCoach.loads($0, area) })
    }

    /// The line's button: Put them back while the app holds the lifts it took out, Change when
    /// nothing is out, and none on a resumed workout whose lifts it can no longer restore.
    var bodyCheckAction: WorkoutBodyCheckAction? {
        guard let check = session?.bodyCheck else { return nil }
        if !coach.removedLifts.isEmpty { return .putBack }
        return check.removed.isEmpty ? .change : nil
    }

    /// Answers the check. `area` nil is "All good". At 4 or more, every lift that loads the area
    /// and has no ticked set leaves today's session and is listed in `body_check.removed`.
    func answerBodyCheck(area: BodyArea?, score: Int) {
        guard coach.bodyCheckBanner == .asking, let before = session?.exercises else { return }
        let score = area == nil ? 0 : min(max(score, 0), 10)
        let openID = before.indices.contains(current) ? before[current].id : nil
        // A changed answer starts from the whole session again.
        var exercises = WorkoutCoach.restore(coach.removedLifts, into: before, order: coach.orderBeforeBodyCheck)
        var removed: [BodyExercise] = []
        if let area, score >= WorkoutCoach.removeAt {
            removed = WorkoutCoach.removable(area, in: exercises)
            // Never an empty workout: the screen would have nothing to show, the banner included.
            if removed.count == exercises.count { removed = [] }
            let ids = Set(removed.map(\.id))
            coach.orderBeforeBodyCheck = exercises.map(\.id)
            exercises.removeAll { ids.contains($0.id) }
        }
        coach.removedLifts = removed
        let reordered = exercises.map(\.id) != before.map(\.id)
        mutate { session in
            session.exercises = exercises
            session.bodyCheck = BodyDayCheck(area: area, score: score, removed: removed.map(\.id))
        }
        coach.bodyCheckBanner = area == nil ? .hidden : .done
        if reordered {
            reopen(openID, movedAway: openID.map { id in removed.contains { $0.id == id } } ?? false)
            refreshHingeOffer()
        }
    }

    /// "Change": the question comes back; the saved answer stays until he gives a new one.
    func changeBodyCheck() {
        guard coach.bodyCheckBanner == .done, bodyCheckAction == .change else { return }
        coach.bodyCheckBanner = .asking
    }

    /// "Put them back": the lifts return where they were, with the area and score kept.
    func putBackBodyCheckLifts() {
        guard coach.bodyCheckBanner == .done, !coach.removedLifts.isEmpty, let before = session?.exercises else { return }
        let openID = before.indices.contains(current) ? before[current].id : nil
        let exercises = WorkoutCoach.restore(coach.removedLifts, into: before, order: coach.orderBeforeBodyCheck)
        coach.removedLifts = []
        mutate { session in
            session.exercises = exercises
            session.bodyCheck?.removed = []
        }
        reopen(openID, movedAway: false)
        refreshHingeOffer()
    }

    // MARK: Adjustments

    /// Baki's adjustments as banners: questions not yet answered, and the ones he used.
    var adjustmentRows: [WorkoutAdjustmentRow] {
        guard coach.asksAdjustments, let session else { return [] }
        return WorkoutCoach.adjustmentRows(session) { canUndo($0, in: session) }
    }

    /// A move undoes while the app remembers where the lift was. A cap undoes until set 1 is
    /// ticked, back to the reps it had, or to the set's goal on a resumed workout.
    private func canUndo(_ adjustment: BodyAdjustment, in session: BodySession) -> Bool {
        switch adjustment.kind {
        case BodyAdjustment.moveUp:
            if case .move = coach.undo[adjustment.id] { return true }
            return false
        case BodyAdjustment.capFirst:
            guard !WorkoutCoach.firstWorkSetDone(adjustment.lift, in: session.exercises) else { return false }
            if case .cap = coach.undo[adjustment.id] { return true }
            return session.exercises.first { $0.id == adjustment.lift }?.goalReps?.first != nil
        default:
            return false
        }
    }

    /// Takes an adjustment: moves the lift up, or caps the first work set, and records `use`.
    func useAdjustment(_ id: String) {
        guard let session, session.adjustmentAnswers?[id] == nil,
              let adjustment = session.adjustments?.first(where: { $0.id == id }),
              WorkoutCoach.applies(adjustment, to: session.exercises),
              let e = session.exercises.firstIndex(where: { $0.id == adjustment.lift }) else { return }
        switch adjustment.kind {
        case BodyAdjustment.moveUp:
            guard let moved = WorkoutCoach.movedUp(adjustment, in: session.exercises) else { return }
            let openID = session.exercises.indices.contains(current) ? session.exercises[current].id : nil
            coach.undo[id] = .move(after: e > 0 ? session.exercises[e - 1].id : nil)
            mutate { session in
                session.exercises = moved
                session.adjustmentAnswers = (session.adjustmentAnswers ?? [:]).merging([id: BodyAdjustment.used]) { $1 }
            }
            reopen(openID, movedAway: false)
        case BodyAdjustment.capFirst:
            guard let s = WorkoutCoach.firstWorkSet(session.exercises[e]), let reps = adjustment.reps,
                  !session.exercises[e].sets[s].done else { return }
            coach.undo[id] = .cap(reps: session.exercises[e].sets[s].reps)
            mutate { session in
                session.exercises[e].sets[s].reps = reps
                session.adjustmentAnswers = (session.adjustmentAnswers ?? [:]).merging([id: BodyAdjustment.used]) { $1 }
            }
        default:
            return
        }
    }

    /// "Keep the order", "Go by feel": records `keep` and the banner goes.
    func keepAdjustment(_ id: String) {
        guard let session, session.adjustmentAnswers?[id] == nil,
              session.adjustments?.contains(where: { $0.id == id }) == true else { return }
        mutate { session in
            session.adjustmentAnswers = (session.adjustmentAnswers ?? [:]).merging([id: BodyAdjustment.kept]) { $1 }
        }
    }

    /// Undo on a used adjustment: the order or the reps go back and the answer is cleared, so the
    /// question shows again.
    func undoAdjustment(_ id: String) {
        guard let session, session.adjustmentAnswers?[id] == BodyAdjustment.used,
              let adjustment = session.adjustments?.first(where: { $0.id == id }),
              canUndo(adjustment, in: session),
              let e = session.exercises.firstIndex(where: { $0.id == adjustment.lift }) else { return }
        switch (adjustment.kind, coach.undo[id]) {
        case (BodyAdjustment.moveUp, .move(let predecessor)):
            let openID = session.exercises.indices.contains(current) ? session.exercises[current].id : nil
            let order = WorkoutCoach.movedBack(adjustment.lift, after: predecessor, in: session.exercises)
            mutate { session in
                session.exercises = order
                session.adjustmentAnswers?[id] = nil
            }
            reopen(openID, movedAway: false)
        case (BodyAdjustment.capFirst, let undo):
            guard let s = WorkoutCoach.firstWorkSet(session.exercises[e]) else { return }
            let reps: Int?
            if case .cap(let before) = undo { reps = before } else { reps = session.exercises[e].goalReps?.first }
            mutate { session in
                session.exercises[e].sets[s].reps = reps
                session.adjustmentAnswers?[id] = nil
            }
        default:
            return
        }
        coach.undo[id] = nil
    }
}
