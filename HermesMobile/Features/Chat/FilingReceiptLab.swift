#if DEBUG
import SwiftUI

/// Debug-only: the filing receipt under a reply, with fixture pages and no server, for
/// screenshots in light and dark.
/// `xcrun simctl launch <udid> <bundle id> --filing-receipt-lab`
struct FilingReceiptLab: View {
    private static let receipt = FilingReceipt(
        id: "fr_lab000000001",
        canUndo: true,
        pages: [
            FiledPage(kind: .person, title: "Sam Rivera", detail: "Note, Nov 9", module: "people",
                      pageID: "crm/contacts/Sam Rivera.md"),
            FiledPage(kind: .journal, title: "Journal", detail: "Nov 9", module: "journal",
                      pageID: "journal/2026/11-November/2026-11-09.md"),
        ]
    )
    private static let storyReceipt = FilingReceipt(
        id: "fr_lab000000002",
        canUndo: true,
        pages: [FiledPage(kind: .story, title: "Story bank", detail: "The eval loop I owned"),
                FiledPage(kind: .note, title: "Work")]
    )

    @State private var undoing: Set<String> = []
    @State private var undone: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                turn("Had coffee with Sam. He's moving to the platform team in January and offered to intro me to his manager.",
                     receipt: Self.receipt)
                turn("The week I owned the eval loop end to end and cut the bad-card rate in half.",
                     receipt: Self.storyReceipt)
                turn("Ran six miles along the water before work.",
                     receipt: FilingReceipt(id: "fr_lab000000003", undone: true, pages: Self.receipt.pages))
            }
            .padding(16)
        }
        .background(Color.hxCanvas)
        .environment(\.filingReceiptActions, FilingReceiptActions(undoingIDs: undoing) { message in
            guard let id = message.filed?.id else { return }
            undone.insert(id)
        })
        .environment(\.openBrainRoute, Self.opener)
    }

    private static let opener: OpenBrainRouteAction = {
        let action = OpenBrainRouteAction()
        action.handler = { _ in }
        return action
    }()

    private func shownReceipt(_ receipt: FilingReceipt) -> FilingReceipt {
        var shown = receipt
        if let id = receipt.id, undone.contains(id) { shown.undone = true }
        return shown
    }

    @ViewBuilder
    private func turn(_ text: String, receipt: FilingReceipt) -> some View {
        let shown = shownReceipt(receipt)
        MessageBubbleView(
            message: ChatMessage(role: "user", content: text, timestamp: nil, messageId: "u-\(receipt.id ?? "")"),
            transcriptMediaCacheNamespace: "lab"
        )
        MessageBubbleView(
            message: ChatMessage(role: "assistant", content: "Saved.", timestamp: nil,
                                 messageId: "a-\(receipt.id ?? "")", filed: shown),
            transcriptMediaCacheNamespace: "lab"
        )
    }
}
#endif
