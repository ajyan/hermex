import SwiftUI

/// Send feedback about the screen it was opened from: the screen's context in plain words,
/// then what should change. Presented by `.feedbackContext(_:)`. Copy is English-only (personal fork).
struct FeedbackSheet: View {
    @State private var viewModel: FeedbackSheetViewModel
    @FocusState private var isEditing: Bool
    @Environment(\.dismiss) private var dismiss

    init(context: FeedbackContext, client: any FeedbackDataClient) {
        _viewModel = State(initialValue: FeedbackSheetViewModel(context: context, client: client))
    }

    var body: some View {
        List {
            Section {
                Text(verbatim: viewModel.context.about)
                    .font(AppFont.body())
                    .foregroundStyle(Color.hxTextPrimary)
                    .listRowBackground(Color.hxSurface)
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
        .onAppear { isEditing = true }
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
