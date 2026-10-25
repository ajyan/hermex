import Foundation
import Observation
import SwiftUI

/// A week's accepted dinners, from `GET /api/meals/week` or the answer to accepting
/// (`POST /api/meals/accept`): the picks, how many grocery items went to each store, the prep list,
/// and what happened in Reminders.
struct MealsWeek: Decodable, Equatable {
    let week: String
    let accepted: Bool
    let picks: [Pick]
    let groceries: [String: Int]
    let prep: [String]
    /// The Reminders error, when the lists couldn't be written (the plan is saved either way).
    let remindersError: String?

    struct Pick: Decodable, Equatable {
        let dish: String
        let name: String
        let veg: [String]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dish = try c.decode(String.self, forKey: .dish)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? dish
            veg = (try? c.decodeIfPresent([String].self, forKey: .veg)) ?? []
        }

        private enum CodingKeys: String, CodingKey { case dish, name, veg }
    }

    private struct Reminders: Decodable {
        let error: String?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        week = try c.decode(String.self, forKey: .week)
        groceries = (try? c.decodeIfPresent([String: Int].self, forKey: .groceries)) ?? [:]
        // Accepting answers without `accepted`: an answer at all means it was saved.
        accepted = (try? c.decodeIfPresent(Bool.self, forKey: .accepted)) ?? true
        picks = ((try? c.decodeIfPresent([Lossy<Pick>].self, forKey: .picks)) ?? []).compactMap(\.value)
        prep = (try? c.decodeIfPresent([String].self, forKey: .prep)) ?? []
        remindersError = (try? c.decodeIfPresent(Reminders.self, forKey: .reminders))?.error
    }

    private enum CodingKeys: String, CodingKey { case week, accepted, picks, groceries, prep, reminders }

    /// "Weee! 12 · Whole Foods 9", stores in a fixed order.
    var groceryLine: String? {
        let order = ["Weee!", "Whole Foods", "Imperfect"]
        let parts = groceries.sorted { (order.firstIndex(of: $0.key) ?? 9, $0.key) < (order.firstIndex(of: $1.key) ?? 9, $1.key) }
            .map { "\($0.key) \($0.value)" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct MealsAcceptRequest: Encodable, Equatable {
    struct Pick: Encodable, Equatable {
        let dish: String
        let veg: [String]
    }

    let week: String
    let picks: [Pick]
    let backup: String?
}

protocol MealsDataClient: Sendable {
    func week(_ monday: String) async throws -> MealsWeek
    func accept(_ request: MealsAcceptRequest) async throws -> MealsWeek
}

/// Wraps the `APIClient` actor in a `Sendable` value for the protocol, decoding with `PrepDecoding`.
struct APIClientMealsAdapter: MealsDataClient {
    let apiClient: APIClient

    func week(_ monday: String) async throws -> MealsWeek {
        try decode(try await apiClient.sendData(endpoint: .mealsWeek(week: monday), method: "GET", encodedBody: nil, timeout: 8))
    }

    func accept(_ request: MealsAcceptRequest) async throws -> MealsWeek {
        // Writing Reminders on the Mac takes a few seconds.
        try decode(try await apiClient.sendData(endpoint: .mealsAccept, method: "POST", body: request))
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try PrepDecoding.decode(Value.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }
}

/// The meals card's server side: whether the week is already planned, and accepting a plan. The
/// Deck owns one per screen. Nothing shows as accepted until the server says it saved.
@MainActor
@Observable
final class MealsPlanModel {
    /// Accepted weeks by Monday, from a load or an accept.
    private(set) var weeks: [String: MealsWeek] = [:]
    /// Weeks a load found unplanned.
    private(set) var unplanned: Set<String> = []
    private(set) var pending = false
    private(set) var error: String?

    @ObservationIgnored private let client: MealsDataClient
    @ObservationIgnored private let onAPIError: (Error) -> Void

    init(client: MealsDataClient, onAPIError: @escaping (Error) -> Void = { _ in }) {
        self.client = client
        self.onAPIError = onAPIError
    }

    /// The week's accepted plan, or nil while it's open (or unknown).
    func accepted(_ week: String) -> MealsWeek? {
        weeks[week].flatMap { $0.accepted ? $0 : nil }
    }

    func load(week: String) async {
        do {
            let result = try await client.week(week)
            if result.accepted { weeks[week] = result } else { unplanned.insert(week) }
        } catch {
            // An older server or a failed read leaves the card editable; accepting reports its own errors.
            if !(error is CancellationError) { onAPIError(error) }
        }
    }

    /// Whether the server saved the plan.
    @discardableResult
    func accept(_ request: MealsAcceptRequest) async -> Bool {
        guard !pending else { return false }
        pending = true
        error = nil
        defer { pending = false }
        do {
            weeks[request.week] = try await client.accept(request)
            unplanned.remove(request.week)
            return true
        } catch {
            onAPIError(error)
            self.error = (error as? APIError)?.isNotFound == true
                ? "This server can't plan meals yet. Say \"plan meals\" in chat instead."
                : "Couldn't save the plan. Try again."
            return false
        }
    }

    /// Opens an accepted week for changes; accepting again replaces it.
    func reopen(_ week: String) {
        weeks[week] = nil
        unplanned.insert(week)
    }
}

/// What the meals card has chosen so far: per night, which candidate is picked and where the
/// alternatives row starts. Kept apart from the view so the rules are testable.
struct MealsSelection: Equatable {
    private(set) var picked: [String: Int] = [:]
    private(set) var offsets: [String: Int] = [:]
    var nights: Int

    init(plan: DeckMealsPlan) {
        nights = plan.nights
    }

    func pick(in slot: DeckMealSlot) -> DeckMealCandidate {
        slot.candidates[min(picked[slot.id] ?? 0, slot.candidates.count - 1)]
    }

    /// Up to two other candidates for a night, skipping what any shown night has picked; ↻ moves on.
    func alternatives(in slot: DeckMealSlot, plan: DeckMealsPlan) -> [DeckMealCandidate] {
        let taken = Set(shown(plan).map { pick(in: $0).dish })
        let others = slot.candidates.filter { !taken.contains($0.dish) }
        guard !others.isEmpty else { return [] }
        let start = (offsets[slot.id] ?? 0) % others.count
        return (0..<min(2, others.count)).map { others[(start + $0) % others.count] }
    }

    func canShuffle(_ slot: DeckMealSlot, plan: DeckMealsPlan) -> Bool {
        let taken = Set(shown(plan).map { pick(in: $0).dish })
        return slot.candidates.filter { !taken.contains($0.dish) }.count > 2
    }

    mutating func choose(_ candidate: DeckMealCandidate, in slot: DeckMealSlot) {
        guard let index = slot.candidates.firstIndex(of: candidate) else { return }
        picked[slot.id] = index
    }

    mutating func shuffle(_ slot: DeckMealSlot) {
        offsets[slot.id, default: 0] += 2
    }

    func shown(_ plan: DeckMealsPlan) -> [DeckMealSlot] {
        Array(plan.slots.prefix(nights))
    }

    func request(_ plan: DeckMealsPlan) -> MealsAcceptRequest {
        var seen = Set<String>()
        let picks = shown(plan).map { pick(in: $0) }.filter { seen.insert($0.dish).inserted }
        return MealsAcceptRequest(week: plan.week, picks: picks.map { .init(dish: $0.dish, veg: $0.veg) },
                                  backup: plan.backup?.dish)
    }
}

/// The Sunday "This week's dinners" card: each night's pick with two alternatives and ↻ for more,
/// how many nights, then Accept, which saves the week and sends the groceries to Reminders on the
/// Mac (`MealsPlanModel`). Once accepted it shows what was saved, with Change to reopen it.
struct DeckMealsCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @Environment(MealsPlanModel.self) private var model: MealsPlanModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: MealsSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: card.title ?? "This week's dinners")
                .font(AppFont.display(style: .title2, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 30)
            if let plan = card.meals, let model {
                if let week = model.accepted(plan.week) {
                    accepted(week, model: model)
                } else {
                    editor(plan, model: model)
                }
            } else if let fallback = card.fallback {
                Text(verbatim: fallback).font(AppFont.body()).padding(.top, 12)
            }
        }
        .task(id: card.meals?.week) {
            guard let week = card.meals?.week, let model, model.weeks[week] == nil, !model.unplanned.contains(week)
            else { return }
            await model.load(week: week)
        }
    }

    // MARK: Editing

    @ViewBuilder
    private func editor(_ plan: DeckMealsPlan, model: MealsPlanModel) -> some View {
        let current = selection ?? MealsSelection(plan: plan)
        Text(verbatim: "\(card.question ?? "Next week") · \(plan.servings) servings each")
            .font(AppFont.subheadline())
            .foregroundStyle(palette.colors.secondaryInk)
            .padding(.top, 4)
        nightsStepper(plan, current: current)
            .padding(.top, 16)
        ForEach(Array(current.shown(plan).enumerated()), id: \.element.id) { index, slot in
            if index > 0 { Divider().overlay(palette.edge).padding(.vertical, 12) } else { Spacer().frame(height: 16) }
            night(slot, plan: plan, current: current)
        }
        if let backup = plan.backup {
            Text(verbatim: "Backup: \(backup.name)").font(AppFont.subheadline()).padding(.top, 18)
        }
        if !plan.onHand.isEmpty {
            Text(verbatim: "On hand: \(plan.onHand.joined(separator: ", "))")
                .font(AppFont.subheadline())
                .foregroundStyle(palette.colors.secondaryInk)
                .padding(.top, 6)
        }
        Button {
            Task {
                if await model.accept(current.request(plan)) { viewModel.markAccepted(card) }
            }
        } label: {
            HStack(spacing: 8) {
                if model.pending { ProgressView().tint(palette.onInk) }
                Text(verbatim: model.pending ? "Saving…" : "Accept and send groceries")
            }
            .font(AppFont.body(weight: .semibold))
            .foregroundStyle(palette.onInk)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(palette.ink, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.pending)
        .padding(.top, 22)
        if let error = model.error {
            Text(verbatim: error).font(AppFont.footnote()).foregroundStyle(Color.hxDanger).padding(.top, 10)
        }
        DeckFootnote(card: card, palette: palette)
    }

    private func nightsStepper(_ plan: DeckMealsPlan, current: MealsSelection) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(current.nights) dinners").font(AppFont.subheadline(weight: .semibold))
            Spacer(minLength: 8)
            ChoiceButton(title: "−", isSelected: false, compact: true) { setNights(current.nights - 1, plan) }
                .disabled(current.nights <= plan.minNights)
                .accessibilityLabel(Text(verbatim: "One fewer dinner"))
            ChoiceButton(title: "+", isSelected: false, compact: true) { setNights(current.nights + 1, plan) }
                .disabled(current.nights >= plan.maxNights)
                .accessibilityLabel(Text(verbatim: "One more dinner"))
        }
    }

    @ViewBuilder
    private func night(_ slot: DeckMealSlot, plan: DeckMealsPlan, current: MealsSelection) -> some View {
        let pick = current.pick(in: slot)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: pick.name).font(AppFont.headline())
                if let tag = pick.tag {
                    Text(verbatim: tag.capitalized(with: nil))
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(palette.ink)
                }
            }
            if !pick.veg.isEmpty {
                Text(verbatim: pick.veg.joined(separator: ", ")).font(AppFont.subheadline())
            }
            if let why = pick.why {
                Text(verbatim: why).font(AppFont.caption()).foregroundStyle(palette.colors.secondaryInk)
            }
        }
        .accessibilityElement(children: .combine)
        let others = current.alternatives(in: slot, plan: plan)
        if !others.isEmpty {
            FlowRow(spacing: 8) {
                ForEach(others) { candidate in
                    ChoiceButton(title: candidate.name, isSelected: false) {
                        change { $0.choose(candidate, in: slot) }
                    }
                    .accessibilityHint(Text(verbatim: "Makes this the dinner instead of \(pick.name)"))
                }
                if current.canShuffle(slot, plan: plan) {
                    ChoiceButton(title: "↻", isSelected: false, compact: true) { change { $0.shuffle(slot) } }
                        .accessibilityLabel(Text(verbatim: "Other ideas"))
                }
            }
            .padding(.top, 10)
        }
    }

    private func setNights(_ value: Int, _ plan: DeckMealsPlan) {
        change { $0.nights = min(max(value, plan.minNights), plan.maxNights) }
    }

    private func change(_ edit: (inout MealsSelection) -> Void) {
        guard let plan = card.meals else { return }
        var next = selection ?? MealsSelection(plan: plan)
        edit(&next)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { selection = next }
    }

    // MARK: Accepted

    @ViewBuilder
    private func accepted(_ week: MealsWeek, model: MealsPlanModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(week.picks.enumerated()), id: \.offset) { _, pick in
                Text(verbatim: pick.veg.isEmpty ? pick.name : "\(pick.name) — \(pick.veg.joined(separator: ", "))")
                    .font(AppFont.body())
            }
        }
        .padding(.top, 14)
        if let error = week.remindersError {
            Text(verbatim: "Saved, but the grocery list didn't reach Reminders: \(error)")
                .font(AppFont.footnote()).foregroundStyle(Color.hxDanger).padding(.top, 14)
        } else if let line = week.groceryLine {
            Label { Text(verbatim: "In Reminders: \(line)") } icon: { Image(systemName: "checklist") }
                .font(AppFont.subheadline(weight: .semibold))
                .padding(.top, 14)
        }
        if !week.prep.isEmpty {
            Text(verbatim: "Prep").font(AppFont.subheadline(weight: .semibold)).padding(.top, 16)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(week.prep.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: "· \(line)").font(AppFont.subheadline())
                }
            }
            .padding(.top, 4)
        }
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { model.reopen(week.week) }
        } label: {
            Label { Text(verbatim: "Change the plan") } icon: { Image(systemName: "arrow.uturn.backward") }
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(palette.ink)
        }
        .buttonStyle(.plain)
        .padding(.top, 18)
        DeckFootnote(card: card, palette: palette)
    }
}
