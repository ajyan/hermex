import SwiftUI

/// One card of the Daily Deck stack, on its own paper (`DeckPalette`). A card leads with its
/// quote or takeaway in large serif type and scrolls into the rest: context, the question,
/// and your reflection. Writing happens in `ReflectionSheet`, so a card never holds a text
/// field and long text never fights the swipe.
struct DeckPageView: View {
    let page: DeckPage
    let viewModel: DailyDeckViewModel
    let file: () -> Void
    /// Cards under the top one show only their paper; their words fade in as they rise.
    var contentOpacity: Double = 1

    static let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    var body: some View {
        let palette = DeckPalette.of(page)
        Group {
            switch page {
            case .card(let card):
                DeckCardView(card: card, palette: palette, viewModel: viewModel, file: file)
            case .followUps(let cards):
                FollowUpsPage(cards: cards, viewModel: viewModel)
            }
        }
        .opacity(contentOpacity)
        .background(palette.paper, in: Self.shape)
        .clipShape(Self.shape)
        .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
        .padding(.vertical, 12)
    }
}

/// A single card: lead, attribution, detail, question, reflection.
private struct DeckCardView: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel
    let file: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isWriting = false
    @State private var overflows = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch card.type {
                case .headline: opener
                case .close: close
                default: reading
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.contentOffset.y > geometry.containerSize.height + 8
        } action: { _, more in
            overflows = more
        }
        .overlay(alignment: .bottom) { moreHint }
        .overlay(alignment: .topTrailing) {
            Image(systemName: palette.symbol)
                .font(.system(.body, weight: .medium))
                .foregroundStyle(palette.ink.opacity(0.35))
                .padding(18)
                .accessibilityHidden(true)
        }
        .foregroundStyle(palette.ink)
        .tint(palette.ink)
        .sheet(isPresented: $isWriting) {
            ReflectionSheet(card: card, palette: palette, viewModel: viewModel)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: palette.name))
    }

    // MARK: Reading cards

    @ViewBuilder
    private var reading: some View {
        let text = DeckCardText(card)
        if card.itemKind == "quote" {
            Image(systemName: "quote.opening")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(palette.ink.opacity(0.22))
                .padding(.bottom, 10)
                .accessibilityHidden(true)
        }
        if let lead = text.lead {
            Text(inlineMarkdown(lead))
                .font(leadFont(lead))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 30)
                .textSelection(.enabled)
        }
        if let attribution = text.attribution {
            Text(verbatim: attribution)
                .font(AppFont.subheadline(weight: .medium))
                .foregroundStyle(palette.ink.opacity(0.7))
                .padding(.top, 12)
        }
        if let detail = text.detail {
            Text(inlineMarkdown(detail))
                .font(AppFont.body())
                .lineSpacing(4)
                .foregroundStyle(palette.ink.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 22)
                .textSelection(.enabled)
        }
        if card.type != .prompt, let question = viewModel.question(for: card) {
            Text(verbatim: question)
                .font(AppFont.title3(weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 28)
                .id(question)
                .transition(reduceMotion ? .opacity : AnyTransition(.blurReplace))
        }
        if card.takesText { reflection.padding(.top, 16) }
        if let reason = card.reason {
            Text(verbatim: reason)
                .font(AppFont.footnote())
                .foregroundStyle(palette.ink.opacity(0.62))
                .padding(.top, 20)
        }
    }

    private func leadFont(_ lead: String) -> Font {
        let style: Font.TextStyle = card.itemKind == "quote" ? .title : lead.count > 220 ? .title3 : .title2
        return AppFont.serif(style: style)
    }

    /// Your words once written; until then, the way in.
    @ViewBuilder
    private var reflection: some View {
        if let text = viewModel.answer(for: card)?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button { isWriting = true } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: text)
                        .font(AppFont.body())
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Label { Text(verbatim: "Edit") } icon: { Image(systemName: "pencil") }
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(palette.ink.opacity(0.7))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "Your reflection: \(text). Edit"))
        } else {
            Button { isWriting = true } label: {
                Label { Text(verbatim: "Write a reflection") } icon: { Image(systemName: "square.and.pencil") }
                    .font(AppFont.body(weight: .semibold))
                    .foregroundStyle(palette.paper)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    /// A soft fade and arrow while there is more card below.
    @ViewBuilder
    private var moreHint: some View {
        if overflows {
            LinearGradient(colors: [palette.paper.opacity(0), palette.paper], startPoint: .top, endPoint: .bottom)
                .frame(height: 64)
                .overlay(alignment: .bottom) {
                    Image(systemName: "chevron.compact.down")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(palette.ink.opacity(0.45))
                        .padding(.bottom, 8)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    // MARK: Opener and close

    @ViewBuilder
    private var opener: some View {
        Text(verbatim: card.title ?? "Today")
            .font(AppFont.serif(style: .largeTitle))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, 24)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(card.lines, id: \.self) { line in
                Text(verbatim: line).font(AppFont.subheadline())
            }
        }
        .foregroundStyle(palette.ink.opacity(0.75))
        .padding(.top, 14)
        let ahead = viewModel.visiblePages.dropFirst().filter {
            if case .card(let c) = $0, c.type == .close { return false }
            return true
        }
        FlowRow(spacing: 8) {
            ForEach(Array(ahead.enumerated()), id: \.element.id) { _, page in
                let p = DeckPalette.of(page)
                Text(verbatim: p.name)
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(p.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(p.paper, in: Capsule())
                    .overlay(Capsule().stroke(p.ink.opacity(0.15), lineWidth: 0.5))
            }
        }
        .padding(.top, 28)
        .accessibilityElement(children: .combine)
        Text(verbatim: "\(ahead.count) cards · swipe to begin")
            .font(AppFont.footnote())
            .foregroundStyle(palette.ink.opacity(0.6))
            .padding(.top, 18)
    }

    @ViewBuilder
    private var close: some View {
        let count = viewModel.answeredCount
        let filed = viewModel.isFiled && !viewModel.hasChanges
        Text(verbatim: filed ? "Filed" : count == 1 ? "1 reflection" : "\(count) reflections")
            .font(AppFont.serif(style: .largeTitle))
        Text(verbatim: filed
             ? "In your journal. Edit any card and file again to update it."
             : viewModel.isFiled
             ? "Filing again updates the journal: changed answers replace what was filed, new ones are added, nothing is deleted."
             : count == 0
             ? "Nothing written yet. Swipe back to any card, or file the follow-ups you chose."
             : "Atlas writes them into today's journal and runs the follow-ups you chose.")
            .font(AppFont.body())
            .foregroundStyle(palette.ink.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
        if case .failed(let message) = viewModel.filing {
            Text(verbatim: message).font(AppFont.footnote()).foregroundStyle(Color.hxDanger).padding(.top, 12)
        }
        Button(action: file) {
            HStack {
                if viewModel.filing == .filing { ProgressView().tint(palette.paper) }
                Text(verbatim: viewModel.isFiled ? "File Changes" : "File It")
            }
            .font(AppFont.body(weight: .semibold))
            .foregroundStyle(palette.paper)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(palette.ink.opacity(filed ? 0.35 : 1), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.filing == .filing || !viewModel.hasChanges)
        .padding(.top, 28)
    }
}

/// Writing a reflection: the card's question pinned on its own paper, the whole sheet for words.
/// Text saves as you type, so closing the sheet any way keeps it.
private struct ReflectionSheet: View {
    let card: DeckCard
    let palette: DeckPalette
    let viewModel: DailyDeckViewModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: viewModel.question(for: card) ?? DeckCardText(card).lead ?? "Your thoughts")
                    .font(AppFont.serif(style: .title3))
                    .foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text)
                    .font(AppFont.body())
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(verbatim: "Write as much or as little as you like")
                                .font(AppFont.body())
                                .foregroundStyle(palette.ink.opacity(0.45))
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
            text = viewModel.answer(for: card)?.text ?? ""
            isFocused = true
        }
        .onChange(of: text) { _, new in viewModel.setText(new, for: card) }
        .presentationDragIndicator(.visible)
    }
}

/// Chips left to right, wrapping onto new rows.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Every follow-up on one page: each row shows what's open and its choices; choosing
/// Answer, Edit, or Draft opens a box for the words.
private struct FollowUpsPage: View {
    let cards: [DeckCard]
    let viewModel: DailyDeckViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: cards.count == 1 ? "1 follow-up" : "\(cards.count) follow-ups")
                    .font(AppFont.serif(style: .title))
                    .padding(.bottom, 20)
                ForEach(Array(cards.enumerated()), id: \.element.id) { offset, card in
                    if offset > 0 { Divider().padding(.vertical, 16) }
                    FollowUpRow(card: card, viewModel: viewModel)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(DeckPalette.followUps.ink)
    }
}

private struct FollowUpRow: View {
    let card: DeckCard
    let viewModel: DailyDeckViewModel

    var body: some View {
        let chosen = viewModel.answer(for: card)?.action
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: card.title ?? "Follow-up").font(AppFont.headline())
            if let body = card.body, body != card.title {
                Text(verbatim: body).font(AppFont.subheadline()).foregroundStyle(.secondary)
            }
            if let draft = card.draft, let text = draft.text {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Draft to \(draft.to ?? "them")\(draft.channel.map { " · \($0)" } ?? "")")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(verbatim: text).font(AppFont.body())
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            // Side by side when they fit; stacked at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons(chosen) }
                VStack(alignment: .leading, spacing: 8) { buttons(chosen) }
            }
            if let chosen, card.actions.first(where: { $0.id == chosen })?.takesText == true {
                AnswerBox(card: card, viewModel: viewModel, prompt: chosen == "edit" ? "Your version" : "Your answer", minHeight: 88)
            } else if chosen == "draft" {
                AnswerBox(card: card, viewModel: viewModel, prompt: "Anything to mention? (optional)", minHeight: 88)
            }
        }
    }

    private func buttons(_ chosen: String?) -> some View {
        ForEach(card.actions) { action in
            ChoiceButton(title: action.label, isSelected: chosen == action.id) {
                viewModel.choose(action, for: card)
            }
        }
    }
}

/// A writing area that takes the space it is offered (at least `minHeight`); tapping
/// anywhere in it puts the cursor in the text.
private struct AnswerBox: View {
    let card: DeckCard
    let viewModel: DailyDeckViewModel
    let prompt: String
    var minHeight: CGFloat = 180
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(text: textBinding, axis: .vertical) {
            Text(verbatim: prompt)
        }
        .focused($isFocused)
        .font(AppFont.body())
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { isFocused = true }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { viewModel.answer(for: card)?.text ?? "" },
            set: { viewModel.setText($0, for: card) }
        )
    }
}

/// Saved notes carry *emphasis* and **bold**; show it rather than the asterisks.
private func inlineMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}

/// A capsule toggle for follow-up choices.
private struct ChoiceButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .lineLimit(1)
                .font(AppFont.subheadline(weight: .medium))
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .foregroundStyle(isSelected ? Color.hxOnAccent : Color.primary)
                .background(isSelected ? Color.accentColor : Color.hxSurface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

