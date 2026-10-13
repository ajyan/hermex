import SwiftUI

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
            .task { await viewModel.build() }
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
        case .needsWorkspace:
            ContentUnavailableView {
                Label { Text(verbatim: "Open the Daily Brief first") } icon: { Image(systemName: "sun.horizon") }
            } description: {
                Text(verbatim: "Choose the workspace that holds briefs/ there, then come back.")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label { Text(verbatim: "Couldn't load recent cards") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(verbatim: message)
            } actions: {
                Button { Task { await viewModel.build() } } label: { Text(verbatim: "Try again") }
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
                         ? "Every reflect card from the last 14 days is labeled."
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
                    .font(["quote", "book", "on_this_day"].contains(item.card.itemKind ?? "")
                          ? AppFont.serif(style: .title3) : AppFont.display(style: .title3, weight: .semibold))
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
        .background(palette.paper, in: DeckPageView.shape)
        .overlay(DeckPageView.shape.strokeBorder(palette.edge, lineWidth: 0.5))
    }
}
