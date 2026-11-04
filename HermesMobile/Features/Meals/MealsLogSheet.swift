import SwiftUI

/// After Eating it: the night is already logged. Each dish can take a thumbs up or down and a
/// "change next time" note under it (a recipe fix, saved to the dish's notes). Done saves them;
/// with nothing added it just closes.
struct MealsLogSheet: View {
    @State var draft: MealsLogDraft
    let viewModel: MealsHomeViewModel
    @Environment(\.dismiss) private var dismiss

    private var paper: HermexPaper { .meal }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.l) {
                    header
                    ForEach($draft.dishes) { $item in
                        dishRow($item)
                    }
                    if let error = viewModel.saveError {
                        Text(verbatim: error)
                            .font(AppFont.footnote())
                            .foregroundStyle(Color.hxDanger)
                    }
                }
                .padding(BrainStyle.l)
            }
            .background(Color.hxCanvas.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { doneButton.padding(BrainStyle.l) }
            .scrollDismissesKeyboard(.interactively)
        }
        .presentationDetents([.large])
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(AppFont.headline(weight: .bold))
                .foregroundStyle(paper.glow)
                .frame(width: 44, height: 44)
                .glowSurface(paper, cornerRadius: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Logged · \(MealsCopy.short(draft.day))")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(paper.glow)
                Text(verbatim: "Enjoy dinner")
                    .font(AppFont.display(style: .title2, weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func dishRow(_ item: Binding<MealsLogDraft.Item>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(verbatim: item.wrappedValue.dish.name)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                Spacer(minLength: 8)
                thumb(item, value: 1, symbol: "hand.thumbsup", label: "Liked it")
                thumb(item, value: -1, symbol: "hand.thumbsdown", label: "Didn't like it")
            }
            TextField(text: item.note, axis: .vertical) { Text(verbatim: "Anything to change next time?") }
                .lineLimit(1...4)
                .font(AppFont.body())
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 44, alignment: .topLeading)
                .background(Color.hxCanvas, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous)
                    .strokeBorder(Color.hxSeparator, lineWidth: 0.5))
        }
        .padding(HXCard<EmptyView, EmptyView, EmptyView>.padding)
        .hxCard()
    }

    /// Tapping the chosen thumb again clears it.
    private func thumb(_ item: Binding<MealsLogDraft.Item>, value: Int, symbol: String, label: String) -> some View {
        let isSelected = item.wrappedValue.rating == value
        return Button { item.wrappedValue.rating = isSelected ? nil : value } label: {
            Image(systemName: isSelected ? "\(symbol).fill" : symbol)
                .frame(width: 24)
        }
        .buttonStyle(ChatDecisionButtonStyle(emphasis: isSelected ? .primary : .secondary))
        .frame(width: 60)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var doneButton: some View {
        Button {
            Task { if await viewModel.finishLog(draft) { dismiss() } }
        } label: {
            Group {
                if viewModel.isSaving { ProgressView() } else { Text(verbatim: "Done") }
            }
            .font(AppFont.display(style: .headline, weight: .semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(viewModel.isSaving)
    }
}
