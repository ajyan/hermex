import UIKit

/// The screen as it looked when "Send feedback" was tapped, attached to the feedback.
/// Rendered small enough to send: the long side is at most `maxLongSide` pixels.
enum FeedbackScreenshot {
    static let maxLongSide: CGFloat = 1600
    static let jpegQuality: CGFloat = 0.7

    /// The foreground scene's key window, or nil when there is none.
    @MainActor
    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    /// Snapshots `window` as it is on screen now, without waiting for pending updates.
    /// Nil without a window or with an empty one, so a missing screenshot never blocks feedback.
    @MainActor
    static func capture(_ window: UIWindow?, displayScale: CGFloat? = nil) -> UIImage? {
        guard let window else { return nil }
        let bounds = window.bounds
        let longSide = max(bounds.width, bounds.height)
        guard longSide > 0, min(bounds.width, bounds.height) > 0 else { return nil }
        let nativeScale = displayScale ?? window.traitCollection.displayScale
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(max(nativeScale, 1), maxLongSide / longSide)
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
    }

    /// The image as a base64 JPEG for `FeedbackCreate.screenshot`.
    static func jpegBase64(_ image: UIImage) -> String? {
        image.jpegData(compressionQuality: jpegQuality)?.base64EncodedString()
    }
}
