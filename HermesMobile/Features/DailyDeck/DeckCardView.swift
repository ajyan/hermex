import SwiftUI

/// One swipe of the Daily Deck. Every page fills the screen; on cards that ask for
/// writing, the answer box takes the room left under the prompt. Content scrolls
/// inside the page so long text and large Dynamic Type never hide the controls.
struct DeckPageView: View {
    let page: DeckPage
    let viewModel: DailyDeckViewModel
    let file: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(minHeight: max(proxy.size.height - 24, 0), alignment: .top)
                    .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .card(let card):
            DeckCardView(card: card, viewModel: viewModel, file: file)
        case .followUps(let cards):
            FollowUpsPage(cards: cards, viewModel: viewModel)
        }
    }
}

/// A single card, as a full-height panel.
private struct DeckCardView: View {
    let card: DeckCard
    let viewModel: DailyDeckViewModel
    let file: () -> Void

    var body: some View {
        SectionCard(title: eyebrow) {
            VStack(alignment: .leading, spacing: 12) {
                cardBody
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var eyebrow: String? {
        switch card.type {
        case .headline: nil
        case .prompt: card.voice.map { "\($0) asks" } ?? "Journal"
        case .reflect: reflectLabel
        case .item: card.itemKind == "youtube" ? "New videos" : "From your library"
        case .decision: "Follow-up"
        case .close: "Done"
        case .unknown: nil
        }
    }

    private var reflectLabel: String {
        switch card.itemKind {
        case "book": "Book highlight"
        case "insight": "Insight"
        case "video": "Video"
        default: "From your library"
        }
    }

    @ViewBuilder
    private var cardBody: some View {
        switch card.type {
        case .headline:
            headline
        case .prompt:
            if let context = card.context {
                Text(inlineMarkdown(context)).font(AppFont.subheadline()).foregroundStyle(.secondary)
            }
            question
            AnswerBox(card: card, viewModel: viewModel, prompt: "Your answer")
        case .reflect:
            reflect
        case .item, .decision:
            titled
        case .close:
            close
        case .unknown:
            titled
            if let fallback = card.fallback { Text(verbatim: fallback).font(AppFont.body()) }
        }
    }

    // MARK: Pieces

    private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: card.title ?? "Today")
                .font(AppFont.title(weight: .semibold))
            ForEach(card.lines, id: \.self) { line in
                Text(verbatim: line).font(AppFont.body()).foregroundStyle(.secondary)
            }
            Text(verbatim: "\(viewModel.pages.count - 2) pages · swipe to start")
                .font(AppFont.footnote())
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var reflect: some View {
        if let title = card.title {
            Text(verbatim: title).font(AppFont.headline())
        }
        if let source = card.source, source != card.title {
            Text(verbatim: source).font(AppFont.footnote()).foregroundStyle(.secondary)
        }
        if let body = card.body {
            // The saved words themselves, set apart from the explanation.
            Text(inlineMarkdown(card.itemKind == "book" ? "“\(body)”" : body))
                .font(AppFont.body())
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2)
                }
                .textSelection(.enabled)
        }
        if let context = card.context {
            Text(inlineMarkdown(context)).font(AppFont.subheadline()).foregroundStyle(.secondary)
        }
        if let why = card.why {
            Text(verbatim: "Why you saved it: \(why)")
                .font(AppFont.footnote())
                .foregroundStyle(.secondary)
        }
        question
        AnswerBox(card: card, viewModel: viewModel, prompt: "Your thoughts")
    }

    @ViewBuilder
    private var question: some View {
        if let text = card.question {
            Text(verbatim: text).font(AppFont.headline())
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var titled: some View {
        if let title = card.title {
            Text(verbatim: title).font(AppFont.headline())
        }
        if let body = card.body {
            Text(verbatim: body).font(AppFont.body()).textSelection(.enabled)
        }
        if let source = card.source, source != card.title {
            Text(verbatim: source).font(AppFont.footnote()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var close: some View {
        let count = viewModel.answeredCount
        Text(verbatim: count == 0 ? "Nothing answered yet" : "\(count) answered")
            .font(AppFont.title3(weight: .semibold))
        Text(verbatim: "Filing sends your answers to today's session. Atlas writes them into the journal and runs the follow-ups you chose.")
            .font(AppFont.subheadline())
            .foregroundStyle(.secondary)
        if case .failed(let message) = viewModel.filing {
            Text(verbatim: message).font(AppFont.footnote()).foregroundStyle(Color.hxDanger)
        }
        Button(action: file) {
            HStack {
                if viewModel.filing == .filing { ProgressView().tint(Color.hxOnAccent) }
                Text(verbatim: "File It")
            }
            .font(AppFont.body(weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(viewModel.filing == .filing)
    }
}

/// Every follow-up on one page: each row shows what's open and its choices; choosing
/// Answer, Edit, or Draft opens a box for the words.
private struct FollowUpsPage: View {
    let cards: [DeckCard]
    let viewModel: DailyDeckViewModel

    var body: some View {
        SectionCard(title: "Follow-ups · \(cards.count)") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { offset, card in
                    if offset > 0 { Divider().padding(.vertical, 12) }
                    FollowUpRow(card: card, viewModel: viewModel)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
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
