import Observation
import SwiftUI

/// Baki's proposals on the Sunday review's training card. A decision hides the proposal at once and
/// brings it back, with a note, if the Body API doesn't take it. It lives on the deck's view model, so
/// a card the stack redraws keeps what was decided. Without a client the proposals are read-only.
@MainActor
@Observable
final class WeekTrainingModel {
    /// Proposal ids decided on this screen, hidden from the card.
    private(set) var decided: Set<String> = []
    /// Proposal ids with a decision in flight; further taps on them are ignored.
    private(set) var deciding: Set<String> = []
    /// Why the last decision didn't take; cleared by the next one.
    private(set) var error: String?

    @ObservationIgnored private let client: (any BodyDataClient)?

    init(client: (any BodyDataClient)?) { self.client = client }

    var canDecide: Bool { client != nil }

    /// The proposals still waiting on an answer.
    func visible(_ proposals: [BodyProposal]) -> [BodyProposal] {
        proposals.filter { $0.isPending && !decided.contains($0.id) }
    }

    func decide(_ proposal: BodyProposal, accept: Bool) async {
        guard let client, !deciding.contains(proposal.id), !decided.contains(proposal.id) else { return }
        deciding.insert(proposal.id)
        decided.insert(proposal.id)
        error = nil
        defer { deciding.remove(proposal.id) }
        do {
            _ = try await client.decide(proposalID: proposal.id, accept: accept)
        } catch {
            // Roll back even when cancelled, so a dismissed screen never loses the proposal.
            decided.remove(proposal.id)
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                self.error = "Couldn't save that. Try again."
            }
        }
    }
}

/// The Sunday review's training card: Baki's read of the week's lifting as a headline and a few
/// bullets, then a compact row per proposal with Use and Not now. Its kind label stands in for the
/// corner mark, as on the deck's other act cards.
struct WeekTrainingCard: View {
    let card: DeckCard
    let palette: DeckPalette
    let model: WeekTrainingModel

    var body: some View {
        let proposals = model.visible(card.proposals)
        VStack(alignment: .leading, spacing: 0) {
            DeckKindLabel(symbol: palette.symbol, text: "Baki · this week", ink: palette.ink)
            Text(verbatim: card.headline ?? card.title ?? "The week's training")
                .font(AppFont.display(style: .title2, weight: .semibold))
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .accessibilityAddTraits(.isHeader)
            if !card.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(card.bullets.enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: "•").accessibilityHidden(true)
                            Text(verbatim: bullet).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(AppFont.body())
                        .foregroundStyle(Color.hxTextPrimary)
                    }
                }
                .padding(.top, 14)
            }
            if !proposals.isEmpty {
                Text(verbatim: "Baki suggests")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(palette.ink.opacity(0.75))
                    .padding(.top, 22)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(proposals) { proposal in
                    Rectangle().fill(palette.ink.opacity(0.12)).frame(height: 0.5)
                    row(proposal)
                }
            }
            if let error = model.error {
                Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(AppFont.footnote(weight: .medium))
                    .foregroundStyle(Color.hxDanger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            DeckFootnote(card: card, palette: palette)
        }
    }

    private func row(_ proposal: BodyProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: proposal.title)
                .font(AppFont.body(weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(proposal.why.enumerated()), id: \.offset) { _, reason in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "•").accessibilityHidden(true)
                    Text(verbatim: reason).fixedSize(horizontal: false, vertical: true)
                }
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextSecondary)
            }
            if model.canDecide {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { buttons(proposal) }
                    VStack(spacing: 8) { buttons(proposal) }
                }
                .environment(\.hxPaper, palette.colors)
                .disabled(model.deciding.contains(proposal.id))
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func buttons(_ proposal: BodyProposal) -> some View {
        Button { Task { await model.decide(proposal, accept: true) } } label: {
            Text(verbatim: "Use").bodyTapHeight()
        }
        .buttonStyle(ChatDecisionButtonStyle(emphasis: .primary))
        .accessibilityLabel(Text(verbatim: "Use: \(proposal.title)"))
        Button { Task { await model.decide(proposal, accept: false) } } label: {
            Text(verbatim: "Not now").bodyTapHeight()
        }
        .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
        .accessibilityLabel(Text(verbatim: "Not now: \(proposal.title)"))
    }
}
