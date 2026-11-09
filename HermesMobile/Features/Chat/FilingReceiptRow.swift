import SwiftUI

/// What the transcript can do with a filing receipt. `ChatView` supplies it; a host that
/// doesn't (Bots, previews) shows the receipt without Undo.
struct FilingReceiptActions {
    /// Receipts whose Undo is in flight, by receipt id.
    var undoingIDs: Set<String> = []
    var undo: ((ChatMessage) -> Void)?
}

private struct FilingReceiptActionsKey: EnvironmentKey {
    static let defaultValue = FilingReceiptActions()
}

extension EnvironmentValues {
    var filingReceiptActions: FilingReceiptActions {
        get { self[FilingReceiptActionsKey.self] }
        set { self[FilingReceiptActionsKey.self] = newValue }
    }
}

/// The filing receipt under a reply (DESIGN.md § Components): one chip per vault page the turn
/// wrote, in that page's paper, opening the page; Undo beside them. Once undone it reads as one
/// quiet line, so the reply never claims pages it no longer changed.
struct FilingReceiptRow: View {
    let message: ChatMessage
    let receipt: FilingReceipt

    @Environment(\.filingReceiptActions) private var actions

    private var isUndoing: Bool {
        receipt.id.map(actions.undoingIDs.contains) ?? false
    }

    private var showsUndo: Bool {
        receipt.canUndo && receipt.id != nil && actions.undo != nil
    }

    var body: some View {
        if receipt.undone {
            Text("Filing undone")
                .font(AppFont.footnote())
                .foregroundStyle(Color.hxTextSecondary)
        } else {
            FlowRow(spacing: 6) {
                ForEach(Array(receipt.pages.enumerated()), id: \.offset) { _, page in
                    FiledPageChip(page: page)
                }
                if showsUndo {
                    undoButton
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Saved to"))
        }
    }

    private var undoButton: some View {
        Button {
            actions.undo?(message)
        } label: {
            HStack(spacing: 4) {
                if isUndoing {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text("Undo")
                    .font(AppFont.footnote())
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 26)
            .contentShape(.interaction, Rectangle().inset(by: -9))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .disabled(isUndoing)
        .accessibilityLabel(Text("Undo filing"))
        .accessibilityHint(Text("Puts these pages back as they were"))
    }
}

/// One filed page as a chip in its page's paper. It opens the page when the page has a Brain
/// screen and a shell is listening; otherwise it only names the page.
struct FiledPageChip: View {
    let page: FiledPage

    @Environment(\.openBrainRoute) private var openBrainRoute

    var body: some View {
        let chip = HXChip(paper: page.kind.paper, symbol: page.kind.symbol, label: page.label)
        if let route = page.route, openBrainRoute.isAvailable {
            Button {
                openBrainRoute(route)
            } label: {
                // A taller hit area than the chip draws, like the Brain citation chips.
                chip
                    .zoomSource(for: ShellPushDestination.brainRoute(route))
                    .contentShape(.interaction, Capsule().inset(by: -7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "\(page.label), \(page.kind.name)"))
            .accessibilityHint(Text("Opens the page"))
        } else {
            chip
                .accessibilityLabel(Text(verbatim: "\(page.label), \(page.kind.name)"))
        }
    }
}
