import SwiftUI

/// Send feedback about the screen it was opened from: ✓/✗ rows for what it shows (when given),
/// the screen's context in plain words, what goes along (a removable screenshot, screen state),
/// then what should change. Presented by `.feedbackContext(_:)` and by swiping up on a Daily
/// Deck card. Copy is English-only (personal fork).
struct FeedbackSheet: View {
    @State private var viewModel: FeedbackSheetViewModel
    private let ratings: [FeedbackRating]
    private let labels: LabelsViewModel?
    @FocusState private var isEditing: Bool
    @Environment(\.dismiss) private var dismiss

    init(context: FeedbackContext, client: any FeedbackDataClient, screenshot: UIImage? = nil,
         ratings: [FeedbackRating] = [], labels: LabelsViewModel? = nil) {
        _viewModel = State(initialValue: FeedbackSheetViewModel(context: context, client: client, screenshot: screenshot))
        self.ratings = labels == nil ? [] : ratings
        self.labels = labels
    }

    var body: some View {
        List {
            if let labels, !ratings.isEmpty {
                Section {
                    ForEach(ratings) { rating in
                        RateControl(label: rating.label, key: rating.key, title: rating.title, labels: labels)
                            .listRowBackground(Color.hxSurface)
                    }
                } header: {
                    Text(verbatim: "Rate")
                }
            }

            Section {
                Text(verbatim: viewModel.context.about)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .listRowBackground(Color.hxSurface)

                if let summary = viewModel.attachmentSummary {
                    attachmentRow(summary)
                        .listRowBackground(Color.hxSurface)
                }
            } header: {
                Text(verbatim: "About")
            }

            Section {
                // The section header names the field; no placeholder repeats it.
                TextField(text: $viewModel.text, axis: .vertical) { Text(verbatim: "") }
                .font(BrainStyle.quote)
                .lineLimit(4...12)
                .focused($isEditing)
                .accessibilityLabel(Text(verbatim: "What should change?"))
                .listRowBackground(Color.hxSurface)

                if let error = viewModel.error {
                    Text(verbatim: error)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxDanger)
                        .listRowBackground(Color.hxSurface)
                }
            } header: {
                Text(verbatim: "What should change?")
            } footer: {
                Text(verbatim: "A plan comes back tonight. Nothing changes until you approve it.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.hxCanvas.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.hxCanvas)
        // A send in flight finishes or fails in view, so its result is never lost.
        .interactiveDismissDisabled(viewModel.isSending)
        // With ratings to tap, the keyboard waits until the note is chosen.
        .onAppear { isEditing = ratings.isEmpty }
        .onDisappear { viewModel.dismiss() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            closeButton
            Text(verbatim: "Send feedback")
                .font(AppFont.headline())
                .foregroundStyle(Color.hxTextPrimary)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .background(Color.hxCanvas)
    }

    /// The screenshot's thumbnail and ✕, then a line naming everything that goes along.
    private func attachmentRow(_ summary: String) -> some View {
        HStack(spacing: 12) {
            if let screenshot = viewModel.screenshot {
                Image(uiImage: screenshot)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: HXRadius.xs, style: .continuous))
                    .accessibilityHidden(true)
            }
            Text(verbatim: summary)
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if viewModel.screenshot != nil {
                Button {
                    viewModel.removeScreenshot()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.hxTextSecondary)
                        .frame(width: 24, height: 24)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isSending)
                .accessibilityLabel(Text(verbatim: "Remove screenshot"))
            }
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.hxTextSecondary)
                .frame(width: 30, height: 30)
                .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isSending)
        .accessibilityLabel(Text(verbatim: "Close"))
    }

    private var sendButton: some View {
        Button {
            Task {
                if await viewModel.send() { dismiss() }
            }
        } label: {
            ZStack {
                if viewModel.isSending {
                    ProgressView().tint(Color.hxOnAccent)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(viewModel.canSend ? Color.hxOnAccent : Color.hxTextSecondary)
                }
            }
            .frame(width: 30, height: 30)
            .background(
                viewModel.canSend || viewModel.isSending ? Color.accentColor : Color(uiColor: .tertiarySystemFill),
                in: Circle()
            )
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canSend)
        .accessibilityLabel(Text(verbatim: "Send"))
    }
}
