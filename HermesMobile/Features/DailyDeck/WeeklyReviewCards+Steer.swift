import SwiftUI

// The weekly review's last card before the seal: the note to the future.

/// A note that opens on this week next year.
struct WeekKeepsakesCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    /// The icon row's height, so the title sits the same under any glyph.
    @ScaledMetric(relativeTo: .title3) private var iconRow: CGFloat = 28
    @State private var isWritingNote = false

    var body: some View {
        let note = viewModel.answer(for: card)?.text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: 0) {
            WeekCardHeading(title: card.title ?? "Keepsakes", palette: palette)
            Text(verbatim: "Optional. The note opens on this week next year.")
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            noteTile(note).padding(.top, 18)
            DeckFootnote(card: card, palette: palette)
        }
        .sheet(isPresented: $isWritingNote) {
            WeekEditorSheet(title: "A note to you, a year from now", placeholder: "It opens on this week next year",
                            serif: true, palette: palette, initial: note ?? "") { viewModel.setText($0, for: card) }
        }
    }

    private func noteTile(_ note: String?) -> some View {
        Button { isWritingNote = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "envelope")
                        .font(AppFont.title3(weight: .semibold))
                        .foregroundStyle(palette.ink)
                    Spacer(minLength: 4)
                    if note != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(AppFont.body())
                            .foregroundStyle(palette.ink)
                    }
                }
                .frame(height: iconRow)
                Text(verbatim: "Note to the future")
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                Group {
                    if let note {
                        Text(verbatim: note)
                            .font(AppFont.serif(style: .footnote))
                            .foregroundStyle(Color.hxTextPrimary)
                            .lineLimit(4)
                    } else {
                        Text(verbatim: "Write to yourself a year from now")
                            .font(AppFont.footnote())
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .glowSurface(palette.colors, cornerRadius: HXRadius.lg, opaque: true)
            .contentShape(RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(verbatim: note != nil ? "Edits it" : "Opens an editor"))
    }
}
