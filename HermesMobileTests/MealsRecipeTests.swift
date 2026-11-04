import XCTest
@testable import HermesMobile

private final class FakeRecipeClient: MealsRecipeClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _fixes: [MealsFixRequest] = []
    private var _edits: [MealsRecipeEditRequest] = []
    private var _links: [MealsLinkRequest] = []
    var recipeResult: Result<MealsRecipe, Error>
    var writeResult: Result<MealsRecipe, Error>
    var bookResult: Result<MealsBook, Error>
    var previewResult: Result<MealsLinkPreview, Error>

    init(recipe: MealsRecipe, book: MealsBook, preview: MealsLinkPreview) {
        recipeResult = .success(recipe)
        writeResult = .success(recipe)
        bookResult = .success(book)
        previewResult = .success(preview)
    }

    var calls: [String] { lock.withLock { _calls } }
    var fixes: [MealsFixRequest] { lock.withLock { _fixes } }
    var edits: [MealsRecipeEditRequest] { lock.withLock { _edits } }
    var links: [MealsLinkRequest] { lock.withLock { _links } }

    func book(day: String) async throws -> MealsBook {
        try lock.withLock { _calls.append("book \(day)"); return bookResult }.get()
    }

    func recipe(slug: String) async throws -> MealsRecipe {
        try lock.withLock { _calls.append("recipe \(slug)"); return recipeResult }.get()
    }

    func editRecipe(_ request: MealsRecipeEditRequest) async throws -> MealsRecipe {
        try lock.withLock { _calls.append("edit"); _edits.append(request); return writeResult }.get()
    }

    func answerFix(_ request: MealsFixRequest) async throws -> MealsRecipe {
        try lock.withLock { _calls.append("fix"); _fixes.append(request); return writeResult }.get()
    }

    func previewLink(url: String) async throws -> MealsLinkPreview {
        try lock.withLock { _calls.append("preview \(url)"); return previewResult }.get()
    }

    func saveLink(_ request: MealsLinkRequest) async throws -> MealsRecipe {
        try lock.withLock { _calls.append("link"); _links.append(request); return writeResult }.get()
    }
}

private enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Meals/\(name).json")
        return try Data(contentsOf: url)
    }

    static func recipe() throws -> MealsRecipe { try PrepDecoding.decode(MealsRecipe.self, from: data("recipe")) }
    static func book() throws -> MealsBook { try PrepDecoding.decode(MealsBook.self, from: data("book")) }
    static func preview(existing: Bool = false) throws -> MealsLinkPreview {
        let json = """
        {"name": "Miso Salmon", "ingredients": ["2 lb salmon"], "steps": ["Broil."], "serves": 6,
         "source": "https://cooking.example/miso-salmon",
         "existing": \(existing ? #"{"slug": "miso-salmon", "name": "Miso salmon"}"# : "null")}
        """
        return try PrepDecoding.decode(MealsLinkPreview.self, from: Data(json.utf8))
    }

    /// Nov 4, 2026, noon in New York.
    static let now = { ISO8601DateFormatter().date(from: "2026-11-04T17:00:00Z")! }
}

final class MealsRecipeModelTests: XCTestCase {
    func testDecodesTheServersDishPage() throws {
        let recipe = try Fixture.recipe()
        XCTAssertEqual(recipe.name, "Kabocha with pork riblets")
        XCTAssertEqual(recipe.serves, 3)
        XCTAssertEqual(recipe.made, 2)
        XCTAssertEqual(recipe.ingredients.count, 5)
        XCTAssertEqual(recipe.ingredients[3], MealsIngredient(qty: 2, qtyTo: 3, unit: "clove", item: "garlic"))
        XCTAssertNil(recipe.ingredients[4].qty)
        XCTAssertEqual(recipe.lines.first, "1 1/2 lb pork riblets")
        XCTAssertEqual(recipe.steps.count, 2)
        XCTAssertEqual(recipe.fix?.changes.map(\.part), ["ingredient", "step"])
        XCTAssertEqual(recipe.fix?.day, "2026-10-31")
        XCTAssertEqual(recipe.goesWith.first?.name, "Yu choy")
        XCTAssertEqual(recipe.goesWith.first?.count, 2)
        XCTAssertEqual(recipe.notes.last?.text, "More black beans, it needed 5 more minutes.")
        XCTAssertTrue(recipe.hasRecipe)
    }

    func testDecodesTheBookAndToleratesAThinDish() throws {
        let book = try Fixture.book()
        XCTAssertEqual(book.season.name, "Fall 2026")
        XCTAssertEqual(book.season.mostMade?.count, 2)
        XCTAssertEqual(book.season.goToSide?.slug, "yu-choy")
        XCTAssertEqual(book.season.seasonWord, "fall")
        XCTAssertEqual(book.dishes.map(\.slug), ["kabocha-with-pork-riblets", "tomato-egg", "yu-choy"])
        let thin = try PrepDecoding.decode(MealsRecipe.self, from: Data(#"{"slug":"galbijjim"}"#.utf8))
        XCTAssertEqual(thin.name, "galbijjim")
        XCTAssertEqual(thin.serves, 3)
        XCTAssertFalse(thin.hasRecipe)
        XCTAssertNil(thin.fix)
    }

    func testAmountsScaleToTheNearestEighthOrThird() {
        XCTAssertEqual(MealsScale.amount(8.0 / 3), "2⅔")
        XCTAssertEqual(MealsScale.amount(1.0 / 3), "⅓")
        XCTAssertEqual(MealsScale.amount(10), "10")
        XCTAssertEqual(MealsScale.amount(1.97), "2")
        XCTAssertEqual(MealsScale.amount(0.01), "⅛", "never zero")
        let beans = MealsIngredient(qty: 1, unit: "cup", item: "fermented black beans")
        XCTAssertEqual(MealsScale.amount(beans, factor: 8.0 / 3), "2⅔ cups")
        XCTAssertEqual(MealsScale.amount(beans, factor: 1), "1 cup")
        let garlic = MealsIngredient(qty: 2, qtyTo: 3, unit: "clove", item: "garlic")
        XCTAssertEqual(MealsScale.amount(garlic, factor: 2), "4–6 cloves")
        XCTAssertEqual(MealsScale.amount(MealsIngredient(qty: 1.5, unit: "lb", item: "riblets"), factor: 2), "3 lb")
        XCTAssertNil(MealsScale.amount(MealsIngredient(qty: nil, item: "scallions"), factor: 2))
    }

    func testCaptionsAndLines() throws {
        XCTAssertEqual(MealsScale.caption(servings: 8, serves: 3, day: "2026-11-07"), "Sat's dinner · scaled from 3")
        XCTAssertEqual(MealsScale.caption(servings: 6, serves: 3, day: nil), "Scaled from 3")
        XCTAssertEqual(MealsScale.caption(servings: 3, serves: 3, day: nil), "As written")
        let recipe = try Fixture.recipe()
        XCTAssertEqual(MealsCopy.madeLine(recipe), "Made 2 times · last Oct 31 · fall and winter")
        XCTAssertEqual(MealsCopy.bookLine(MealsBookDish(slug: "a", name: "A", made: 6, last: "2026-10-31", partners: 1)),
                       "Main · 6× · no recipe yet")
        XCTAssertEqual(MealsCopy.bookLine(MealsBookDish(slug: "t", name: "Tomato egg", kind: "side", hasRecipe: true,
                                                        made: 9, partners: 5)), "Side · 9× · with 5 mains")
        XCTAssertEqual(MealsCopy.bookLine(MealsBookDish(slug: "l", name: "Lion's head", status: "want",
                                                        saved: "2026-10-25")), "Saved Oct 25")
        XCTAssertEqual(MealsCopy.asciiFractions("2⅔ tbsp"), "2 2/3 tbsp")
        XCTAssertEqual(MealsCopy.asciiFractions("½–1 cup"), "1/2-1 cup")
        XCTAssertEqual(MealsCopy.lines("  a \n\n b\n"), ["a", "b"])
    }
}

@MainActor
final class MealsDishViewModelTests: XCTestCase {
    func testOpensAtTheNightsServingsOrTheRecipesOwn() async throws {
        let client = FakeRecipeClient(recipe: try Fixture.recipe(), book: try Fixture.book(),
                                      preview: try Fixture.preview())
        let fromNight = MealsDishViewModel(route: MealsDishRoute(slug: "kabocha-with-pork-riblets", servings: 8,
                                                                 day: "2026-11-07"), client: client)
        await fromNight.load()
        XCTAssertEqual(fromNight.servings, 8)
        XCTAssertEqual(fromNight.factor, 8.0 / 3, accuracy: 0.0001)
        let fromBook = MealsDishViewModel(route: MealsDishRoute(slug: "kabocha-with-pork-riblets"), client: client)
        await fromBook.load()
        XCTAssertEqual(fromBook.servings, 3)
        fromBook.setServings(0)
        XCTAssertEqual(fromBook.servings, 1)
        await fromBook.load()
        XCTAssertEqual(fromBook.servings, 1, "a reload keeps the servings he chose")
    }

    func testUseThisSendsTheAnswerAndShowsTheSavedRecipe() async throws {
        let client = FakeRecipeClient(recipe: try Fixture.recipe(), book: try Fixture.book(),
                                      preview: try Fixture.preview())
        let applied = try PrepDecoding.decode(MealsRecipe.self, from: Data(
            #"{"slug":"kabocha-with-pork-riblets","fixes":[{"day":"2026-11-04","note":"More black beans"}]}"#.utf8))
        client.writeResult = .success(applied)
        let vm = MealsDishViewModel(route: MealsDishRoute(slug: "kabocha-with-pork-riblets"), client: client,
                                    now: Fixture.now)
        await vm.load()
        await vm.answerFix(use: true)
        XCTAssertEqual(client.fixes, [MealsFixRequest(slug: "kabocha-with-pork-riblets", use: true, today: "2026-11-04")])
        guard case .loaded(let shown) = vm.state else { return XCTFail("not loaded") }
        XCTAssertNil(shown.fix)
        XCTAssertEqual(MealsCopy.recipeFooter(shown), "Your recipe · 1 change applied (Nov 4)")
    }

    func testAFailedEditKeepsTheRecipeAndSaysSo() async throws {
        let recipe = try Fixture.recipe()
        let client = FakeRecipeClient(recipe: recipe, book: try Fixture.book(), preview: try Fixture.preview())
        client.writeResult = .failure(APIError.http(statusCode: 400, body: #"{"error":"serves must be 1–48"}"#))
        let vm = MealsDishViewModel(route: MealsDishRoute(slug: recipe.slug), client: client)
        await vm.load()
        let saved = await vm.save(MealsRecipeEditRequest(slug: recipe.slug, serves: 0))
        XCTAssertFalse(saved)
        XCTAssertEqual(vm.saveError, "Couldn't save that. Try again.")
        XCTAssertEqual(vm.state, .loaded(recipe))
    }

    func testAMissingDishIsUnavailable() async throws {
        let client = FakeRecipeClient(recipe: try Fixture.recipe(), book: try Fixture.book(),
                                      preview: try Fixture.preview())
        client.recipeResult = .failure(APIError.http(statusCode: 404, body: nil))
        let vm = MealsDishViewModel(route: MealsDishRoute(slug: "nope"), client: client)
        await vm.load()
        XCTAssertEqual(vm.state, .unavailable)
    }
}

@MainActor
final class MealsBookViewModelTests: XCTestCase {
    private func book() throws -> MealsBook {
        let json = """
        {"day": "2026-11-04", "season": {"name": "Fall 2026"}, "dishes": [
         {"slug": "kabocha", "name": "Kabocha with pork riblets", "made": 6, "seasons": ["fall", "winter"], "has_recipe": true},
         {"slug": "beef-noodle-soup", "name": "Beef noodle soup", "made": 4, "seasons": ["fall"]},
         {"slug": "tomato-egg", "name": "Tomato egg", "kind": "side", "made": 9},
         {"slug": "lions-head", "name": "Lion's head", "status": "want", "saved": "2026-10-25", "seasons": ["fall"]},
         {"slug": "pork-orzo", "name": "Pork orzo soup", "status": "want", "saved": "2026-10-28"},
         {"slug": "soba", "name": "Toshikoshi soba", "occasions": ["New Year's Eve"]}]}
        """
        return try PrepDecoding.decode(MealsBook.self, from: Data(json.utf8))
    }

    func testFiltersAndSearch() async throws {
        let book = try book()
        let vm = MealsBookViewModel(client: FakeRecipeClient(recipe: try Fixture.recipe(), book: book,
                                                             preview: try Fixture.preview()))
        XCTAssertTrue(vm.isBrowsing)
        vm.filter = .sides
        XCTAssertEqual(vm.matches(in: book).map(\.slug), ["tomato-egg"])
        vm.filter = .want
        XCTAssertEqual(vm.matches(in: book).map(\.slug), ["lions-head", "pork-orzo"])
        vm.filter = .occasions
        XCTAssertEqual(vm.matches(in: book).map(\.slug), ["soba"])
        vm.filter = .mains
        vm.query = "soup"
        XCTAssertFalse(vm.isBrowsing)
        XCTAssertEqual(vm.matches(in: book).map(\.slug), ["beef-noodle-soup"], "a want dish isn't a main yet")
        vm.filter = .all
        vm.query = "SOUP orzo"
        XCTAssertEqual(vm.matches(in: book).map(\.slug), ["pork-orzo"])
    }

    func testGoodRightNowAndWantToTry() throws {
        let book = try book()
        XCTAssertEqual(MealsBookViewModel.inSeason(book).map(\.slug), ["kabocha", "beef-noodle-soup"])
        XCTAssertEqual(MealsBookViewModel.wantToTry(book).map(\.slug), ["pork-orzo", "lions-head"], "newest first")
    }
}

@MainActor
final class MealsLinkModelTests: XCTestCase {
    private func model(existing: Bool = false, fillsIn: MealsSeasonPick? = nil) throws
        -> (MealsLinkModel, FakeRecipeClient) {
        let client = FakeRecipeClient(recipe: try Fixture.recipe(), book: try Fixture.book(),
                                      preview: try Fixture.preview(existing: existing))
        return (MealsLinkModel(fillsIn: fillsIn, client: client, now: Fixture.now), client)
    }

    func testALinkWithoutASchemeGetsHttpsAndGarbageIsNotALink() throws {
        let (model, _) = try model()
        model.url = " justonecookbook.com/toshikoshi-soba "
        XCTAssertEqual(model.normalizedURL, "https://justonecookbook.com/toshikoshi-soba")
        model.url = "not a link"
        XCTAssertNil(model.normalizedURL)
        model.url = "ftp://x.example"
        XCTAssertNil(model.normalizedURL)
    }

    func testFindThenSaveEatenTonight() async throws {
        let (model, client) = try model()
        model.url = "cooking.example/miso-salmon"
        XCTAssertFalse(model.canSave)
        await model.findRecipe()
        await model.findRecipe()
        XCTAssertEqual(client.calls, ["preview https://cooking.example/miso-salmon"], "the same link isn't read twice")
        XCTAssertTrue(model.canSave)
        XCTAssertNil(model.target)
        model.side = true
        model.toggle(season: "winter")
        model.toggle(season: "fall")
        model.toggle(occasion: "New Year's Eve")
        model.ateTonight = true
        let saved = await model.save()
        XCTAssertNotNil(saved)
        XCTAssertEqual(client.links, [MealsLinkRequest(
            url: "https://cooking.example/miso-salmon", slug: nil, kind: "side", seasons: ["fall", "winter"],
            occasions: ["New Year's Eve"], ateOn: "2026-11-04", today: "2026-11-04")])
    }

    func testASameNamedDishOrTheOpeningDishIsFilledIn() async throws {
        let (named, namedClient) = try model(existing: true)
        named.url = "https://cooking.example/miso-salmon"
        await named.findRecipe()
        XCTAssertEqual(named.target?.slug, "miso-salmon")
        _ = await named.save()
        XCTAssertEqual(namedClient.links.first?.slug, "miso-salmon")
        let (opened, _) = try model(fillsIn: MealsSeasonPick(slug: "galbijjim", name: "Galbijjim"))
        XCTAssertEqual(opened.target?.slug, "galbijjim")
    }

    func testAPageWithoutARecipeSaysWhy() async throws {
        let (model, client) = try model()
        client.previewResult = .failure(APIError.http(
            statusCode: 400, body: #"{"error":"no recipe found on that page: paste the recipe or describe it"}"#))
        model.url = "https://youtube.example/v"
        await model.findRecipe()
        XCTAssertEqual(model.preview, .failed("No recipe found on that page: paste the recipe or describe it."))
        XCTAssertFalse(model.canSave)
    }
}
