import Foundation

/// Step 1 of the weekend planner (`GET /api/meals/plan/review?day=`): how the week before the
/// target went. Each day has a state for its dot; `needs` are the planned nights not logged (or
/// eaten out), each with what it defaults to by the weekend rule.
struct MealsPlanReview: Decodable, Equatable {
    let day: String
    /// The week reviewed (a Monday).
    let week: String
    /// The week the planner fills (a Monday).
    let target: String
    let days: [MealsReviewDay]
    let needs: [MealsReviewNight]
    /// The mains logged this week, for the dots card's line.
    let logged: [String]
    /// Dishes with a recipe fix waiting.
    let fixes: [MealsSeasonPick]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? ""
        week = try c.decode(String.self, forKey: .week)
        target = try c.decode(String.self, forKey: .target)
        days = (try? c.decode([PrepLossy<MealsReviewDay>].self, forKey: .days))?.compactMap(\.value) ?? []
        needs = (try? c.decode([PrepLossy<MealsReviewNight>].self, forKey: .needs))?.compactMap(\.value) ?? []
        logged = (try? c.decodeIfPresent([String].self, forKey: .logged)) ?? []
        fixes = (try? c.decode([PrepLossy<MealsSeasonPick>].self, forKey: .fixes))?.compactMap(\.value) ?? []
    }

    private enum CodingKeys: String, CodingKey { case day, week, target, days, needs, logged, fixes }
}

struct MealsReviewDay: Decodable, Equatable, Identifiable {
    let day: String
    /// logged · open · skipped · ahead · out · none
    let state: String
    var id: String { day }
}

struct MealsReviewNight: Decodable, Equatable, Identifiable {
    let day: String
    let servings: Int
    let dishes: [MealsSeasonPick]
    /// ate · skipped · out: what it defaults to.
    let choice: String
    let carry: Bool
    let reason: String
    var id: String { day }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        servings = (try? c.decodeIfPresent(Int.self, forKey: .servings)) ?? MealsCopy.defaultServings
        dishes = (try? c.decode([PrepLossy<MealsSeasonPick>].self, forKey: .dishes))?.compactMap(\.value) ?? []
        choice = (try? c.decodeIfPresent(String.self, forKey: .choice)) ?? "ate"
        carry = (try? c.decodeIfPresent(Bool.self, forKey: .carry)) ?? false
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case day, servings, dishes, choice, carry, reason }
}

/// Step 2 (`GET /api/meals/plan/left?target=`): what should still be around.
struct MealsLeftovers: Decodable, Equatable {
    let items: [MealsLeftover]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decode([PrepLossy<MealsLeftover>].self, forKey: .items))?.compactMap(\.value) ?? []
    }

    private enum CodingKeys: String, CodingKey { case items }
}

struct MealsLeftover: Decodable, Equatable {
    let text: String
    let why: String
    /// fridge · freezer
    let `where`: String
    let checked: Bool

    init(text: String, why: String, where place: String = "fridge", checked: Bool = true) {
        self.text = text
        self.why = why
        self.where = place
        self.checked = checked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        why = (try? c.decodeIfPresent(String.self, forKey: .why)) ?? ""
        self.where = (try? c.decodeIfPresent(String.self, forKey: .where)) ?? "fridge"
        checked = (try? c.decodeIfPresent(Bool.self, forKey: .checked)) ?? true
    }

    private enum CodingKeys: String, CodingKey { case text, why, `where`, checked }
}

/// Step 3 (`POST /api/meals/plan/start {target}`, which first places last week's carried meals):
/// the mains Atlas would suggest, best first, the sides each main is usually eaten with, what he
/// ate this time last year, and each dish's prep.
struct MealsSuggestions: Decodable, Equatable {
    let candidates: [MealsSuggestion]
    let sides: [String: [MealsSeasonPick]]
    let lastYear: [MealsSeasonPick]
    let prep: [String: [String]]
    /// The target week's occasions a dish is tagged for, by date.
    let occasions: [String: MealsOccasion]

    init(candidates: [MealsSuggestion] = [], sides: [String: [MealsSeasonPick]] = [:],
         lastYear: [MealsSeasonPick] = [], prep: [String: [String]] = [:], occasions: [String: MealsOccasion] = [:]) {
        self.candidates = candidates
        self.sides = sides
        self.lastYear = lastYear
        self.prep = prep
        self.occasions = occasions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        candidates = (try? c.decode([PrepLossy<MealsSuggestion>].self, forKey: .candidates))?.compactMap(\.value) ?? []
        sides = (try? c.decodeIfPresent([String: [MealsSeasonPick]].self, forKey: .sides)) ?? [:]
        lastYear = (try? c.decode([PrepLossy<MealsSeasonPick>].self, forKey: .lastYear))?.compactMap(\.value) ?? []
        prep = (try? c.decodeIfPresent([String: [String]].self, forKey: .prep)) ?? [:]
        occasions = (try? c.decodeIfPresent([String: MealsOccasion].self, forKey: .occasions)) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case candidates, sides, prep, occasions
        case lastYear = "last_year"
    }
}

struct MealsSuggestion: Decodable, Equatable, Identifiable {
    let slug: String
    let name: String
    let why: String?
    var id: String { slug }

    init(slug: String, name: String, why: String?) {
        self.slug = slug
        self.name = name
        self.why = why
    }

    var dish: MealsDish { MealsDish(slug: slug, name: name) }
}

/// Step 4 (`GET /api/meals/plan/groceries?target=`): the list by store, nights scaled away from 3,
/// and what's on hand that it skipped.
struct MealsGroceries: Decodable, Equatable {
    let dinners: Int
    let scaled: [String]
    let stores: [MealsStoreList]
    let have: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dinners = (try? c.decodeIfPresent(Int.self, forKey: .dinners)) ?? 0
        scaled = (try? c.decodeIfPresent([String].self, forKey: .scaled)) ?? []
        stores = (try? c.decode([PrepLossy<MealsStoreList>].self, forKey: .stores))?.compactMap(\.value) ?? []
        have = (try? c.decodeIfPresent([String].self, forKey: .have)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case dinners, scaled, stores, have }

    var itemCount: Int { stores.reduce(0) { $0 + $1.items.count } }
}

struct MealsStoreList: Decodable, Equatable, Identifiable {
    let store: String
    let items: [MealsGroceryItem]
    var id: String { store }
}

struct MealsGroceryItem: Decodable, Equatable {
    let item: String
    let amount: String
}

/// `POST /api/meals/plan/finish`: how many items went to each store, and what Reminders said.
struct MealsPlanFinish: Decodable, Equatable {
    let groceries: [String: Int]
    let reminders: Reminders?

    struct Reminders: Decodable, Equatable {
        let added: Int?
        let error: String?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groceries = (try? c.decodeIfPresent([String: Int].self, forKey: .groceries)) ?? [:]
        reminders = try? c.decodeIfPresent(Reminders.self, forKey: .reminders)
    }

    private enum CodingKeys: String, CodingKey { case groceries, reminders }
}

// MARK: Requests

struct MealsReviewRequest: Encodable, Equatable {
    let week: String
    let answers: [MealsReviewAnswer]
}

struct MealsReviewAnswer: Encodable, Equatable {
    let day: String
    var choice: String
    var carry: Bool
}

struct MealsLeftoversRequest: Encodable, Equatable {
    let items: [String]
}

struct MealsPlanTargetRequest: Encodable, Equatable {
    let target: String
}

struct MealsPlanFinishRequest: Encodable, Equatable {
    let target: String
    let reminders: Bool
}

/// The weekend planner's API on the same fork module.
protocol MealsPlanClient: Sendable {
    func review(day: String) async throws -> MealsPlanReview
    func finishReview(_ request: MealsReviewRequest) async throws
    func leftovers(target: String) async throws -> MealsLeftovers
    func saveLeftovers(_ items: [String]) async throws
    func start(target: String) async throws -> MealsSuggestions
    func groceries(target: String) async throws -> MealsGroceries
    func finish(_ request: MealsPlanFinishRequest) async throws -> MealsPlanFinish
}

extension APIClientMealsScreenAdapter: MealsPlanClient {
    func review(day: String) async throws -> MealsPlanReview {
        try PrepDecoding.decodeAPI(try await apiClient.sendData(endpoint: .mealsPlanReview(day: day), method: "GET"))
    }

    func finishReview(_ request: MealsReviewRequest) async throws {
        _ = try await apiClient.sendData(endpoint: .mealsPlanReviewSave, method: "POST", body: request)
    }

    func leftovers(target: String) async throws -> MealsLeftovers {
        try PrepDecoding.decodeAPI(try await apiClient.sendData(endpoint: .mealsPlanLeft(target: target), method: "GET"))
    }

    func saveLeftovers(_ items: [String]) async throws {
        _ = try await apiClient.sendData(endpoint: .mealsPlanLeftSave, method: "POST",
                                         body: MealsLeftoversRequest(items: items))
    }

    func start(target: String) async throws -> MealsSuggestions {
        // Ranking the library runs on the server; give it time.
        try PrepDecoding.decodeAPI(try await apiClient.sendData(
            endpoint: .mealsPlanStart, method: "POST", body: MealsPlanTargetRequest(target: target), timeout: 45))
    }

    func groceries(target: String) async throws -> MealsGroceries {
        try PrepDecoding.decodeAPI(try await apiClient.sendData(endpoint: .mealsPlanGroceries(target: target),
                                                                method: "GET"))
    }

    func finish(_ request: MealsPlanFinishRequest) async throws -> MealsPlanFinish {
        // Adding to Reminders runs AppleScript on the server's Mac.
        try PrepDecoding.decodeAPI(try await apiClient.sendData(endpoint: .mealsPlanFinish, method: "POST",
                                                                body: request, timeout: 90))
    }
}

extension PrepDecoding {
    /// Decodes a server answer, reporting a bad shape as `APIError.decoding`.
    static func decodeAPI<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try decode(Value.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }
}
