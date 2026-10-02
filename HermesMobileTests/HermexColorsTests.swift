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

    func testStatusTextMeetsAAInIncreasedContrastLight() {
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .light),
            UITraitCollection(accessibilityContrast: .high)
        ])
        let grouped = UIColor(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF7 / 255, alpha: 1)
        for token in [HermexToken.success, .warning] {
            let fg = UIColor(Color(hermexToken: token)).resolvedColor(with: traits)
            // Tinted capsules and banners paint the same hue at up to 18% over white.
            let tint = blend(fg, alpha: 0.18, over: .white)
            XCTAssertGreaterThanOrEqual(contrastResolved(fg, grouped), 4.5, "\(token) on grouped")
            XCTAssertGreaterThanOrEqual(contrastResolved(fg, tint), 4.5, "\(token) on tint")
        }
    }

    func testInAppIconImagesUseNousBlueArtwork() throws {
        for name in ["AppIconLightPreview", "AppIconDarkPreview", "HermesAppIcon"] {
            let image = try XCTUnwrap(UIImage(named: name), name)
            let average = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in
                image.draw(in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            average.cgImage.map { UIColor(cgColor: CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: pixel($0))!) }?
                .getRed(&r, green: &g, blue: &b, alpha: &a)
            XCTAssertGreaterThan(b - r, 0.2, "\(name) should average to a blue, got r=\(r) b=\(b)")
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

    private func blend(_ c: UIColor, alpha: CGFloat, over base: UIColor) -> UIColor {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (br, bg, bb, ba): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        c.getRed(&r, green: &g, blue: &b, alpha: &a); base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: r * alpha + br * (1 - alpha), green: g * alpha + bg * (1 - alpha), blue: b * alpha + bb * (1 - alpha), alpha: 1)
    }

    private func contrastResolved(_ a: UIColor, _ b: UIColor) -> Double {
        contrast(a, b, .light)
    }

    private func pixel(_ image: CGImage) -> [CGFloat] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes.map { CGFloat($0) / 255 }
    }
}
