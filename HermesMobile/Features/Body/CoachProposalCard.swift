import SwiftUI

/// Baki's suggestion, drawn the same wherever one waits for an answer, with the same three actions:
/// Use, Not now, and Ask (a new chat about it). `.card` is the training-paper card on the finish
/// screen (`BodyProposalCards`): the change as its title, a Why list, and the rule that raised it.
/// `.compact` sits inside another card (Baki's card on Body home, the Sunday review's training card):
/// the change and its reasons, in that card's `paper`. `ask` is nil where no chat can open, which
/// hides Ask; `canDecide` false (a review without the Body API) leaves the buttons off.
struct CoachProposalCard: View {
    enum Style { case card, compact }

    /// The buttons, in order. Use is the primary.
    enum Action: Hashable {
        case use, notNow, ask

        var label: String {
            switch self {
            case .use: "Use"
            case .notNow: "Not now"
            case .ask: "Ask"
            }
        }

        func accessibilityLabel(_ title: String) -> String {
            self == .ask ? "Ask Baki about: \(title)" : "\(label): \(title)"
        }
    }

    static func actions(canDecide: Bool, canAsk: Bool) -> [Action] {
        (canDecide ? [.use, .notNow] : []) + (canAsk ? [.ask] : [])
    }

    let proposal: BodyProposal
    var style: Style = .card
    var paper: HermexPaper = .training
    var isBusy = false
    var canDecide = true
    let use: () -> Void
    let notNow: () -> Void
    let ask: (() -> Void)?

    private var actions: [Action] { Self.actions(canDecide: canDecide, canAsk: ask != nil) }

    var body: some View {
        switch style {
        case .card: card
        case .compact: compact
        }
    }

    private var card: some View {
        HXCard(.glow(paper), spacing: 10) {
            BodyCoachKicker(text: "Baki suggests")
        } content: {
            Text(verbatim: proposal.title)
                .font(AppFont.display(style: .title2, weight: .bold))
                .foregroundStyle(paper.glow)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !proposal.why.isEmpty { why }
            if !proposal.rule.isEmpty {
                Text(verbatim: proposal.rule)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            buttons.padding(.top, 4)
        }
    }

    private var compact: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Baki suggests")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(paper.glow)
            Text(verbatim: proposal.title)
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(proposal.why.enumerated()), id: \.offset) { _, reason in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "•").accessibilityHidden(true)
                    Text(verbatim: reason).fixedSize(horizontal: false, vertical: true)
                }
                .font(AppFont.footnote())
                .foregroundStyle(paper.secondaryInk)
            }
            if !actions.isEmpty { buttons.padding(.top, 4) }
        }
    }

    private var why: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Why")
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
            ForEach(Array(proposal.why.enumerated()), id: \.offset) { _, reason in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "•").accessibilityHidden(true)
                    Text(verbatim: reason).fixedSize(horizontal: false, vertical: true)
                }
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextPrimary)
            }
        }
    }

    /// Side by side when they fit; stacked at large text sizes.
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons }
            VStack(spacing: 8) { actionButtons }
        }
        .environment(\.hxPaper, paper)
        .disabled(isBusy)
    }

    private var actionButtons: some View {
        ForEach(actions, id: \.self) { action in
            Button { perform(action) } label: { Text(verbatim: action.label).bodyTapHeight() }
                .buttonStyle(ChatDecisionButtonStyle(emphasis: action == .use ? .primary : .secondary))
                .accessibilityLabel(Text(verbatim: action.accessibilityLabel(proposal.title)))
        }
    }

    private func perform(_ action: Action) {
        switch action {
        case .use: use()
        case .notNow: notNow()
        case .ask: ask?()
        }
    }
}

extension View {
    /// Lifts a `ChatDecisionButtonStyle` label to a 44 pt button. The style adds 9 pt above and below
    /// its label and a 40 pt floor, so a 26 pt label is 44 pt tall in all.
    func bodyTapHeight() -> some View { frame(minHeight: 26) }

    /// The same, at 50 pt: a screen's or card's one full-width action (DESIGN.md § Buttons).
    func bodyPrimaryHeight() -> some View { frame(minHeight: 32) }
}

/// Baki's note as he wrote it: the headline in the training glow, then his paragraphs. It sits on
/// his wash card on Body home, the finish screen and a past session.
struct BakiNoteText: View {
    let note: BodyCoachNote

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !note.headline.isEmpty {
                Text(verbatim: note.headline)
                    .font(AppFont.display(style: .headline, weight: .semibold))
                    .foregroundStyle(HermexPaper.training.glow)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(note.body.enumerated()), id: \.offset) { _, paragraph in
                Text(verbatim: paragraph)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The last row of Baki's card: opens a new chat with `draft` in the composer. Draws nothing when
/// no chat can open.
struct BakiAskRow: View {
    var title = "Ask Baki"
    var draft = BodyAskBaki.draft
    @Environment(\.openDraftChat) private var openDraftChat

    var body: some View {
        if openDraftChat.isAvailable {
            Button { openDraftChat(draft) } label: {
                HStack(spacing: 8) {
                    Text(verbatim: title)
                        .font(AppFont.body())
                        .foregroundStyle(HermexPaper.training.glow)
                    Spacer(minLength: 8)
                    BodyChevron()
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(verbatim: "Starts a chat with Baki"))
        }
    }
}

/// The hairline between the parts of Baki's card.
struct BakiRule: View {
    var body: some View {
        Rectangle().fill(HermexPaper.training.edge).frame(height: 0.5).accessibilityHidden(true)
    }
}

/// The trailing mark on every Body row that opens another screen.
struct BodyChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(Color.hxTextSecondary)
            .accessibilityHidden(true)
    }
}

/// What "Ask Baki" starts a chat with: the composer is filled in, never sent.
enum BodyAskBaki {
    /// The general opener: "Baki, ".
    static let draft = "Baki, "

    /// An opener about one proposal: `Baki, about "Strict press: 70 lb for 3 × 8": `.
    static func draft(about title: String) -> String { "Baki, about \"\(title)\": " }

    /// An opener about one workout: `Baki, about Pull on Mon, Nov 9: `.
    static func draft(aboutSession label: String, date: String) -> String { "Baki, about \(label) on \(date): " }
}

/// Baki's pending proposals as cards, one after another. Use and Not now go to `decide`; Ask opens
/// a new chat with the composer filled in, and is left off when no chat can open.
struct BodyProposalCards: View {
    let proposals: [BodyProposal]
    var deciding: Set<String> = []
    /// Why the last decision didn't take, shown under the cards.
    var error: String?
    let decide: (BodyProposal, Bool) -> Void

    @Environment(\.openDraftChat) private var openDraftChat

    var body: some View {
        if !proposals.isEmpty || error != nil {
            VStack(alignment: .leading, spacing: BrainStyle.m) {
                ForEach(proposals) { proposal in
                    CoachProposalCard(
                        proposal: proposal, isBusy: deciding.contains(proposal.id),
                        use: { decide(proposal, true) }, notNow: { decide(proposal, false) },
                        ask: openDraftChat.isAvailable
                            ? { openDraftChat(BodyAskBaki.draft(about: proposal.title)) } : nil)
                }
                if let error {
                    Text(verbatim: error)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxDanger)
                }
            }
        }
    }
}
