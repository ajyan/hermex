import SwiftUI
import UIKit

/// Each kind of Daily Deck card has its own paper: a soft wash on warm paper in light
/// appearance, a deep tinted ground in dark. Ink is the text color on that paper; every
/// pair keeps body text above 7:1. Built once per kind, since SwiftUI compares colors when
/// diffing and a fresh dynamic color never equals another.
struct DeckPalette: Equatable {
    let paper: Color
    let ink: Color
    /// The kind's mark, drawn faintly in the card's corner.
    let symbol: String
    /// What VoiceOver calls this kind of card.
    let name: String

    private init(light: UInt32, dark: UInt32, inkLight: UInt32, inkDark: UInt32, symbol: String, name: String) {
        paper = Self.dynamic(light: light, dark: dark)
        ink = Self.dynamic(light: inkLight, dark: inkDark)
        self.symbol = symbol
        self.name = name
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        let l = HermexPalette.uiColor(light << 8 | 0xFF), d = HermexPalette.uiColor(dark << 8 | 0xFF)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? d : l })
    }

    static let opener = DeckPalette(light: 0xFBF5EA, dark: 0x2E2920, inkLight: 0x3A2A16, inkDark: 0xF5EBD9, symbol: "sun.horizon", name: "Today")
    static let quote = DeckPalette(light: 0xE3ECF7, dark: 0x1D2939, inkLight: 0x172B4D, inkDark: 0xE3ECF7, symbol: "quote.opening", name: "Quote")
    static let book = DeckPalette(light: 0xF6E6EA, dark: 0x38252B, inkLight: 0x4A2230, inkDark: 0xF6E3EA, symbol: "book.closed", name: "Book highlight")
    static let wiki = DeckPalette(light: 0xE4EDE0, dark: 0x232F20, inkLight: 0x22361F, inkDark: 0xE4EDE0, symbol: "leaf", name: "From your wiki")
    static let reading = DeckPalette(light: 0xF8E9DE, dark: 0x3A2A20, inkLight: 0x4C2B17, inkDark: 0xF8E6D8, symbol: "newspaper", name: "From your reading")
    static let notes = DeckPalette(light: 0xECE8F6, dark: 0x2A2640, inkLight: 0x2D2550, inkDark: 0xECE8F6, symbol: "lightbulb", name: "From your notes")
    static let video = DeckPalette(light: 0xF6EFD3, dark: 0x34301B, inkLight: 0x3B3110, inkDark: 0xF6EFD3, symbol: "play.rectangle", name: "Video")
    static let past = DeckPalette(light: 0xF2E8D8, dark: 0x382F22, inkLight: 0x3D2C18, inkDark: 0xF2E6D2, symbol: "clock.arrow.circlepath", name: "On this day")
    static let advisor = DeckPalette(light: 0xE6EEF0, dark: 0x203038, inkLight: 0x1E3036, inkDark: 0xE3EEF1, symbol: "bubble.left", name: "Check-in")
    static let plain = DeckPalette(light: 0xF3F1EC, dark: 0x2A2926, inkLight: 0x2A2A28, inkDark: 0xEDEBE6, symbol: "tray", name: "From your library")
    static let followUps = DeckPalette(light: 0xF3F1EC, dark: 0x2A2926, inkLight: 0x2A2A28, inkDark: 0xEDEBE6, symbol: "checklist", name: "Follow-ups")

    static func of(_ page: DeckPage) -> DeckPalette {
        switch page {
        case .followUps: return .followUps
        case .card(let card): return of(card)
        }
    }

    static func of(_ card: DeckCard) -> DeckPalette {
        switch card.type {
        case .headline: return .opener
        case .close: return .quote
        case .prompt: return .advisor
        case .decision: return .followUps
        case .item, .unknown: return .plain
        case .reflect:
            switch card.itemKind {
            case "quote": return .quote
            case "book": return .book
            case "wiki": return .wiki
            case "media": return .reading
            case "insight": return .notes
            case "video": return .video
            case "on_this_day": return .past
            default: return .plain
            }
        }
    }

    static func == (lhs: DeckPalette, rhs: DeckPalette) -> Bool { lhs.symbol == rhs.symbol && lhs.name == rhs.name }
}
