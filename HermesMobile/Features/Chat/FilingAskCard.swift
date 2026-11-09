import SwiftUI
import UIKit

/// "Where does this belong?": the request card for a capture that fits two places (DESIGN.md
/// § Components, Request cards). It sits where a clarification does, above the composer, on
/// the request paper's wash: the likelier place is the filled button, the other the secondary
/// one. Choosing files the capture, and the reply ends with its filing receipt.
struct FilingAskCard: View {
    let question: String
    let detail: String?
    let recommended: String
    let other: String
    let isResponding: Bool
    let errorMessage: String?
    let onChoose: (String) -> Void
    /// The card's height, which the transcript leaves room for.
    let onFootprintChange: (CGFloat) -> Void

    private let paper = HermexPaper.request

    var body: some View {
        HXCard(.wash(paper), title: question, spacing: 8) {
            Text("Needs you")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(paper.glow)
        } content: {
            if let detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage, !errorMessage.isEmpty {
                Text(verbatim: errorMessage)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            HStack(spacing: 8) {
                Button { onChoose(other) } label: {
                    Text(verbatim: other).lineLimit(1)
                }
                .buttonStyle(.chatDecision(.secondary))
                Button { onChoose(recommended) } label: {
                    Text(verbatim: recommended).lineLimit(1)
                }
                .buttonStyle(.chatDecision(.primary))
            }
            .disabled(isResponding)
            .padding(.top, 4)
        }
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onFootprintChange(height)
        }
        .onAppear {
            guard UIAccessibility.isVoiceOverRunning else { return }
            AccessibilityNotification.Announcement(String(localized: "Input needed: \(question)")).post()
        }
    }
}
