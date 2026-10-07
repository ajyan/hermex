import SwiftUI

/// Live captions for a call, shown over the orb: the user's words while they
/// talk, then Atlas's reply under a one-line reminder of what was asked. The
/// area has a fixed height; long text scrolls, pinned to the newest words.
struct VoiceCallCaptions: View {
    let sent: String?
    let live: String
    /// Atlas's reply to `sent`, as spoken.
    let reply: String?
    /// True while Atlas is still working on or saying `reply`.
    let isReplying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Seven lines of the caption font.
    @ScaledMetric(relativeTo: .title2) private var bodyHeight: CGFloat = 205
    @ScaledMetric(relativeTo: .title3) private var fadeHeight: CGFloat = 32

    struct Content: Equatable {
        enum Speaker: Equatable { case user, atlas }
        /// Whose words `body` is; a change of speaker crossfades.
        var speaker: Speaker
        /// What was asked, shown small above Atlas's reply.
        var context: String?
        var body: String
        /// Dimmed once the words are no longer being said.
        var isActive: Bool
    }

    /// What the captions show. Atlas's last reply stays, dimmed, until the
    /// user's next words are recognized.
    static func content(sent: String?, live: String, reply: String?, isReplying: Bool) -> Content? {
        if !live.isEmpty {
            return Content(speaker: .user, body: live, isActive: true)
        }
        guard let sent else { return nil }
        if let reply {
            return Content(speaker: .atlas, context: sent, body: reply, isActive: isReplying)
        }
        return Content(speaker: .user, body: sent, isActive: false)
    }

    var body: some View {
        let content = Self.content(sent: sent, live: live, reply: reply, isReplying: isReplying)
        VStack(spacing: 8) {
            // Always takes its line, so the reply below never shifts.
            Text(content?.context ?? " ")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(content?.context == nil ? 0 : 1)
                .accessibilityHidden(content?.context == nil)

            ZStack(alignment: .bottom) {
                if let content {
                    caption(content)
                        .id(content.speaker)
                        .transition(.opacity)
                }
            }
            .frame(height: bodyHeight, alignment: .bottom)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        // A soft dark halo around the letters keeps them legible over the glow.
        .shadow(color: .black.opacity(0.55), radius: 10)
        .shadow(color: .black.opacity(0.5), radius: 2)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: content?.speaker)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: content?.isActive)
    }

    private func caption(_ content: Content) -> some View {
        ScrollView {
            Text(content.body)
                .font(.title2)
                .foregroundStyle(content.isActive ? .primary : .secondary)
                // Short text sits centered on the orb; longer text fills the box and follows its end.
                .frame(maxWidth: .infinity, minHeight: bodyHeight, alignment: .center)
        }
        .scrollIndicators(.hidden)
        // Follows the newest line as the text grows.
        .defaultScrollAnchor(.bottom)
        // Older lines fade out at the top instead of being cut through.
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: fadeHeight)
                Color.black
            }
        }
    }
}
