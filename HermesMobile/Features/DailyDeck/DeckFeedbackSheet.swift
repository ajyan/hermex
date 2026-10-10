import SwiftUI

/// "Not for Me" on one card: say what's off, then skip it or ask for less like it, or
/// keep the card with a different question (the next one the brief wrote, or your own).
/// Skipping hands the feedback back to the stack, which drops the card once the sheet closes.
struct DeckFeedbackSheet: View {
    let card: DeckCard
    let viewModel: DailyDeckViewModel
    let onDismissCard: (DeckFeedback) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reasons: Set<String> = []
    @State private var note = ""
    @State private var isAskingOwn = false
    @State private var ownQuestion = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: "What's off about this card?")
                    .font(AppFont.headline())
                ChipFlow(spacing: 8) {
                    ForEach(DeckFeedback.reasons, id: \.id) { reason in
                        chip(reason.id, label: reason.label)
                    }
                }
                TextField(text: $note, axis: .vertical) { Text(verbatim: "Anything else? (optional)") }
                    .font(AppFont.body())
                    .lineLimit(1...4)
                    .padding(12)
                    .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(spacing: 0) {
                    if !card.altQuestions.isEmpty {
                        row("Regenerate Question", systemImage: "arrow.triangle.2.circlepath") {
                            dismiss()
                            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35)) {
                                viewModel.regenerateQuestion(for: card)
                            }
                        }
                        Divider()
                    }
                    row("Ask My Own Question", systemImage: "pencil") {
                        ownQuestion = viewModel.question(for: card) ?? ""
                        isAskingOwn = true
                    }
                }
                .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { verdictButtons }
                    VStack(spacing: 8) { verdictButtons }
                }
            }
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .alert(Text(verbatim: "Your Question"), isPresented: $isAskingOwn) {
            TextField(text: $ownQuestion) { Text(verbatim: "What do you want to answer?") }
            Button(role: .cancel) {} label: { Text(verbatim: "Cancel") }
            Button {
                viewModel.setOwnQuestion(ownQuestion, for: card)
                dismiss()
            } label: { Text(verbatim: "Use It") }
        } message: {
            Text(verbatim: "It replaces this card's question and is filed with your answer.")
        }
    }

    @ViewBuilder
    private var verdictButtons: some View {
        Button { send(.skip) } label: {
            Text(verbatim: "Skip Card").frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        Button { send(.less) } label: {
            Text(verbatim: "Less Like This").frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
    }

    private func send(_ verdict: DeckFeedback.Verdict) {
        let ordered = DeckFeedback.reasons.map(\.id).filter(reasons.contains)
        onDismissCard(DeckFeedback(verdict: verdict, reasons: ordered, note: note))
    }

    private func chip(_ id: String, label: String) -> some View {
        let isSelected = reasons.contains(id)
        return Button {
            if isSelected { reasons.remove(id) } else { reasons.insert(id) }
        } label: {
            Text(verbatim: label)
                .font(AppFont.subheadline(weight: .medium))
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .foregroundStyle(isSelected ? Color.hxOnAccent : Color.primary)
                .background(isSelected ? Color.accentColor : Color.hxSurface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(verbatim: title) } icon: { Image(systemName: systemImage) }
                .font(AppFont.body())
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }
}

/// Lays chips out left to right, wrapping to a new row when one won't fit.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
