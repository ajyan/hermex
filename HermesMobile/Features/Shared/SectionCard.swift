import SwiftUI

/// A card container: an optional sentence-case `HXSectionHeader` over a neutral
/// `.hxCard()` body (DESIGN.md § Components). Shared by Usage, Task Detail, and
/// Settings, so the screens read as one app.
///
/// An optional `footer` sits flush against the card's bottom edge, under a
/// full-width divider and outside the content's padding — the shape a row of
/// card actions wants. Passing it here rather than cancelling the padding at
/// the call site keeps the card's insets its own business.
struct SectionCard<Content: View, Footer: View>: View {
    let title: String?
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer
    /// Set by the initializer rather than inferred from `Footer`, so an empty
    /// footer never leaves a divider hanging under the content.
    private let hasFooter: Bool

    init(
        title: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.content = content()
        self.footer = footer()
        self.hasFooter = true
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HXRadius.lg, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HXSectionHeader(title: title)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
            }

            VStack(spacing: 0) {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if hasFooter {
                    Divider()
                        .overlay(Color.hxSeparator)
                    footer
                }
            }
            .clipShape(shape)
            .hxCard()
        }
    }
}

extension SectionCard where Footer == EmptyView {
    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        self.footer = EmptyView()
        self.hasFooter = false
    }
}
