import Foundation

/// The Meals screen's week (`GET /api/meals/home?day=`, `api/vault_meals.py` over the vault's
/// `tools/meals.py`): seven days Monday to Sunday, each with its planned night and what was
/// logged, plus tonight and tomorrow's prep. Snake_case keys are matched literally
/// (`PrepDecoding`); every field a server might drop decodes to an empty default.
struct MealsHome: Decodable, Equatable {
    /// The phone's local day the server answered for (YYYY-MM-DD).
    let day: String
    /// The week's Monday.
    let week: String
    let days: [MealsDay]
    let tonight: MealsNight?
    let tonightLogged: Bool
    /// Tomorrow's dishes' prep lines, "Dish: step".
    let tomorrowPrep: [String]
    /// Occasions in the next two weeks that a dish is tagged for.
    let occasions: [MealsOccasion]
    /// What he ate this week a year ago.
    let yearAgo: [MealsSeasonPick]

    enum CodingKeys: String, CodingKey {
        case day, week, days, tonight, occasions
        case tonightLogged = "tonight_logged"
        case tomorrowPrep = "tomorrow_prep"
        case yearAgo = "year_ago"
    }

    init(day: String, week: String, days: [MealsDay], tonight: MealsNight?, tonightLogged: Bool,
         tomorrowPrep: [String], occasions: [MealsOccasion] = [], yearAgo: [MealsSeasonPick] = []) {
        self.day = day
        self.week = week
        self.days = days
        self.tonight = tonight
        self.tonightLogged = tonightLogged
        self.tomorrowPrep = tomorrowPrep
        self.occasions = occasions
        self.yearAgo = yearAgo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        week = try c.decode(String.self, forKey: .week)
        days = (try? c.decode([PrepLossy<MealsDay>].self, forKey: .days))?.compactMap(\.value) ?? []
        tonight = try? c.decodeIfPresent(MealsNight.self, forKey: .tonight)
        tonightLogged = (try? c.decodeIfPresent(Bool.self, forKey: .tonightLogged)) ?? false
        tomorrowPrep = (try? c.decodeIfPresent([String].self, forKey: .tomorrowPrep)) ?? []
        occasions = (try? c.decode([PrepLossy<MealsOccasion>].self, forKey: .occasions))?.compactMap(\.value) ?? []
        yearAgo = (try? c.decode([PrepLossy<MealsSeasonPick>].self, forKey: .yearAgo))?.compactMap(\.value) ?? []
    }

    var today: MealsDay? { days.first { $0.day == day } }
}

struct MealsDay: Decodable, Equatable, Identifiable {
    let day: String
    let night: MealsNight?
    let logged: MealsLogged?

    var id: String { day }

    init(day: String, night: MealsNight?, logged: MealsLogged?) {
        self.day = day
        self.night = night
        self.logged = logged
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        night = try? c.decodeIfPresent(MealsNight.self, forKey: .night)
        logged = try? c.decodeIfPresent(MealsLogged.self, forKey: .logged)
    }

    private enum CodingKeys: String, CodingKey { case day, night, logged }
}

/// One planned meal: the main first, then its sides, all at `servings`.
struct MealsNight: Decodable, Equatable {
    let day: String?
    let servings: Int
    let dishes: [MealsDish]

    init(day: String?, servings: Int, dishes: [MealsDish]) {
        self.day = day
        self.servings = servings
        self.dishes = dishes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try? c.decodeIfPresent(String.self, forKey: .day)
        servings = (try? c.decodeIfPresent(Int.self, forKey: .servings)) ?? MealsCopy.defaultServings
        dishes = (try? c.decode([PrepLossy<MealsDish>].self, forKey: .dishes))?.compactMap(\.value) ?? []
    }

    private enum CodingKeys: String, CodingKey { case day, servings, dishes }

    var main: MealsDish? { dishes.first }
    var sides: [MealsDish] { Array(dishes.dropFirst()) }
}

/// A dish in the library. A side (tomato egg, miso soup) is a dish of its own.
struct MealsDish: Decodable, Equatable, Hashable, Identifiable {
    let slug: String
    let name: String
    let kind: String
    let source: String?
    let hasRecipe: Bool
    let ingredients: [String]

    var id: String { slug }
    var isSide: Bool { kind == "side" }

    enum CodingKeys: String, CodingKey {
        case slug, name, kind, source, ingredients
        case hasRecipe = "has_recipe"
    }

    init(slug: String, name: String, kind: String = "main", source: String? = nil, hasRecipe: Bool = false,
         ingredients: [String] = []) {
        self.slug = slug
        self.name = name
        self.kind = kind
        self.source = source
        self.hasRecipe = hasRecipe
        self.ingredients = ingredients
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? slug
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "main"
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        hasRecipe = (try? c.decodeIfPresent(Bool.self, forKey: .hasRecipe)) ?? false
        ingredients = (try? c.decodeIfPresent([String].self, forKey: .ingredients)) ?? []
    }
}

/// What was logged for a day: the dishes eaten, or a night out.
struct MealsLogged: Decodable, Equatable {
    let out: Bool
    let dishes: [MealsLoggedDish]

    init(out: Bool, dishes: [MealsLoggedDish]) {
        self.out = out
        self.dishes = dishes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        out = (try? c.decodeIfPresent(Bool.self, forKey: .out)) ?? false
        dishes = (try? c.decode([PrepLossy<MealsLoggedDish>].self, forKey: .dishes))?.compactMap(\.value) ?? []
    }

    private enum CodingKeys: String, CodingKey { case out, dishes }
}

struct MealsLoggedDish: Decodable, Equatable {
    let slug: String?
    let name: String
    /// 1 thumbs up, -1 thumbs down.
    let rating: Int?
}

// MARK: Requests

/// `POST /api/meals/nights`: the week's nights, replacing what's saved. `today` is the phone's
/// local day, which the answered home is for.
struct MealsNightsRequest: Encodable, Equatable {
    let week: String
    let today: String
    let nights: [MealsNightBody]
}

struct MealsNightBody: Encodable, Equatable {
    let day: String
    var dishes: [String]
    var servings: Int
}

/// `POST /api/meals/log`: every dish eaten on `day`, main first. Logging a day again replaces it.
struct MealsLogRequest: Encodable, Equatable {
    let day: String
    let today: String
    /// Left out of the body when nil.
    let servings: Int?
    let dishes: [MealsLogDish]

    /// Not eaten after all: no dishes, so the server keeps nothing logged for `day`. The fork's
    /// `vault_meals.log` must accept an empty `dishes` for this (it answers 400 until it does), and
    /// `meals.log_night` then drops the day's non-estimated history rows, as logging again does.
    static func notEaten(day: String, today: String) -> MealsLogRequest {
        MealsLogRequest(day: day, today: today, servings: nil, dishes: [])
    }
}

struct MealsLogDish: Encodable, Equatable {
    let dish: String
    var rating: Int?
    var note: String?
}

struct MealsNewDishRequest: Encodable, Equatable {
    let name: String
    let kind: String
}

// MARK: Copy

enum MealsCopy {
    /// A dinner is two adults plus one lunch the next day.
    static let defaultServings = 3
    static let servingsChoices = [2, 3, 4, 6, 8, 10, 12]

    /// The phone's local calendar day, as the server's dates are written.
    static func localDay(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func formatted(_ day: String, _ format: String) -> String {
        guard let date = date(day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// "Tue"
    static func weekday(_ day: String) -> String { formatted(day, "EEE") }
    /// "Tuesday"
    static func weekdayName(_ day: String) -> String { formatted(day, "EEEE") }
    /// "3"
    static func dayNumber(_ day: String) -> String { formatted(day, "d") }
    /// "Tue, Nov 3"
    static func short(_ day: String) -> String { formatted(day, "EEE, MMM d") }

    static func serves(_ servings: Int) -> String? {
        servings == defaultServings ? nil : "Serves \(servings)"
    }

    /// "Hamachi collar · Tomato egg" for a row's line under its main.
    static func sidesLine(_ night: MealsNight) -> String? {
        let sides = night.sides.map(\.name)
        return sides.isEmpty ? nil : sides.joined(separator: " · ")
    }
}
