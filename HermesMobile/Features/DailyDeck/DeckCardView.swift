import SwiftUI

/// One Daily Deck card. Content scrolls inside the card so long briefs and large
/// Dynamic Type never push the controls off screen.
struct DeckCardView: View {
    let card: DeckCard
    let viewModel: DailyDeckViewModel
    let file: () -> Void

    var body: some View {
        ScrollView {
            SectionCard(title: eyebrow) {
                VStack(alignment: .leading, spacing: 12) {
                    cardBody
                }
            }
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
    }

    private var eyebrow: String? {
        switch card.type {
        case .headline: nil
        case .prompt: card.voice.map { "\($0) asks" } ?? "Journal"
        case .decision: "Follow-up"
        case .reflect: "Reflect"
        case .item: itemLabel
        case .close: "Done"
        case .unknown: nil
        }
    }

    private var itemLabel: String {
        switch card.itemKind {
        case "book": "Book highlight"
        case "insight": "Insight"
        case "video": "Video"
        case "youtube": "New videos"
        case "media": "From your library"
        default: "Item"
        }
    }

    @ViewBuilder
    private var cardBody: some View {
        switch card.type {
        case .headline:
            headline
        case .prompt:
            if let context = card.context { CollapsibleText(text: context) }
            question(card.question)
            answerField(prompt: "Your answer")
        case .reflect:
            titled
            if let why = card.why {
                Text(verbatim: "Why it mattered: \(why)").font(AppFont.subheadline()).foregroundStyle(.secondary)
            }
            question(card.question)
            answerField(prompt: "What do you think now?")
        case .decision:
            decision
        case .item:
            titled
            reactions
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
            Text(verbatim: "\(viewModel.cards.count - 2) cards · swipe to start")
                .font(AppFont.footnote())
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var titled: some View {
        if let title = card.title {
            Text(verbatim: title).font(AppFont.headline())
        }
        if let body = card.body {
            Text(verbatim: card.itemKind == "book" ? "“\(body)”" : body)
                .font(AppFont.body())
                .textSelection(.enabled)
        }
        if let source = card.source, source != card.title {
            Text(verbatim: source).font(AppFont.footnote()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func question(_ text: String?) -> some View {
        if let text {
            Text(verbatim: text).font(AppFont.headline())
        }
    }

    private func answerField(prompt: String) -> some View {
        TextField(text: textBinding, axis: .vertical) {
            Text(verbatim: prompt)
        }
        .lineLimit(3...10)
        .font(AppFont.body())
        .padding(10)
        .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { viewModel.answer(for: card)?.text ?? "" },
            set: { viewModel.setText($0, for: card) }
        )
    }

    @ViewBuilder
    private var decision: some View {
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
        let chosen = viewModel.answer(for: card)?.action
        // Side by side when they fit; stacked at large text sizes.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons(chosen) }
            VStack(alignment: .leading, spacing: 8) { actionButtons(chosen) }
        }
        if let chosen, card.actions.first(where: { $0.id == chosen })?.takesText == true {
            answerField(prompt: chosen == "edit" ? "Your version" : "Your answer")
        } else if chosen == "draft" {
            answerField(prompt: "Anything to mention? (optional)")
        }
    }

    private func actionButtons(_ chosen: String?) -> some View {
        ForEach(card.actions) { action in
            ChoiceButton(title: action.label, isSelected: chosen == action.id) {
                viewModel.choose(action, for: card)
            }
        }
    }

    private var reactions: some View {
        let reaction = viewModel.answer(for: card)?.reaction
        return HStack(spacing: 8) {
            ChoiceButton(title: "Resonates", systemImage: "sparkles", isSelected: reaction == .resonates) {
                viewModel.react(.resonates, for: card)
            }
            ChoiceButton(title: "Skip", isSelected: reaction == .skip) {
                viewModel.react(.skip, for: card)
            }
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

/// A capsule toggle for decisions and reactions.
private struct ChoiceButton: View {
    let title: String
    var systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
                Text(verbatim: title).lineLimit(1)
            }
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

/// Long advisor context, folded to a few lines until asked.
private struct CollapsibleText: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: text)
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 4)
            Button { isExpanded.toggle() } label: {
                Text(verbatim: isExpanded ? "Less" : "More").font(AppFont.footnote(weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }
}
