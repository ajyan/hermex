import SwiftUI

/// Writing or editing a dish's recipe: its name, main or side, the servings it's written for,
/// ingredients and steps one per line, and when to bring it back. Saves only when the server
/// takes it; a failed save keeps the sheet open with his words.
struct MealsRecipeEditor: View {
    let recipe: MealsRecipe
    let viewModel: MealsDishViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var side: Bool
    @State private var serves: Int
    @State private var ingredients: String
    @State private var steps: String
    @State private var seasons: Set<String>
    @State private var occasions: String

    init(recipe: MealsRecipe, viewModel: MealsDishViewModel) {
        self.recipe = recipe
        self.viewModel = viewModel
        _name = State(initialValue: recipe.name)
        _side = State(initialValue: recipe.isSide)
        _serves = State(initialValue: recipe.serves)
        _ingredients = State(initialValue: (recipe.lines.isEmpty ? recipe.ingredients.map(MealsCopy.line) : recipe.lines)
            .joined(separator: "\n"))
        _steps = State(initialValue: recipe.steps.joined(separator: "\n"))
        _seasons = State(initialValue: Set(recipe.seasons))
        _occasions = State(initialValue: recipe.occasions.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $name) { Text(verbatim: "Name") }
                    Picker(selection: $side) {
                        Text(verbatim: "Main").tag(false)
                        Text(verbatim: "Side").tag(true)
                    } label: { Text(verbatim: "It's a") }
                    .pickerStyle(.segmented)
                    Stepper(value: $serves, in: 1...48) {
                        Text(verbatim: "Written for \(serves) servings")
                    }
                }
                Section {
                    TextEditor(text: $ingredients)
                        .font(AppFont.subheadline())
                        .frame(minHeight: 160)
                        .accessibilityLabel(Text(verbatim: "Ingredients"))
                } header: {
                    Text(verbatim: "Ingredients")
                } footer: {
                    Text(verbatim: "One per line, amount first, for \(serves) servings: 1 1/2 lb pork riblets.")
                }
                Section {
                    TextEditor(text: $steps)
                        .font(AppFont.subheadline())
                        .frame(minHeight: 200)
                        .accessibilityLabel(Text(verbatim: "Steps"))
                } header: {
                    Text(verbatim: "Steps")
                } footer: {
                    Text(verbatim: "One step per line.")
                }
                Section {
                    FlowRow(spacing: 8) {
                        ForEach(MealsCopy.seasons, id: \.self) { season in
                            Button {
                                if seasons.contains(season) { seasons.remove(season) } else { seasons.insert(season) }
                            } label: {
                                BrainTagChip(tag: season.capitalized, selected: seasons.contains(season))
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    TextField(text: $occasions) { Text(verbatim: "Occasions, like New Year's Eve") }
                } header: {
                    Text(verbatim: "Bring it back")
                } footer: {
                    Text(verbatim: "No season means any time.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(Text(verbatim: recipe.hasRecipe ? "Edit recipe" : "Write the recipe"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Cancel") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { if await viewModel.save(request) { dismiss() } }
                    } label: { Text(verbatim: "Save") }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isSaving)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error = viewModel.saveError {
                    Text(verbatim: error)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxDanger)
                        .padding(8)
                }
            }
            .hxKeyboardDoneButton()
        }
        .interactiveDismissDisabled(viewModel.isSaving)
    }

    var request: MealsRecipeEditRequest {
        MealsRecipeEditRequest(
            slug: recipe.slug,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: side ? "side" : "main",
            serves: serves,
            seasons: MealsCopy.seasons.filter(seasons.contains),
            occasions: occasions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            ingredients: MealsCopy.lines(ingredients),
            steps: MealsCopy.lines(steps)
        )
    }
}

extension MealsCopy {
    /// An ingredient as he'd write it, for editing: "1 1/2 lb pork riblets".
    static func line(_ ingredient: MealsIngredient) -> String {
        guard let amount = MealsScale.amount(ingredient, factor: 1) else { return ingredient.item }
        return "\(asciiFractions(amount)) \(ingredient.item)"
    }

    /// The non-empty lines of a text box.
    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// "2⅔" → "2 2/3", which the vault parses back.
    static func asciiFractions(_ text: String) -> String {
        let glyphs = ["⅛": "1/8", "¼": "1/4", "⅓": "1/3", "⅜": "3/8", "½": "1/2", "⅝": "5/8", "⅔": "2/3",
                      "¾": "3/4", "⅞": "7/8"]
        var out = ""
        for character in text {
            if let ascii = glyphs[String(character)] {
                if let last = out.last, last.isNumber { out += " " }
                out += ascii
            } else {
                out.append(character)
            }
        }
        return out.replacingOccurrences(of: "–", with: "-")
    }
}
