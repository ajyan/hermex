import SwiftUI
import UIKit

/// Each kind of Daily Deck card has its own paper (`HermexPaper`), symbol, and spoken name.
struct DeckPalette: Equatable {
    let colors: HermexPaper
    /// The opener summarizes the day rather than being one kind of thing, so it sits on the
    /// neutral surface and keeps its color for the accents.
    let isNeutralCard: Bool
    /// The card's opaque fill: its glow card, or `hxSurface` for a neutral card.
    var paper: Color { isNeutralCard ? .hxSurface : colors.card }
    /// The card's role: a glow card in its paper, or a summary card for a neutral one.
    var cardRole: HXCardRole { isNeutralCard ? .summary : .glow(colors) }
    /// The card's hairline.
    var edge: Color { isNeutralCard ? .hxSeparator : colors.edge }
    /// Text and marks on the card: the paper's glow.
    var ink: Color { colors.glow }
    /// Text on an `ink`-filled button.
    var onInk: Color { colors.onGlow }
    /// The kind's mark, drawn faintly in the card's corner.
    let symbol: String
    /// What VoiceOver calls this kind of card.
    let name: String
    /// The kind in one word, for the opener's list of cards ahead.
    let shortName: String

    private init(_ colors: HermexPaper, symbol: String, name: String, shortName: String, isNeutralCard: Bool = false) {
        self.colors = colors
        self.isNeutralCard = isNeutralCard
        self.symbol = symbol
        self.name = name
        self.shortName = shortName
    }

    // Bright paper in both appearances: index cards on a dark desk. Cards draw in light mode
    // (`DeckPageView`) so system text and controls stay legible on them.
    static let opener = DeckPalette(.opener, symbol: "sun.horizon", name: "Today", shortName: "Today", isNeutralCard: true)
    /// The "This week" divider: the opener's neutral paper, named for what it opens.
    static let section = DeckPalette(.opener, symbol: "calendar", name: "This week", shortName: "This week", isNeutralCard: true)
    static let quote = DeckPalette(.quote, symbol: "quote.opening", name: "Quote", shortName: "Quote")
    static let book = DeckPalette(.book, symbol: "book.closed", name: "Book highlight", shortName: "Book")
    static let wiki = DeckPalette(.wiki, symbol: "leaf", name: "From your wiki", shortName: "Wiki")
    static let reading = DeckPalette(.reading, symbol: "newspaper", name: "From your reading", shortName: "Reading")
    static let notes = DeckPalette(.notes, symbol: "lightbulb", name: "From your notes", shortName: "Notes")
    static let video = DeckPalette(.video, symbol: "play.rectangle", name: "Video", shortName: "Video")
    static let past = DeckPalette(.past, symbol: "clock.arrow.circlepath", name: "On this day", shortName: "On this day")
    static let sleep = DeckPalette(.notes, symbol: "moon.zzz", name: "Sleep", shortName: "Sleep")
    static let advisor = DeckPalette(.advisor, symbol: "bubble.left", name: "Check-in", shortName: "Check-in")
    /// The Dad card is the Dad advisor's, so it wears the advisor paper with its own mark.
    static let letter = DeckPalette(.advisor, symbol: "heart", name: "Letter to her", shortName: "Letter")
    static let mandarin = DeckPalette(.mandarin, symbol: "character.bubble", name: "Mandarin practice", shortName: "Mandarin")
    static let plain = DeckPalette(.plain, symbol: "tray", name: "From your library", shortName: "Library")
    /// A reflect card about a person (a week source from the CRM), on the plain paper.
    static let people = DeckPalette(.plain, symbol: "person.2", name: "From your people", shortName: "People")
    static let followUps = DeckPalette(.plain, symbol: "checklist", name: "Follow-ups", shortName: "Follow-ups")
    // A weekly review's Wrapped cards. Themes quote your own past words; mood reads like a
    // check-in; lessons come from your notes; the goals card wears its goal's paper.
    static let theme = DeckPalette(.past, symbol: "quote.bubble", name: "Theme", shortName: "Theme")
    static let mood = DeckPalette(.advisor, symbol: "waveform.path", name: "Energy and mood", shortName: "Mood")
    static let lessons = DeckPalette(.notes, symbol: "lightbulb", name: "Lessons", shortName: "Lessons")
    static let recap = DeckPalette(.plain, symbol: "list.bullet", name: "Recap", shortName: "Recap")
    /// The week's fixes from the feedback loop, on the recap's paper.
    static let changes = DeckPalette(.plain, symbol: "wrench.and.screwdriver", name: "What changed", shortName: "Changes")
    /// The Daily Ask wears its goal's paper (`land-ai-role`, color `notes`).
    static let ask = DeckPalette(GoalPaper.palette(named: "notes", slug: "land-ai-role").colors,
                                 symbol: "briefcase", name: "Today's Ask", shortName: "Ask")

    static func of(_ page: DeckPage) -> DeckPalette {
        switch page {
        case .followUps: return .followUps
        case .card(let card): return of(card)
        }
    }

    static func of(_ card: DeckCard) -> DeckPalette {
        switch card.type {
        case .headline: return .opener
        case .section: return .section
        case .close: return .quote
        case .prompt: return card.isMandarin ? .mandarin : card.isLetter ? .letter : .advisor
        case .sleep: return .sleep
        case .goal:
            let goal = GoalPaper.palette(named: card.color ?? "", slug: card.goals.first ?? card.id)
            return DeckPalette(goal.colors, symbol: "flag", name: "Goals", shortName: "Goals")
        case .weekAhead:
            let goal = GoalPaper.palette(named: card.color ?? "", slug: card.goal ?? card.id)
            return DeckPalette(goal.colors, symbol: "calendar", name: "Week ahead", shortName: "Week ahead")
        case .ask: return .ask
        case .decision: return .followUps
        case .changes: return .changes
        case .item, .unknown:
            switch card.itemKind {
            case "theme": return .theme
            case "mood": return .mood
            case "lessons": return .lessons
            case "recap": return .recap
            case "goals":
                let goal = GoalPaper.palette(named: card.color ?? "", slug: card.meters.first?.group ?? card.id)
                return DeckPalette(goal.colors, symbol: "flag", name: "Goals", shortName: "Goals")
            default: return .plain
            }
        case .reflect:
            switch card.itemKind {
            case "quote": return .quote
            case "book": return .book
            case "wiki": return .wiki
            case "media": return .reading
            case "insight": return .notes
            case "video": return .video
            case "on_this_day", "journal": return .past
            case "crm": return .people
            default: return .plain
            }
        }
    }

    static func == (lhs: DeckPalette, rhs: DeckPalette) -> Bool { lhs.symbol == rhs.symbol && lhs.name == rhs.name }
}
