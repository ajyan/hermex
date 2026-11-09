import SwiftUI

/// What a call saved: every vault page its turns filed, for the card the chat shows once the
/// call screen closes. Built from the filing receipts on the chat's replies, so it lists exactly
/// what those replies list.
struct CallReceipt: Equatable {
    let pages: [FiledPage]

    /// The ids of the receipts already in the chat, taken when a call starts.
    static func receiptIDs(in messages: [ChatMessage]) -> Set<String> {
        Set(messages.compactMap { $0.filed?.id })
    }

    /// The pages filed since `before` was taken, each page once, in the order they were filed.
    /// A receipt the user undid is left out.
    init(messages: [ChatMessage], before: Set<String>) {
        var seen = Set<String>()
        var pages: [FiledPage] = []
        for message in messages {
            guard let receipt = message.filed, !receipt.undone,
                  let id = receipt.id, !before.contains(id)
            else { continue }
            for page in receipt.pages where seen.insert(page.id).inserted {
                pages.append(page)
            }
        }
        self.pages = pages
    }

    init(pages: [FiledPage]) {
        self.pages = pages
    }
}

/// The receipt after a call (DESIGN.md § Components): what was saved and where, under the
/// call's last turn. It stays until the next message is sent.
struct CallReceiptCard: View {
    let receipt: CallReceipt

    var body: some View {
        HXCard(.neutral, title: String(localized: "Saved from this call"), titleStyle: .subheadline) {
            if receipt.pages.isEmpty {
                Text("Nothing was saved during this call. Atlas files call notes overnight.")
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowRow(spacing: 6) {
                    ForEach(Array(receipt.pages.enumerated()), id: \.offset) { _, page in
                        FiledPageChip(page: page)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
