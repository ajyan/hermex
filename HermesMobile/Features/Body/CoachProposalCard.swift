import SwiftUI

/// Baki's suggestion (board 8): a training-paper card with the change as its title, the reasons as
/// a Why list, the rule that raised it, and Use, Not now and Ask. It takes the proposal and the
/// three actions, so Body home, the finish screen and a chat's app card all draw the same card.
/// `ask` is nil where there is no chat to open, which hides the Ask button.
struct CoachProposalCard: View {
    let proposal: BodyProposal
    var isBusy = false
    let use: () -> Void
    let notNow: () -> Void
    let ask: (() -> Void)?

    private var paper: HermexPaper { .training }

    var body: some View {
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

    @ViewBuilder
    private var actionButtons: some View {
        Button(action: use) { Text(verbatim: "Use").bodyTapHeight() }
            .buttonStyle(ChatDecisionButtonStyle(emphasis: .primary))
            .accessibilityLabel(Text(verbatim: "Use: \(proposal.title)"))
        Button(action: notNow) { Text(verbatim: "Not now").bodyTapHeight() }
            .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
            .accessibilityLabel(Text(verbatim: "Not now: \(proposal.title)"))
        if let ask {
            Button(action: ask) { Text(verbatim: "Ask").bodyTapHeight() }
                .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
                .accessibilityLabel(Text(verbatim: "Ask Baki about: \(proposal.title)"))
        }
    }
}

extension View {
    /// Lifts a `ChatDecisionButtonStyle` label to a 44 pt button. The style adds 9 pt above and below
    /// its label and a 40 pt floor, so a 26 pt label is 44 pt tall in all.
    func bodyTapHeight() -> some View { frame(minHeight: 26) }
}

/// What "Ask Baki" starts a chat with: the composer is filled in, never sent.
enum BodyAskBaki {
    /// The general opener: "Baki, ".
    static let draft = "Baki, "

    /// An opener about one proposal: `Baki, about "Strict press: 70 lb for 3 × 8": `.
    static func draft(about title: String) -> String { "Baki, about \"\(title)\": " }
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
