import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

final class HermexColorsTests: XCTestCase {
    func testEveryTokenResolvesToSpecValuesInLightAndDark() {
        let expected: [HermexToken: (light: UInt32, dark: UInt32)] = [
            .canvas: (0xF8FAFFFF, 0x0D1117FF),
            .surface: (0xFFFFFFFF, 0x161B22FF),
            .textPrimary: (0x17171AFF, 0xE6EDF3FF),
            .textSecondary: (0x666678FF, 0x7D8590FF),
            .separator: (0xD0D7DEFF, 0x30363DFF),
            .userBubble: (0xDAE7FDFF, 0x17243AFF),
            .codeBackground: (0xF6F8FAFF, 0x010409FF),
            .inlineCodeBackground: (0x1414140D, 0xFFFFFF12),
            .success: (0x1F8A65FF, 0x55A583FF),
            .warning: (0x9A6700FF, 0xD29922FF),
            .danger: (0xCF222EFF, 0xF85149FF),
            .onAccent: (0xFFFFFFFF, 0x161616FF)
        ]
        XCTAssertEqual(Set(expected.keys), Set(HermexToken.allCases))
        for token in HermexToken.allCases {
            let color = UIColor(Color(hermexToken: token))
            XCTAssertEqual(rgba(color, .light), expected[token]?.light, "\(token) light")
            XCTAssertEqual(rgba(color, .dark), expected[token]?.dark, "\(token) dark")
        }
    }

    func testAccentAssetIsNousBlue() throws {
        let accent = try XCTUnwrap(UIColor(named: "AccentColor"))
        XCTAssertEqual(rgba(accent, .light), 0x0053FDFF)
        XCTAssertEqual(rgba(accent, .dark), 0x4A84FEFF)
    }

    func testSecondaryTextMeetsAAOnCanvasAndSurface() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let text = UIColor(Color(hermexToken: .textSecondary))
            for background in [HermexToken.canvas, .surface] {
                let ratio = contrast(text, UIColor(Color(hermexToken: background)), style)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(background) \(style.rawValue)")
            }
        }
    }

    func testAttentionColorsetsMapToTokens() throws {
        let accent = try XCTUnwrap(UIColor(named: "AccentColor"))
        let mapping: [(String, UIColor)] = [
            ("AttentionApproval", UIColor(Color(hermexToken: .warning))),
            ("AttentionInput", accent),
            ("AttentionWorking", UIColor(Color(hermexToken: .textSecondary)))
        ]
        for (name, token) in mapping {
            let asset = try XCTUnwrap(UIColor(named: name), name)
            for style in [UIUserInterfaceStyle.light, .dark] {
                XCTAssertEqual(rgba(asset, style), rgba(token, style), "\(name) \(style.rawValue)")
            }
        }
    }

    func testMarkdownPaletteUsesTokens() {
        let cases: [(String, Color, HermexToken)] = [
            ("codeBlock", MarkdownPalette.codeBlock, .codeBackground),
            ("inlineCode", MarkdownPalette.inlineCode, .inlineCodeBackground),
            ("tableBackground", MarkdownPalette.tableBackground, .surface),
            ("tableSecondaryBackground", MarkdownPalette.tableSecondaryBackground, .canvas),
            ("border", MarkdownPalette.border, .separator),
            ("mutedText", MarkdownPalette.mutedText, .textSecondary)
        ]
        for (name, color, token) in cases {
            for style in [UIUserInterfaceStyle.light, .dark] {
                XCTAssertEqual(rgba(UIColor(color), style), rgba(UIColor(Color(hermexToken: token)), style), "\(name) \(style.rawValue)")
            }
        }
    }

    func testUserBubbleFillUsesToken() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            XCTAssertEqual(rgba(UIColor(MessageBubbleView.userBubbleFill), style), rgba(UIColor(Color(hermexToken: .userBubble)), style))
        }
    }

    func testPaletteDarkAccentMatchesAccentAsset() throws {
        let accent = try XCTUnwrap(UIColor(named: "AccentColor"))
        XCTAssertEqual(rgba(HermexPalette.uiColor(HermexPalette.accentDark), .dark), rgba(accent, .dark))
    }

    func testOnAccentTextMeetsAAOnAccent() throws {
        let accent = try XCTUnwrap(UIColor(named: "AccentColor"))
        for style in [UIUserInterfaceStyle.light, .dark] {
            XCTAssertGreaterThanOrEqual(contrast(UIColor(Color(hermexToken: .onAccent)), accent, style), 4.5, "\(style.rawValue)")
        }
    }

    // MARK: - Helpers

    func rgba(_ color: UIColor, _ style: UIUserInterfaceStyle) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
        let byte = { (v: CGFloat) in UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(r) << 24 | byte(g) << 16 | byte(b) << 8 | byte(a)
    }

    private func contrast(_ a: UIColor, _ b: UIColor, _ style: UIUserInterfaceStyle) -> Double {
        func luminance(_ c: UIColor) -> Double {
            let v = rgba(c, style)
            let channel = { (shift: UInt32) -> Double in
                let s = Double((v >> shift) & 0xFF) / 255
                return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(24) + 0.7152 * channel(16) + 0.0722 * channel(8)
        }
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
