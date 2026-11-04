import Foundation

/// The Meals screen's API on this user's `hermes-webui` fork (`api/vault_meals.py`). Every write
/// answers the whole week again, so the screen always shows what the server saved. Stock servers
/// answer 404, which the screen shows as "no Meals on this server". (The Daily Brief's plan card
/// keeps its own `MealsDataClient`.)
protocol MealsScreenClient: Sendable {
    func home(day: String) async throws -> MealsHome
    func dishes() async throws -> [MealsDish]
    func saveNights(_ request: MealsNightsRequest) async throws -> MealsHome
    func log(_ request: MealsLogRequest) async throws -> MealsHome
    func addDish(name: String, side: Bool) async throws -> MealsDish
}

struct APIClientMealsScreenAdapter: MealsScreenClient {
    let apiClient: APIClient

    func home(day: String) async throws -> MealsHome {
        try decode(try await apiClient.sendData(endpoint: .mealsHome(day: day), method: "GET"))
    }

    func dishes() async throws -> [MealsDish] {
        let rows: [PrepLossy<MealsDish>] = try decode(
            try await apiClient.sendData(endpoint: .mealsDishes, method: "GET"))
        return rows.compactMap(\.value)
    }

    func saveNights(_ request: MealsNightsRequest) async throws -> MealsHome {
        try decode(try await apiClient.sendData(endpoint: .mealsNights, method: "POST", body: request))
    }

    func log(_ request: MealsLogRequest) async throws -> MealsHome {
        try decode(try await apiClient.sendData(endpoint: .mealsLog, method: "POST", body: request))
    }

    func addDish(name: String, side: Bool) async throws -> MealsDish {
        try decode(try await apiClient.sendData(
            endpoint: .mealsDish, method: "POST", body: MealsNewDishRequest(name: name, kind: side ? "side" : "main")))
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try PrepDecoding.decode(Value.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }
}

/// Edits to a week, as the nights `POST /api/meals/nights` saves. Each starts from the week the
/// server last answered, so an edit never resurrects a night the server dropped.
enum MealsWeekEdit {
    static func nights(_ home: MealsHome) -> [MealsNightBody] {
        home.days.compactMap { day in
            guard let night = day.night, !night.dishes.isEmpty else { return nil }
            return MealsNightBody(day: day.day, dishes: night.dishes.map(\.slug), servings: night.servings)
        }
    }

    /// Moves `from`'s meal to `to`; a meal already on `to` takes `from`'s place.
    static func move(_ home: MealsHome, from: String, to: String) -> [MealsNightBody] {
        nights(home).map { night in
            var night = night
            if night.day == from { return MealsNightBody(day: to, dishes: night.dishes, servings: night.servings) }
            if night.day == to { night = MealsNightBody(day: from, dishes: night.dishes, servings: night.servings) }
            return night
        }
    }

    /// Adds `dish` to `day`'s meal: a main goes first, a side after the rest. A new night starts
    /// at the default servings.
    static func add(_ home: MealsHome, dish: MealsDish, to day: String) -> [MealsNightBody] {
        var all = nights(home)
        if let index = all.firstIndex(where: { $0.day == day }) {
            guard !all[index].dishes.contains(dish.slug) else { return all }
            if dish.isSide { all[index].dishes.append(dish.slug) } else { all[index].dishes.insert(dish.slug, at: 0) }
        } else {
            all.append(MealsNightBody(day: day, dishes: [dish.slug], servings: MealsCopy.defaultServings))
        }
        return all
    }

    /// Takes `slug` off `day`; the night goes when its last dish does.
    static func remove(_ home: MealsHome, slug: String, from day: String) -> [MealsNightBody] {
        nights(home).compactMap { night in
            guard night.day == day else { return night }
            var night = night
            night.dishes.removeAll { $0 == slug }
            return night.dishes.isEmpty ? nil : night
        }
    }

    static func clear(_ home: MealsHome, day: String) -> [MealsNightBody] {
        nights(home).filter { $0.day != day }
    }

    static func servings(_ home: MealsHome, day: String, to servings: Int) -> [MealsNightBody] {
        nights(home).map { night in
            guard night.day == day else { return night }
            var night = night
            night.servings = servings
            return night
        }
    }
}
