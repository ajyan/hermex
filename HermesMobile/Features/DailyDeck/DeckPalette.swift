import SwiftUI
import UIKit

/// Each kind of Daily Deck card has its own paper (`HermexPaper`), symbol, and spoken name.
struct DeckPalette: Equatable {
    let colors: HermexPaper
    var paper: Color { colors.paper }
    var ink: Color { colors.ink }
    /// The kind's mark, drawn faintly in the card's corner.
    let symbol: String
    /// What VoiceOver calls this kind of card.
    let name: String

    private init(_ colors: HermexPaper, symbol: String, name: String) {
        self.colors = colors
        self.symbol = symbol
        self.name = name
    }

    // Bright paper in both appearances: index cards on a dark desk. Cards draw in light mode
    // (`DeckPageView`) so system text and controls stay legible on them.
    static let opener = DeckPalette(.opener, symbol: "sun.horizon", name: "Today")
    static let quote = DeckPalette(.quote, symbol: "quote.opening", name: "Quote")
    static let book = DeckPalette(.book, symbol: "book.closed", name: "Book highlight")
    static let wiki = DeckPalette(.wiki, symbol: "leaf", name: "From your wiki")
    static let reading = DeckPalette(.reading, symbol: "newspaper", name: "From your reading")
    static let notes = DeckPalette(.notes, symbol: "lightbulb", name: "From your notes")
    static let video = DeckPalette(.video, symbol: "play.rectangle", name: "Video")
    static let past = DeckPalette(.past, symbol: "clock.arrow.circlepath", name: "On this day")
    static let advisor = DeckPalette(.advisor, symbol: "bubble.left", name: "Check-in")
    static let plain = DeckPalette(.plain, symbol: "tray", name: "From your library")
    static let followUps = DeckPalette(.plain, symbol: "checklist", name: "Follow-ups")

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
