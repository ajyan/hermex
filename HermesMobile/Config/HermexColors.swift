import SwiftUI
import UIKit

/// The semantic color tokens, valued from the Hermes desktop "Nous blue" theme.
/// Views use the `.hx*` styles (`.foregroundStyle(.hxWarning)`); the accent stays
/// `Color.accentColor` / `.tint`, which read `AccentColor` in the asset catalog.
/// Shared with the Live Activity widget, which uses `HermexPalette.dark` directly.
enum HermexToken: CaseIterable {
    case canvas, surface, textPrimary, textSecondary, separator, userBubble
    case codeBackground, inlineCodeBackground, success, warning, danger
    /// Text and symbols drawn on an accent fill.
    case onAccent
}

/// Token values as `0xRRGGBBAA`.
enum HermexPalette {
    static let light: [HermexToken: UInt32] = [
        .canvas: 0xF8FAFFFF, .surface: 0xFFFFFFFF,
        .textPrimary: 0x17171AFF, .textSecondary: 0x666678FF,
        .separator: 0xD0D7DEFF, .userBubble: 0xDAE7FDFF,
        .codeBackground: 0xF6F8FAFF, .inlineCodeBackground: 0x1414140D,
        .success: 0x1F8A65FF, .warning: 0x9A6700FF, .danger: 0xCF222EFF,
        .onAccent: 0xFFFFFFFF
    ]

    static let dark: [HermexToken: UInt32] = [
        .canvas: 0x0D1117FF, .surface: 0x161B22FF,
        .textPrimary: 0xE6EDF3FF, .textSecondary: 0x7D8590FF,
        .separator: 0x30363DFF, .userBubble: 0x17243AFF,
        .codeBackground: 0x010409FF, .inlineCodeBackground: 0xFFFFFF12,
        .success: 0x55A583FF, .warning: 0xD29922FF, .danger: 0xF85149FF,
        .onAccent: 0x161616FF
    ]

    /// Light values under Increase Contrast, where the base value misses WCAG AA on
    /// grouped backgrounds and tinted status capsules.
    static let increasedContrastLight: [HermexToken: UInt32] = [
        .success: 0x176E50FF, .warning: 0x7D5400FF
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
    /// Each token's color is built once: SwiftUI compares colors when diffing views, and a
    /// fresh dynamic `UIColor` never equals another, so rebuilding would redraw every pass.
    init(hermexToken token: HermexToken) {
        self = HermexPalette.colors[token] ?? .clear
    }
}

extension HermexPalette {
    static let colors: [HermexToken: Color] = Dictionary(uniqueKeysWithValues: HermexToken.allCases.map { token in
        let light = uiColor(light[token] ?? 0)
        let dark = uiColor(dark[token] ?? 0)
        let lightHighContrast = increasedContrastLight[token].map(uiColor) ?? light
        return (token, Color(uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark { return dark }
            return traits.accessibilityContrast == .high ? lightHighContrast : light
        }))
    })
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
    static var hxOnAccent: Color { Color(hermexToken: .onAccent) }
}

/// A paper and the ink drawn on it: the Daily Brief's card colors, which also mark objects by
/// kind across the app (DESIGN.md § Color). The same in light and dark appearance, like index
/// cards on a dark desk; every pair keeps ink-on-paper body text above 7:1. Built once each,
/// since SwiftUI compares colors when diffing.
struct HermexPaper: Equatable {
    let paper: Color
    let ink: Color

    /// Supporting text on the paper: the ink, lighter, never `hxTextSecondary`.
    var secondaryInk: Color { ink.opacity(0.7) }

    private init(paper: UInt32, ink: UInt32) {
        self.paper = Color(uiColor: HermexPalette.uiColor(paper << 8 | 0xFF))
        self.ink = Color(uiColor: HermexPalette.uiColor(ink << 8 | 0xFF))
    }

    static let opener = HermexPaper(paper: 0xFFF1DC, ink: 0x3A2410)
    static let quote = HermexPaper(paper: 0xD9E8FF, ink: 0x0E3264)
    static let book = HermexPaper(paper: 0xFFDCE6, ink: 0x6B1534)
    static let wiki = HermexPaper(paper: 0xD3F2E2, ink: 0x0E4A33)
    static let reading = HermexPaper(paper: 0xFFE4D1, ink: 0x5A2A0C)
    static let notes = HermexPaper(paper: 0xE6DCFF, ink: 0x33197A)
    static let video = HermexPaper(paper: 0xD2F0F4, ink: 0x0B4650)
    static let past = HermexPaper(paper: 0xFFEFC2, ink: 0x4E3A00)
    static let advisor = HermexPaper(paper: 0xE4EEF6, ink: 0x14324A)
    static let plain = HermexPaper(paper: 0xF4F0E8, ink: 0x2A2A28)
}
