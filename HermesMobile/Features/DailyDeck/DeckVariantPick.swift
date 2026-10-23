import SwiftUI

/// The close card's "Which reads better?": the day's variant card written two ways, one above the other from where
/// they differ (`DeckVariant.previews`), with no labels saying which is which. One tap picks a face, again clears it;
/// the pick is filed with the answers for the vault's style learner (`DailyDeckViewModel.choose`).
struct DeckVariantPick: View {
    let card: DeckCard
    let viewModel: DailyDeckViewModel
    let palette: DeckPalette

    var body: some View {
        if let variant = card.variant {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "Which reads better?")
                    .font(AppFont.headline())
                    .foregroundStyle(Color.hxTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: card.title ?? "Today's card, written two ways")
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
                let previews = variant.previews
                faceButton("a", previews.a)
                faceButton("b", previews.b)
                Text(verbatim: "Tap your pick again to clear it.")
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
            }
        }
    }

    private func faceButton(_ id: String, _ preview: String) -> some View {
        let isPicked = viewModel.signals.pick == DeckPick(card: card.id, chose: id)
        return Button {
            viewModel.choose(id, on: card)
        } label: {
            Text(verbatim: preview)
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous)
                        .strokeBorder(isPicked ? palette.ink : palette.edge, lineWidth: isPicked ? 2 : 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "Version \(id == "a" ? 1 : 2): \(preview)"))
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}
