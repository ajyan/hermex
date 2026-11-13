import SwiftUI

/// Add a recipe from a link: paste it, see what the server found (name, ingredients and steps,
/// the servings it's written for), say whether it's a main or a side and when to bring it back,
/// optionally log it with tonight's dinner, and save. Opened from the recipe book's plus, or from
/// a dish's page to fill in its missing recipe.
struct MealsAddLinkSheet: View {
    @State var model: MealsLinkModel
    let onSaved: (MealsRecipe) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var linkFocused: Bool

    private var paper: HermexPaper { .meal }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.l) {
                    linkField
                    found
                    if model.canSave {
                        if model.target == nil { kind }
                        bringItBack
                        ateTonight
                    }
                    if let error = model.saveError {
                        Text(verbatim: error)
                            .font(AppFont.footnote())
                            .foregroundStyle(Color.hxDanger)
                    }
                }
                .padding(BrainStyle.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.hxCanvas.ignoresSafeArea())
            .hxNavigationTitle(model.fillsIn == nil ? "Add a recipe" : "Add from a link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Cancel") }
                }
            }
            .safeAreaInset(edge: .bottom) { saveButton }
            .onAppear { if model.url.isEmpty { linkFocused = true } }
        }
        .interactiveDismissDisabled(model.isSaving)
    }

    private var linkField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Link")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(Color.hxTextSecondary)
                .padding(.horizontal, 4)
            HStack(spacing: 8) {
                TextField(text: $model.url) { Text(verbatim: "Paste a recipe link") }
                    .font(AppFont.subheadline())
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($linkFocused)
                    .onSubmit { Task { await model.findRecipe() } }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous)
                        .strokeBorder(Color.hxSeparator, lineWidth: 0.5))
                PasteButton(payloadType: URL.self) { urls in
                    guard let first = urls.first else { return }
                    model.url = first.absoluteString
                    Task { await model.findRecipe() }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
            }
            if model.normalizedURL != nil, model.preview == .idle {
                Button { Task { await model.findRecipe() } } label: {
                    Text(verbatim: "Find the recipe")
                        .font(AppFont.subheadline(weight: .semibold))
                        .frame(minHeight: 44)
                }
            }
        }
    }

    @ViewBuilder
    private var found: some View {
        switch model.preview {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text(verbatim: "Reading the page…")
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: message)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextPrimary)
                Text(verbatim: "Videos and posts usually have no recipe on the page. Tell Atlas how you make it instead.")
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .found(let preview):
            HXCard(.glow(paper), title: preview.name.isEmpty ? "A recipe" : preview.name, titleStyle: .title3) {
                Text(verbatim: MealsCopy.foundOn(preview.source))
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(paper.glow)
            } content: {
                VStack(alignment: .leading, spacing: 6) {
                    check(MealsCopy.foundWhat(preview))
                    check(preview.serves.map { "Serves \($0) as written, scaled when you cook it" }
                          ?? "No servings on the page: saved as 3")
                    if let target = model.target {
                        check("Fills in your \(target.name)")
                    }
                }
                Text(verbatim: "Not quite right? Edit it after saving, or tell Atlas how you make it.")
                    .font(AppFont.footnote())
                    .foregroundStyle(paper.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            } footer: {
                EmptyView()
            }
        }
    }

    private func check(_ text: String) -> some View {
        Label {
            Text(verbatim: text)
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark")
                .font(AppFont.caption(weight: .bold))
                .foregroundStyle(paper.glow)
        }
    }

    private var kind: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("It's a")
            HStack(spacing: 8) {
                chip("Main", selected: !model.side) { model.side = false }
                chip("Side", selected: model.side) { model.side = true }
            }
        }
    }

    private var bringItBack: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Bring it back")
            FlowRow(spacing: 8) {
                ForEach(MealsCopy.occasions, id: \.self) { occasion in
                    chip(occasion, selected: model.occasions.contains(occasion)) { model.toggle(occasion: occasion) }
                }
                ForEach(MealsCopy.seasons, id: \.self) { season in
                    chip(season.capitalized, selected: model.seasons.contains(season)) { model.toggle(season: season) }
                }
                chip("Any time", selected: model.seasons.isEmpty) { model.seasons = [] }
            }
        }
    }

    private var ateTonight: some View {
        VStack(alignment: .leading, spacing: 6) {
            chip("We ate it tonight", selected: model.ateTonight, symbol: model.ateTonight ? "checkmark" : nil) {
                model.ateTonight.toggle()
            }
            if model.ateTonight {
                Text(verbatim: "Logs it with dinner on \(MealsCopy.short(model.today)).")
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var saveButton: some View {
        Button {
            Task {
                if let saved = await model.save() { onSaved(saved) }
            }
        } label: {
            Group {
                if model.isSaving { ProgressView().tint(Color.hxOnAccent) } else {
                    Text(verbatim: model.target == nil ? "Save to Recipes" : "Save the recipe")
                }
            }
            .bodyPrimaryHeight()
        }
        .buttonStyle(ChatDecisionButtonStyle(emphasis: .primary))
        .disabled(!model.canSave)
        .padding(.horizontal, BrainStyle.l)
        .padding(.bottom, 8)
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text)
            .font(AppFont.footnote(weight: .semibold))
            .foregroundStyle(Color.hxTextSecondary)
            .padding(.horizontal, 4)
    }

    private func chip(_ title: String, selected: Bool, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            BrainTagChip(tag: symbol == nil ? title : "✓ \(title)", selected: selected)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension MealsCopy {
    /// "Found on justonecookbook.com"
    static func foundOn(_ source: String) -> String {
        guard let host = URL(string: source)?.host() else { return "Found it" }
        return "Found on \(host.replacingOccurrences(of: "www.", with: ""))"
    }

    /// "12 ingredients and 8 steps", or what's missing.
    static func foundWhat(_ preview: MealsLinkPreview) -> String {
        let ingredients = preview.ingredients.count == 1 ? "1 ingredient" : "\(preview.ingredients.count) ingredients"
        let steps = preview.steps.count == 1 ? "1 step" : "\(preview.steps.count) steps"
        switch (preview.ingredients.isEmpty, preview.steps.isEmpty) {
        case (false, false): return "\(ingredients) and \(steps)"
        case (false, true): return "\(ingredients), no steps"
        case (true, false): return "\(steps), no ingredients"
        case (true, true): return "No ingredients or steps on the page"
        }
    }
}
