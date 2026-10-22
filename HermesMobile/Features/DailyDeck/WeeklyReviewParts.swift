import SwiftUI

// Pieces the weekly review's cards share (`WeeklyReviewCards*.swift`).

/// The line at a card's foot: its weekly chapter ("1 · Remember"), else why the brief picked it.
struct DeckFootnote: View {
    let card: DeckCard
    let palette: DeckPalette

    var body: some View {
        if let line = card.chapterLabel ?? card.reason {
            Text(verbatim: line)
                .font(AppFont.footnote())
                .foregroundStyle(palette.ink)
                .padding(.top, 20)
        }
    }
}

/// A weekly card's headline, clear of the kind mark in the corner.
struct WeekCardHeading: View {
    let title: String
    let palette: DeckPalette

    /// Room for the corner mark, which grows with the text.
    @ScaledMetric(relativeTo: .body) private var clearance: CGFloat = 30

    var body: some View {
        Text(verbatim: title)
            .font(AppFont.display(style: .title2, weight: .semibold))
            .foregroundStyle(palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, clearance)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A hairline between rows, in the card's hue.
struct WeekHairline: View {
    let palette: DeckPalette

    var body: some View {
        Rectangle().fill(palette.ink.opacity(0.14)).frame(height: 0.5)
    }
}

/// A choice in the week's paper: the wash until chosen, then filled with the glow. The weekly
/// cards keep Nous blue for Begin, Seal, and Confirm, so their choices wear the card's hue.
struct WeekChoiceChip: View {
    let title: String
    var symbol: String?
    let isSelected: Bool
    let palette: DeckPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(AppFont.caption(weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(verbatim: title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(AppFont.subheadline(weight: .medium))
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .foregroundStyle(isSelected ? palette.onInk : palette.ink)
            .background(isSelected ? palette.ink : palette.colors.wash, in: Capsule())
            .overlay(Capsule().strokeBorder(palette.colors.edge, lineWidth: isSelected ? 0 : 0.5))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "+ add": a dashed chip that asks for one more.
struct WeekAddChip: View {
    let title: String
    let palette: DeckPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label { Text(verbatim: title) } icon: { Image(systemName: "plus") }
                .labelStyle(WeekTightLabelStyle())
                .font(AppFont.caption(weight: .medium))
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(palette.ink.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .frame(minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct WeekTightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(AppFont.caption2(weight: .bold))
            configuration.title
        }
    }
}

extension View {
    /// A small alert with one text field; `add` gets the trimmed words, never empty ones.
    func weekAddAlert(_ title: String, prompt: String, isPresented: Binding<Bool>,
                      add: @escaping (String) -> Void) -> some View {
        modifier(WeekAddAlert(title: title, prompt: prompt, isPresented: isPresented, add: add))
    }
}

private struct WeekAddAlert: ViewModifier {
    let title: String
    let prompt: String
    @Binding var isPresented: Bool
    let add: (String) -> Void
    @State private var text = ""

    func body(content: Content) -> some View {
        content.alert(Text(verbatim: title), isPresented: $isPresented) {
            TextField(text: $text) { Text(verbatim: prompt) }
            Button {
                let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = ""
                if !words.isEmpty { add(words) }
            } label: { Text(verbatim: "Add") }
            Button(role: .cancel) { text = "" } label: { Text(verbatim: "Cancel") }
        }
    }
}

/// Editing a weekly card's words: the whole sheet on the card's paper, saving as he types, so
/// closing it any way keeps them. `serif` for words he keeps (the story, evidence, the note).
struct WeekEditorSheet: View {
    let title: String
    /// A small line under the title saying what to write.
    var subtitle: String?
    let placeholder: String
    var serif = false
    let palette: DeckPalette
    let initial: String
    let save: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: title)
                        .font(AppFont.display(style: .title3, weight: .semibold))
                        .foregroundStyle(palette.ink)
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                TextEditor(text: $text)
                    .font(serif ? AppFont.serif(style: .body) : AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(verbatim: placeholder)
                                .font(serif ? AppFont.serif(style: .body) : AppFont.body())
                                .foregroundStyle(Color.hxTextSecondary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(palette.paper.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Done") }
                }
            }
            .toolbarBackground(palette.paper, for: .navigationBar)
        }
        .tint(palette.ink)
        .onAppear {
            text = initial
            isFocused = true
        }
        .onChange(of: text) { old, new in
            // Loading `initial` isn't an edit: opening and closing leaves Atlas's draft unanswered.
            if old.isEmpty && new == initial { return }
            save(new)
        }
        .presentationDragIndicator(.visible)
    }
}

/// Deck copy that depends on the card or the deck: the way into writing, and the close card's heading.
enum DeckCopy {
    /// The button that opens a card's writing sheet.
    static func invitation(for card: DeckCard) -> String {
        if card.isLetter { return "Write to her" }
        if card.isMandarin { return "Answer in Mandarin" }
        return card.id == "one-thing" ? "Write the one thing" : "Write a reflection"
    }

    /// The close card's heading: a v2 weekly review is sealed, other decks count their reflections.
    static func closeHeading(seal: Bool, filed: Bool, count: Int) -> String {
        if seal { return filed ? "Sealed" : "Seal the week" }
        return filed ? "Filed" : count == 1 ? "1 reflection" : "\(count) reflections"
    }

    /// The header's word for a filed deck: a v2 weekly review is sealed; "Edited" once changed since.
    static func filedStatus(seal: Bool, edited: Bool) -> String {
        edited ? "Edited" : seal ? "Sealed" : "Filed"
    }

    /// Under a weekly review's close heading.
    static func answered(_ count: Int) -> String {
        count == 1 ? "1 card answered" : "\(count) cards answered"
    }
}
