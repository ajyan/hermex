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

/// The small line over a weekly card's headline ("Last week you meant to", "People · 2 of 5"),
/// clear of the kind mark in the corner.
struct WeekKicker: View {
    let text: String
    let palette: DeckPalette

    @ScaledMetric(relativeTo: .body) private var clearance: CGFloat = 30

    var body: some View {
        Text(verbatim: text)
            .font(AppFont.footnote(weight: .semibold))
            .foregroundStyle(palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, clearance)
            .padding(.bottom, 8)
    }
}

/// His words on a weekly card, opened in `WeekEditorSheet` by a tap: an optional label over the
/// words in serif, or the placeholder until he writes some.
struct WeekWordsBox: View {
    var label: String?
    let text: String
    let placeholder: String
    let palette: DeckPalette
    let action: () -> Void

    var body: some View {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                if let label {
                    Text(verbatim: label)
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(palette.ink)
                }
                Text(verbatim: words.isEmpty ? placeholder : words)
                    .font(AppFont.serif(style: .subheadline))
                    .foregroundStyle(words.isEmpty ? Color.hxTextSecondary : Color.hxTextPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glowSurface(palette.colors, cornerRadius: HXRadius.md, opaque: true)
            .contentShape(RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: Self.spoken(label: label, words: words.isEmpty ? "Not written yet" : words)))
        .accessibilityHint(Text(verbatim: "Edits it"))
    }
}

extension WeekWordsBox {
    /// "Thread: Honesty"; a label that ends in its own punctuation ("What got in the way?") takes a space.
    static func spoken(label: String?, words: String) -> String {
        guard let label, !label.isEmpty else { return words }
        return label + (label.last.map { ".?!:".contains($0) } == true ? " " : ": ") + words
    }
}

/// A 1–10 score on ten segments, tapped to set; tapping the chosen score again clears it
/// (`DailyDeckViewModel.setScore`). One adjustable element for VoiceOver: "Present, 7 of 10".
struct WeekScoreRow: View {
    let title: String
    let score: Int?
    let palette: DeckPalette
    let set: (Int) -> Void

    @ScaledMetric(relativeTo: .body) private var segmentHeight: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(verbatim: score.map(String.init) ?? "–")
                    .font(AppFont.display(style: .headline, weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .monospacedDigit()
            }
            HStack(spacing: 4) {
                ForEach(1...10, id: \.self) { segment in
                    Button { set(segment) } label: {
                        Capsule()
                            .fill(segment <= (score ?? 0) ? palette.ink : Color.hxSeparator)
                            .frame(height: min(segmentHeight, 14))
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: score.map { "\($0) of 10" } ?? "Not scored"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if (score ?? 0) < 10 { set((score ?? 0) + 1) }
            case .decrement: if let score, score > 1 { set(score - 1) }
            @unknown default: break
            }
        }
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
/// closing it any way keeps them. `serif` for words he keeps (a value's line, the note).
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
        if card.isFuture { return card.thread != nil ? "Write back" : card.returns.isEmpty ? "Write it down" : "Write to future you" }
        if card.isPast { return "Write it down" }
        if card.isMandarin { return "Answer in Mandarin" }
        return card.id == "one-thing" ? "Write the one thing" : "Write a reflection"
    }

    /// The close card's heading: a sealed weekly review is sealed, other decks count their reflections.
    static func closeHeading(seal: Bool, filed: Bool, count: Int) -> String {
        if seal { return filed ? "Sealed" : "Seal the week" }
        return filed ? "Filed" : count == 1 ? "1 reflection" : "\(count) reflections"
    }

    /// Under the close heading once the deck is filed. The heading already says it worked, so this only says
    /// where the answers went; the server's own summary (count and journal path) stays out of the card.
    static func filedLine(seal: Bool) -> String {
        seal ? "Sealed in your journal." : "In your journal."
    }

    /// The header's word for a filed deck: a sealed weekly review is sealed; "Edited" once changed since.
    static func filedStatus(seal: Bool, edited: Bool) -> String {
        edited ? "Edited" : seal ? "Sealed" : "Filed"
    }

    /// Under a weekly review's close heading.
    static func answered(_ count: Int) -> String {
        count == 1 ? "1 card answered" : "\(count) cards answered"
    }
}
