import SwiftUI

/// Picks a dish for a night: search the library, or type a name that isn't there and add it as a
/// new main or side with no recipe yet.
struct MealsDishPicker: View {
    let viewModel: MealsHomeViewModel
    /// "Tuesday", for the title.
    let dayLabel: String
    let onPick: (MealsDish) -> Void
    @State private var query = ""
    @State private var isCreating = false
    @Environment(\.dismiss) private var dismiss

    private var paper: HermexPaper { .meal }

    var body: some View {
        NavigationStack {
            List {
                if !trimmed.isEmpty, !hasExactMatch {
                    Section {
                        createButton(side: false)
                        createButton(side: true)
                    }
                }
                if let library = viewModel.library {
                    let mains = matches(library).filter { !$0.isSide }
                    let sides = matches(library).filter(\.isSide)
                    if !mains.isEmpty { Section("Mains") { ForEach(mains) { row($0) } } }
                    if !sides.isEmpty { Section("Sides") { ForEach(sides) { row($0) } } }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text(verbatim: "Search or add a dish"))
            .hxNavigationTitle("Add to \(dayLabel)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Cancel") }
                }
            }
            .task { await viewModel.loadLibrary() }
            .disabled(isCreating)
        }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var hasExactMatch: Bool {
        viewModel.library?.contains { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame } ?? false
    }

    private func matches(_ library: [MealsDish]) -> [MealsDish] {
        guard !trimmed.isEmpty else { return library }
        return library.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private func row(_ dish: MealsDish) -> some View {
        Button { onPick(dish) } label: {
            HStack(spacing: 12) {
                Image(systemName: dish.isSide ? "leaf" : "fork.knife")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(paper.glow)
                    .frame(width: 30, height: 30)
                    .background(paper.wash, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
                    .accessibilityHidden(true)
                Text(verbatim: dish.name)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                Spacer(minLength: 8)
                if !dish.hasRecipe {
                    Text(verbatim: "No recipe yet")
                        .font(AppFont.caption())
                        .foregroundStyle(Color.hxTextSecondary)
                }
            }
            .frame(minHeight: 44)
        }
    }

    private func createButton(side: Bool) -> some View {
        Button {
            isCreating = true
            Task {
                let dish = await viewModel.createDish(named: trimmed, side: side)
                isCreating = false
                if let dish { onPick(dish) }
            }
        } label: {
            Label {
                Text(verbatim: "Add “\(trimmed)” as a \(side ? "side" : "main")")
            } icon: {
                Image(systemName: "plus.circle.fill")
            }
            .frame(minHeight: 44)
        }
    }
}
