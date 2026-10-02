import SwiftUI
import UIKit

/// The semantic color tokens, valued from the Hermes desktop "Nous blue" theme.
/// Views use the `.hx*` styles (`.foregroundStyle(.hxWarning)`); the accent stays
/// `Color.accentColor` / `.tint`, which read `AccentColor` in the asset catalog.
/// Shared with the Live Activity widget, which uses `HermexPalette.dark` directly.
enum HermexToken: CaseIterable {
    case canvas, surface, textPrimary, textSecondary, separator, userBubble
    case codeBackground, inlineCodeBackground, success, warning, danger
}

/// Token values as `0xRRGGBBAA`.
enum HermexPalette {
    static let light: [HermexToken: UInt32] = [
        .canvas: 0xF8FAFFFF, .surface: 0xFFFFFFFF,
        .textPrimary: 0x17171AFF, .textSecondary: 0x666678FF,
        .separator: 0xD0D7DEFF, .userBubble: 0xDAE7FDFF,
        .codeBackground: 0xF6F8FAFF, .inlineCodeBackground: 0x1414140D,
        .success: 0x1F8A65FF, .warning: 0x9A6700FF, .danger: 0xCF222EFF
    ]

    static let dark: [HermexToken: UInt32] = [
        .canvas: 0x0D1117FF, .surface: 0x161B22FF,
        .textPrimary: 0xE6EDF3FF, .textSecondary: 0x7D8590FF,
        .separator: 0x30363DFF, .userBubble: 0x17243AFF,
        .codeBackground: 0x010409FF, .inlineCodeBackground: 0xFFFFFF12,
        .success: 0x55A583FF, .warning: 0xD29922FF, .danger: 0xF85149FF
    ]

    /// Dark-appearance accent, for surfaces outside the app's asset catalog (the Live Activity).
    static let accentDark: UInt32 = 0x4A84FEFF

    static func uiColor(_ rgba: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((rgba >> 24) & 0xFF) / 255,
            green: CGFloat((rgba >> 16) & 0xFF) / 255,
            blue: CGFloat((rgba >> 8) & 0xFF) / 255,
            alpha: CGFloat(rgba & 0xFF) / 255
        )
    }
}

extension Color {
    init(hermexToken token: HermexToken) {
        let light = HermexPalette.uiColor(HermexPalette.light[token] ?? 0)
        let dark = HermexPalette.uiColor(HermexPalette.dark[token] ?? 0)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

extension ShapeStyle where Self == Color {
    static var hxCanvas: Color { Color(hermexToken: .canvas) }
    static var hxSurface: Color { Color(hermexToken: .surface) }
    static var hxTextPrimary: Color { Color(hermexToken: .textPrimary) }
    static var hxTextSecondary: Color { Color(hermexToken: .textSecondary) }
    static var hxSeparator: Color { Color(hermexToken: .separator) }
    static var hxUserBubble: Color { Color(hermexToken: .userBubble) }
    static var hxCodeBackground: Color { Color(hermexToken: .codeBackground) }
    static var hxInlineCodeBackground: Color { Color(hermexToken: .inlineCodeBackground) }
    static var hxSuccess: Color { Color(hermexToken: .success) }
    static var hxWarning: Color { Color(hermexToken: .warning) }
    static var hxDanger: Color { Color(hermexToken: .danger) }
}
