import SwiftUI
import UIKit

/// Each kind of Daily Deck card has its own bright paper, the same in light and dark
/// appearance. Ink is the text color on that paper; every pair keeps body text above 7:1.
/// Built once per kind, since SwiftUI compares colors when diffing.
struct DeckPalette: Equatable {
    let paper: Color
    let ink: Color
    /// The kind's mark, drawn faintly in the card's corner.
    let symbol: String
    /// What VoiceOver calls this kind of card.
    let name: String

    private init(paper: UInt32, ink: UInt32, symbol: String, name: String) {
        self.paper = Color(uiColor: HermexPalette.uiColor(paper << 8 | 0xFF))
        self.ink = Color(uiColor: HermexPalette.uiColor(ink << 8 | 0xFF))
        self.symbol = symbol
        self.name = name
    }

    // Bright paper in both appearances: index cards on a dark desk. Cards draw in light mode
    // (`DeckPageView`) so system text and controls stay legible on them.
    static let opener = DeckPalette(paper: 0xFFF1DC, ink: 0x3A2410, symbol: "sun.horizon", name: "Today")
    static let quote = DeckPalette(paper: 0xD9E8FF, ink: 0x0E3264, symbol: "quote.opening", name: "Quote")
    static let book = DeckPalette(paper: 0xFFDCE6, ink: 0x6B1534, symbol: "book.closed", name: "Book highlight")
    static let wiki = DeckPalette(paper: 0xD3F2E2, ink: 0x0E4A33, symbol: "leaf", name: "From your wiki")
    static let reading = DeckPalette(paper: 0xFFE4D1, ink: 0x5A2A0C, symbol: "newspaper", name: "From your reading")
    static let notes = DeckPalette(paper: 0xE6DCFF, ink: 0x33197A, symbol: "lightbulb", name: "From your notes")
    static let video = DeckPalette(paper: 0xD2F0F4, ink: 0x0B4650, symbol: "play.rectangle", name: "Video")
    static let past = DeckPalette(paper: 0xFFEFC2, ink: 0x4E3A00, symbol: "clock.arrow.circlepath", name: "On this day")
    static let advisor = DeckPalette(paper: 0xE4EEF6, ink: 0x14324A, symbol: "bubble.left", name: "Check-in")
    static let plain = DeckPalette(paper: 0xF4F0E8, ink: 0x2A2A28, symbol: "tray", name: "From your library")
    static let followUps = DeckPalette(paper: 0xF4F0E8, ink: 0x2A2A28, symbol: "checklist", name: "Follow-ups")

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
