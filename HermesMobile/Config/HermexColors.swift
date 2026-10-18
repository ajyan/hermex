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

/// A paper: one hue that marks a kind of object across the app (DESIGN.md § Color), rendered
/// as a **glow** that adapts to the appearance: a deep hue in light, a bright hue in dark.
/// - Small objects (chips, request cards, drawer icons) use `wash` behind `glow` text, with an
///   `edge` hairline.
/// - Whole cards (Brief, Goal hero) use `card`, the same hue at medium strength made opaque, so
///   stacked cards never show through each other.
/// `paper` and `ink` are the original light index-card values, kept as the hue's source and
/// for surfaces that must stay light (widgets). Glow text clears 4.5:1 on wash and card.
/// Colors are built once each, since SwiftUI compares colors when diffing.
struct HermexPaper: Equatable {
    let paper: Color
    let ink: Color
    /// Text and symbols on the canvas in this paper's hue.
    let glow: Color
    /// The faint fill behind glow text: the hue at 16% over the canvas.
    let wash: Color
    /// A whole card's fill, opaque: the hue at 20% over `hxCanvas`. In dark mode a warm hue
    /// (amber, orange, gold, sand) goes 12% over `hxSurface` instead, since warm over navy reads
    /// as muddy brown.
    let card: Color
    /// A hairline in the hue, so a wash keeps its edge on a light canvas.
    let edge: Color
    /// Text on a solid `glow` fill (a request's primary button).
    let onGlow: Color
    /// The raw values, for surfaces that derive their own ramps (Brain covers).
    let values: (paper: UInt32, ink: UInt32, glowLight: UInt32, glowDark: UInt32, hue: UInt32)

    /// Supporting text on the paper: the ink, lighter, never `hxTextSecondary`.
    var secondaryInk: Color { ink.opacity(0.75) }

    private init(paper: UInt32, ink: UInt32, glowLight: UInt32, glowDark: UInt32, hue: UInt32, warm: Bool = false) {
        func color(_ rgb: UInt32, alpha: UInt32 = 0xFF) -> UIColor { HermexPalette.uiColor(rgb << 8 | alpha) }
        func dynamic(light: UIColor, dark: UIColor) -> Color {
            Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        }
        self.paper = Color(uiColor: color(paper))
        self.ink = Color(uiColor: color(ink))
        glow = dynamic(light: color(glowLight), dark: color(glowDark))
        wash = Color(uiColor: color(hue, alpha: 0x29))
        let darkCard = warm ? Self.mix(hue, over: 0x161B22, 0.12) : Self.mix(hue, over: 0x0D1117, 0.2)
        card = dynamic(light: color(Self.mix(hue, over: 0xF8FAFF, 0.2)), dark: color(darkCard))
        edge = dynamic(light: color(glowLight, alpha: 0x4D), dark: color(glowDark, alpha: 0x47))
        onGlow = dynamic(light: color(0xFFFFFF), dark: color(ink))
        values = (paper, ink, glowLight, glowDark, hue)
    }

    static func == (lhs: HermexPaper, rhs: HermexPaper) -> Bool { lhs.values.paper == rhs.values.paper }

    /// `top` at `alpha` over `bottom`, both `0xRRGGBB`.
    static func mix(_ top: UInt32, over bottom: UInt32, _ alpha: Double) -> UInt32 {
        [16, 8, 0].reduce(UInt32(0)) { result, shift in
            let t = Double((top >> UInt32(shift)) & 0xFF), b = Double((bottom >> UInt32(shift)) & 0xFF)
            return result | UInt32((t * alpha + b * (1 - alpha)).rounded()) << UInt32(shift)
        }
    }

    static let opener = HermexPaper(paper: 0xFFF1DC, ink: 0x3A2410, glowLight: 0x8A5200, glowDark: 0xF6C77E, hue: 0xF2B45A, warm: true)
    static let quote = HermexPaper(paper: 0xD9E8FF, ink: 0x0E3264, glowLight: 0x1D4FB8, glowDark: 0x8DB4FF, hue: 0x6E9BFF)
    static let book = HermexPaper(paper: 0xFFDCE6, ink: 0x6B1534, glowLight: 0xA8335E, glowDark: 0xF59AB8, hue: 0xF27BA0)
    static let wiki = HermexPaper(paper: 0xD3F2E2, ink: 0x0E4A33, glowLight: 0x137049, glowDark: 0x5FD3A0, hue: 0x3FBF8A)
    static let reading = HermexPaper(paper: 0xFFE4D1, ink: 0x5A2A0C, glowLight: 0x9A4410, glowDark: 0xF5A37A, hue: 0xF08A55, warm: true)
    static let notes = HermexPaper(paper: 0xE6DCFF, ink: 0x33197A, glowLight: 0x5B3FC4, glowDark: 0xB39DFF, hue: 0x9B7BFF)
    static let video = HermexPaper(paper: 0xD2F0F4, ink: 0x0B4650, glowLight: 0x0E6D7A, glowDark: 0x5CCFE0, hue: 0x3BB8C9)
    static let past = HermexPaper(paper: 0xFFEFC2, ink: 0x4E3A00, glowLight: 0x7A5C00, glowDark: 0xE8C55A, hue: 0xD9AE2E, warm: true)
    static let advisor = HermexPaper(paper: 0xE4EEF6, ink: 0x14324A, glowLight: 0x2E5878, glowDark: 0x9DBEDD, hue: 0x7FA6C9)
    static let plain = HermexPaper(paper: 0xF4F0E8, ink: 0x2A2A28, glowLight: 0x5E5646, glowDark: 0xD6CDBB, hue: 0xA09680, warm: true)
    static let mandarin = HermexPaper(paper: 0xFFDDD6, ink: 0x5E1A0E, glowLight: 0xB03A22, glowDark: 0xFF9C85, hue: 0xF2694B)
    static let ledger = HermexPaper(paper: 0xEEF3D6, ink: 0x2F3A0A, glowLight: 0x4F6300, glowDark: 0xC2DA6E, hue: 0x9DB83A)

    static let all: [HermexPaper] = [.opener, .quote, .book, .wiki, .reading, .notes, .video, .past, .advisor, .plain, .mandarin, .ledger]
}
