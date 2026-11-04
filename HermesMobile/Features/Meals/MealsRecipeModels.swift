import Foundation

/// A dish's page (`GET /api/meals/recipe?slug=`): the recipe as written for `serves`, which the app
/// scales to the night's servings, plus how often it was made, his notes, Atlas's proposed fix,
/// the fixes he accepted, and the dishes it's eaten with. Snake_case keys are matched literally
/// (`PrepDecoding`); anything a server might drop decodes to an empty default.
struct MealsRecipe: Decodable, Equatable {
    let slug: String
    let name: String
    let kind: String
    let status: String
    let source: String?
    /// The servings the ingredients are written for.
    let serves: Int
    let seasons: [String]
    let occasions: [String]
    let made: Int
    let last: String?
    let saved: String?
    let ingredients: [MealsIngredient]
    /// The ingredient lines as written, for editing.
    let lines: [String]
    let steps: [String]
    let notes: [MealsNote]
    let fix: MealsFix?
    let fixes: [MealsAppliedFix]
    let goesWith: [MealsPairing]

    var isSide: Bool { kind == "side" }
    var isWant: Bool { status == "want" }
    var hasRecipe: Bool { !steps.isEmpty || !ingredients.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case slug, name, kind, status, source, serves, seasons, occasions, made, last, saved, ingredients, lines, steps
        case notes, fix, fixes
        case goesWith = "goes_with"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? slug
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "main"
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "library"
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        serves = max(1, (try? c.decodeIfPresent(Int.self, forKey: .serves)) ?? MealsCopy.defaultServings)
        seasons = (try? c.decodeIfPresent([String].self, forKey: .seasons)) ?? []
        occasions = (try? c.decodeIfPresent([String].self, forKey: .occasions)) ?? []
        made = (try? c.decodeIfPresent(Int.self, forKey: .made)) ?? 0
        last = try? c.decodeIfPresent(String.self, forKey: .last)
        saved = try? c.decodeIfPresent(String.self, forKey: .saved)
        ingredients = (try? c.decode([PrepLossy<MealsIngredient>].self, forKey: .ingredients))?.compactMap(\.value) ?? []
        lines = (try? c.decodeIfPresent([String].self, forKey: .lines)) ?? []
        steps = (try? c.decodeIfPresent([String].self, forKey: .steps)) ?? []
        notes = (try? c.decode([PrepLossy<MealsNote>].self, forKey: .notes))?.compactMap(\.value) ?? []
        fix = try? c.decodeIfPresent(MealsFix.self, forKey: .fix)
        fixes = (try? c.decode([PrepLossy<MealsAppliedFix>].self, forKey: .fixes))?.compactMap(\.value) ?? []
        goesWith = (try? c.decode([PrepLossy<MealsPairing>].self, forKey: .goesWith))?.compactMap(\.value) ?? []
    }
}

/// An ingredient line as written, split so it scales: "1 1/2 lb pork belly, sliced" is
/// qty 1.5, unit "lb", item "pork belly, sliced". A line with no amount has no qty.
struct MealsIngredient: Decodable, Equatable {
    let qty: Double?
    let qtyTo: Double?
    let unit: String
    let item: String

    private enum CodingKeys: String, CodingKey {
        case qty, unit, item
        case qtyTo = "qty_to"
    }

    init(qty: Double?, qtyTo: Double? = nil, unit: String = "", item: String) {
        self.qty = qty
        self.qtyTo = qtyTo
        self.unit = unit
        self.item = item
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(String.self, forKey: .item)
        qty = try? c.decodeIfPresent(Double.self, forKey: .qty)
        qtyTo = try? c.decodeIfPresent(Double.self, forKey: .qtyTo)
        unit = (try? c.decodeIfPresent(String.self, forKey: .unit)) ?? ""
    }
}

struct MealsNote: Decodable, Equatable {
    let day: String?
    let text: String
}

/// Atlas's proposed change from his note: each change swaps one line of the recipe (an empty
/// `was` adds a line, an empty `now` removes one). Nothing changes until he taps Use this.
struct MealsFix: Decodable, Equatable {
    let day: String?
    let note: String
    let changes: [MealsFixChange]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try? c.decodeIfPresent(String.self, forKey: .day)
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
        changes = (try? c.decode([PrepLossy<MealsFixChange>].self, forKey: .changes))?.compactMap(\.value) ?? []
    }

    private enum CodingKeys: String, CodingKey { case day, note, changes }
}

struct MealsFixChange: Decodable, Equatable {
    let part: String
    let was: String
    let now: String
}

struct MealsAppliedFix: Decodable, Equatable {
    let day: String
    let note: String?
}

/// A dish eaten the same night: a main's usual sides, or a side's mains.
struct MealsPairing: Decodable, Equatable, Identifiable {
    let slug: String
    let name: String
    let count: Int
    var id: String { slug }
}

/// The recipe book (`GET /api/meals/book?day=`): every dish, plus this season's most made main,
/// go-to side and the dishes first made this season.
struct MealsBook: Decodable, Equatable {
    let day: String
    let season: MealsSeason
    let dishes: [MealsBookDish]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? ""
        season = (try? c.decodeIfPresent(MealsSeason.self, forKey: .season)) ?? MealsSeason()
        dishes = (try? c.decode([PrepLossy<MealsBookDish>].self, forKey: .dishes))?.compactMap(\.value) ?? []
    }

    private enum CodingKeys: String, CodingKey { case day, season, dishes }
}

struct MealsSeason: Decodable, Equatable {
    var name = ""
    var mostMade: MealsSeasonPick?
    var goToSide: MealsSeasonPick?
    var new: [MealsSeasonPick] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        mostMade = try? c.decodeIfPresent(MealsSeasonPick.self, forKey: .mostMade)
        goToSide = try? c.decodeIfPresent(MealsSeasonPick.self, forKey: .goToSide)
        new = (try? c.decode([PrepLossy<MealsSeasonPick>].self, forKey: .new))?.compactMap(\.value) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case name, new
        case mostMade = "most_made"
        case goToSide = "go_to_side"
    }

    /// "fall" from "Fall 2026", for "New this fall".
    var seasonWord: String { name.split(separator: " ").first.map { $0.lowercased() } ?? "season" }
}

struct MealsSeasonPick: Decodable, Equatable, Identifiable {
    let slug: String
    let name: String
    var count: Int?
    var id: String { slug }
}

struct MealsBookDish: Decodable, Equatable, Identifiable {
    let slug: String
    let name: String
    let kind: String
    let status: String
    let hasRecipe: Bool
    let made: Int
    let last: String?
    let seasons: [String]
    let occasions: [String]
    let saved: String?
    /// How many different dishes it was eaten with (a side's mains).
    let partners: Int

    var id: String { slug }
    var isSide: Bool { kind == "side" }
    var isWant: Bool { status == "want" }

    private enum CodingKeys: String, CodingKey {
        case slug, name, kind, status, made, last, seasons, occasions, saved, partners
        case hasRecipe = "has_recipe"
    }

    init(slug: String, name: String, kind: String = "main", status: String = "library", hasRecipe: Bool = false,
         made: Int = 0, last: String? = nil, seasons: [String] = [], occasions: [String] = [], saved: String? = nil,
         partners: Int = 0) {
        self.slug = slug
        self.name = name
        self.kind = kind
        self.status = status
        self.hasRecipe = hasRecipe
        self.made = made
        self.last = last
        self.seasons = seasons
        self.occasions = occasions
        self.saved = saved
        self.partners = partners
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? slug
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "main"
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "library"
        hasRecipe = (try? c.decodeIfPresent(Bool.self, forKey: .hasRecipe)) ?? false
        made = (try? c.decodeIfPresent(Int.self, forKey: .made)) ?? 0
        last = try? c.decodeIfPresent(String.self, forKey: .last)
        seasons = (try? c.decodeIfPresent([String].self, forKey: .seasons)) ?? []
        occasions = (try? c.decodeIfPresent([String].self, forKey: .occasions)) ?? []
        saved = try? c.decodeIfPresent(String.self, forKey: .saved)
        partners = (try? c.decodeIfPresent(Int.self, forKey: .partners)) ?? 0
    }
}

/// What saving a link would save (`POST /api/meals/link/preview`). `existing` is the library dish
/// of the same name, whose missing recipe the link then fills in.
struct MealsLinkPreview: Decodable, Equatable {
    let name: String
    let ingredients: [String]
    let steps: [String]
    let serves: Int?
    let source: String
    let existing: MealsSeasonPick?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        ingredients = (try? c.decodeIfPresent([String].self, forKey: .ingredients)) ?? []
        steps = (try? c.decodeIfPresent([String].self, forKey: .steps)) ?? []
        serves = try? c.decodeIfPresent(Int.self, forKey: .serves)
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? ""
        existing = try? c.decodeIfPresent(MealsSeasonPick.self, forKey: .existing)
    }

    private enum CodingKeys: String, CodingKey { case name, ingredients, steps, serves, source, existing }
}

// MARK: Requests

struct MealsURLRequest: Encodable, Equatable {
    let url: String
}

/// `POST /api/meals/link`: saves the recipe as written. `slug` fills in that dish's missing recipe;
/// `ateOn` also logs it into that night's dinner.
struct MealsLinkRequest: Encodable, Equatable {
    let url: String
    var slug: String?
    var kind: String
    var seasons: [String]
    var occasions: [String]
    var ateOn: String?
    let today: String
}

struct MealsFixRequest: Encodable, Equatable {
    let slug: String
    let use: Bool
    let today: String
}

/// `POST /api/meals/recipe`: his edits; fields left nil stay as they are.
struct MealsRecipeEditRequest: Encodable, Equatable {
    let slug: String
    var name: String?
    var kind: String?
    var serves: Int?
    var seasons: [String]?
    var occasions: [String]?
    var ingredients: [String]?
    var steps: [String]?
}

/// A dish page pushed over Meals: the dish, and the night it was opened from (its servings and
/// day), which the ingredients scale to.
struct MealsDishRoute: Hashable {
    let slug: String
    var servings: Int?
    var day: String?
}

// MARK: Scaling

enum MealsScale {
    private static let fractions: [(Double, String)] = [
        (0, ""), (1.0 / 8, "⅛"), (1.0 / 4, "¼"), (1.0 / 3, "⅓"), (3.0 / 8, "⅜"), (1.0 / 2, "½"),
        (5.0 / 8, "⅝"), (2.0 / 3, "⅔"), (3.0 / 4, "¾"), (7.0 / 8, "⅞"), (1, "")
    ]
    /// Units that read in the plural above one ("2 cups"); weights and spoons don't change.
    private static let countable: Set<String> = [
        "cup", "can", "jar", "block", "head", "bag", "pint", "quart", "clove", "slice", "link", "fillet", "piece",
        "stalk", "sprig", "container", "tub", "carton"
    ]

    /// "2⅔", "½", "10": the nearest eighth or third, never zero.
    static func amount(_ value: Double) -> String {
        let whole = value.rounded(.down)
        let rest = value - whole
        let nearest = fractions.min { abs($0.0 - rest) < abs($1.0 - rest) } ?? (0, "")
        if nearest.0 == 1 { return "\(Int(whole) + 1)" }
        if whole == 0 { return nearest.1.isEmpty ? "⅛" : nearest.1 }
        return "\(Int(whole))\(nearest.1)"
    }

    /// The amount column for a line at `factor` ("2⅔ tbsp", "2–3 cloves"), or nil when the line
    /// has no amount ("shichimi togarashi").
    static func amount(_ ingredient: MealsIngredient, factor: Double) -> String? {
        guard let qty = ingredient.qty else { return nil }
        let low = qty * factor
        var text = amount(low)
        var high = low
        if let to = ingredient.qtyTo {
            high = to * factor
            text += "–" + amount(high)
        }
        guard !ingredient.unit.isEmpty else { return text }
        let unit = high > 1 && countable.contains(ingredient.unit) ? ingredient.unit + "s" : ingredient.unit
        return "\(text) \(unit)"
    }

    /// "Tue's dinner · scaled from 3", "Scaled from 2", "Tue's dinner", or "As written".
    static func caption(servings: Int, serves: Int, day: String?) -> String {
        let night = day.map { "\(MealsCopy.weekday($0))'s dinner" }
        let scaled = servings == serves ? nil : "scaled from \(serves)"
        switch (night, scaled) {
        case let (night?, scaled?): return "\(night) · \(scaled)"
        case let (night?, nil): return night
        case let (nil, scaled?): return scaled.prefix(1).uppercased() + scaled.dropFirst()
        case (nil, nil): return "As written"
        }
    }
}

extension MealsCopy {
    static let seasons = ["spring", "summer", "fall", "winter"]
    /// Occasions offered when saving a recipe, beside any the library already uses.
    static let occasions = ["New Year's Eve"]

    /// "Made 6 times · last Oct 31 · fall and winter", "Saved Oct 25 · not cooked yet".
    static func madeLine(_ recipe: MealsRecipe) -> String {
        var parts: [String] = []
        if recipe.made == 0 {
            parts.append(recipe.saved.map { "Saved \(monthDay($0)) · not cooked yet" } ?? "Not cooked yet")
        } else {
            parts.append(recipe.made == 1 ? "Made once" : "Made \(recipe.made) times")
            if let last = recipe.last { parts.append("last \(monthDay(last))") }
        }
        if !recipe.seasons.isEmpty { parts.append(listed(recipe.seasons)) }
        return parts.joined(separator: " · ")
    }

    /// "Main · 6× · last Oct 31", "Side · 9× · with 5 mains", "Main · no recipe yet", "Saved Oct 25".
    static func bookLine(_ dish: MealsBookDish) -> String {
        if dish.isWant { return dish.saved.map { "Saved \(monthDay($0))" } ?? "Saved, not cooked yet" }
        var parts = [dish.isSide ? "Side" : "Main"]
        if dish.made > 0 { parts.append("\(dish.made)×") }
        if !dish.hasRecipe {
            parts.append("no recipe yet")
        } else if dish.isSide, dish.partners > 1 {
            parts.append("with \(dish.partners) mains")
        } else if let last = dish.last {
            parts.append("last \(monthDay(last))")
        }
        return parts.joined(separator: " · ")
    }

    /// "Your recipe · 1 change applied (Oct 12)", or where it came from.
    static func recipeFooter(_ recipe: MealsRecipe) -> String? {
        if let latest = recipe.fixes.last {
            let count = recipe.fixes.count == 1 ? "1 change" : "\(recipe.fixes.count) changes"
            return "Your recipe · \(count) applied (\(monthDay(latest.day)))"
        }
        if let host = recipe.source.flatMap({ URL(string: $0)?.host() }) {
            return "From \(host.replacingOccurrences(of: "www.", with: ""))"
        }
        return nil
    }

    /// "Oct 31"
    static func monthDay(_ day: String) -> String {
        guard let date = date(day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    /// "fall and winter", "spring, summer and fall"
    static func listed(_ words: [String]) -> String {
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + (words.last ?? "")
    }
}
