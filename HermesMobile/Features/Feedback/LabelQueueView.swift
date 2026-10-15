import SwiftUI

/// The morning deck's closing-card link to Label recent cards: shown once the queue is built,
/// while it has cards and the evals still want tapped labels. Opens the queue in a sheet, which
/// stays open after the last card is rated. The Daily Deck starts the build.
struct RateRecentCardsLink: View {
    let queue: LabelQueueViewModel
    let palette: DeckPalette

    @State private var isOpen = false

    var body: some View {
        VStack(spacing: 0) {
            if queue.state == .ready, queue.evalsWantLabels, queue.unlabeledCount > 0 {
                Button { isOpen = true } label: {
                    Label {
                        Text(verbatim: queue.unlabeledCount == 1 ? "Rate 1 earlier card" : "Rate \(queue.unlabeledCount) earlier cards")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $isOpen) {
            NavigationStack {
                LabelQueueView(viewModel: queue)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button { isOpen = false } label: { Text(verbatim: "Done") }
                        }
                    }
            }
        }
    }
}

/// The Feedback inbox's "Label recent cards" row: opens the queue, with how many cards are
/// still unlabeled once it is built.
struct LabelQueueRow: View {
    let queue: LabelQueueViewModel

    var body: some View {
        NavigationLink {
            LabelQueueView(viewModel: queue)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(Color.hxTextSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: "Label recent cards")
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if queue.state == .ready {
                    Text(verbatim: "\(queue.unlabeledCount)")
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                        .accessibilityLabel(Text(verbatim: "\(queue.unlabeledCount) unlabeled"))
                }
                Image(systemName: "chevron.forward")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(Color.hxTextSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hxCard()
        .accessibilityElement(children: .combine)
    }
}

/// Label recent cards: one Daily Deck reflect card at a time, drawn as the Deck draws it,
/// with Rate rows for its card and question and Skip/Next. Each tap saves at once.
struct LabelQueueView: View {
    let viewModel: LabelQueueViewModel

    var body: some View {
        content
            .background(Color.hxCanvas.ignoresSafeArea())
            .hxNavigationTitle("Label Cards", subtitle: subtitle)
            .onAppear { viewModel.start() }
    }

    private var subtitle: String? {
        guard viewModel.state == .ready, viewModel.current != nil else { return nil }
        return "\(viewModel.index + 1) of \(viewModel.items.count)"
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsBrief:
            ContentUnavailableView {
                Label { Text(verbatim: "Open the Daily Brief once first") } icon: { Image(systemName: "sun.horizon") }
            } description: {
                Text(verbatim: "Recent cards are read through the Daily Brief's session. Open it, then come back.")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label { Text(verbatim: "Couldn't load recent cards") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(verbatim: message)
            } actions: {
                Button { viewModel.start() } label: { Text(verbatim: "Try again") }
            }
        case .ready:
            if let item = viewModel.current {
                VStack(spacing: 0) {
                    ScrollView {
                        LabelQueueCard(item: item, labels: viewModel.labels)
                            .padding(16)
                            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
                    }
                    .id(item.id)
                    Button { viewModel.next() } label: {
                        Text(verbatim: viewModel.isLabeled(item) ? "Next" : "Skip")
                            .font(AppFont.body(weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            } else {
                ContentUnavailableView {
                    Label { Text(verbatim: "All caught up") } icon: { Image(systemName: "checkmark.circle") }
                } description: {
                    Text(verbatim: viewModel.items.isEmpty
                         ? "Every reflect card from the last 14 days is answered, labeled, or has feedback."
                         : "That's every card in this batch.")
                }
            }
        }
    }
}

/// A reflect card as the Deck shows it: its lead, where it came from, the explanation, and
/// the question, on its kind's paper, with the Rate rows at the bottom.
private struct LabelQueueCard: View {
    let item: LabelQueueItem
    let labels: LabelsViewModel

    var body: some View {
        let palette = DeckPalette.of(item.card)
        let text = DeckCardText(item.card)
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: palette.name)
                .font(AppFont.footnote(weight: .semibold))
                .padding(.bottom, 12)
            if let lead = text.lead {
                Text(verbatim: lead)
                    .font(DeckCardText.leadFont(for: item.card, lead: lead))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let attribution = text.attribution {
                Text(verbatim: attribution)
                    .font(AppFont.subheadline(weight: .medium))
                    .padding(.top, 10)
            }
            if let detail = text.detail {
                Text(verbatim: detail)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
            }
            if !text.leadIsQuestion, let question = item.card.question {
                Text(verbatim: question)
                    .font(AppFont.display(style: .headline, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 20)
            }
            Text(verbatim: DailyDeckPaths.label(item.date))
                .font(AppFont.footnote())
                .padding(.top, 16)
            DeckRateRows(card: item.card, date: item.date, kind: item.kind, showsQuestion: true,
                         labels: labels, palette: palette)
                .padding(.top, 16)
        }
        .foregroundStyle(palette.ink)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A glow card laid flat in a list, so without the deck's shadow.
        .background(palette.paper, in: palette.cardRole.shape)
        .overlay(palette.cardRole.shape.strokeBorder(palette.edge, lineWidth: 0.5))
    }
}
