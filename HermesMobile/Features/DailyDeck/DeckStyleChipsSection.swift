import SwiftUI

/// The swipe-up sheet's "How it's written" chips for one deck card: one tap each, kept as the deck's style signals
/// (`DailyDeckViewModel.toggleStyle`) and filed with its answers for the vault's style learner.
struct DeckStyleChipsSection: View {
    let card: DeckCard
    let viewModel: DailyDeckViewModel

    var body: some View {
        Section {
            ChipFlow(spacing: 8) {
                ForEach(DeckStyleChip.allCases) { chip in
                    chipButton(chip)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.hxSurface)
        } header: {
            Text(verbatim: "How it's written")
        }
    }

    /// Keeps the sheet's note with the chips; only "Not my voice" files it, as the learned rule's words.
    func keepNote(_ text: String) {
        viewModel.setStyleNote(text, on: card)
    }

    private func chipButton(_ chip: DeckStyleChip) -> some View {
        let isSelected = viewModel.styleChips(on: card).contains(chip.rawValue)
        return Button {
            viewModel.toggleStyle(chip, on: card)
        } label: {
            Text(verbatim: chip.label)
                .font(AppFont.subheadline(weight: .medium))
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .foregroundStyle(isSelected ? Color.hxOnAccent : Color.primary)
                .background(isSelected ? Color.accentColor : Color.hxCanvas, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
