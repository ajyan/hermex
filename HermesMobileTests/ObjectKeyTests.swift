import Foundation
import XCTest
@testable import HermesMobile

// This file mirrors DESIGN.md's object key (§ The object key, § Shared papers): one test per place,
// each asserting the papers DESIGN.md names, read through the accessors the screens use. Change
// DESIGN.md and this file together. Paper contrast lives in `DesignSystemTests`.
final class ObjectKeyTests: XCTestCase {
    // MARK: - The object key in Config/HermexStyle.swift

    func testObjectKeyNamesWearTheirPapers() {
        XCTAssertEqual(HermexPaper.request, .opener, "DESIGN.md: approval, clarification, anything waiting on the user wears opener")
        XCTAssertEqual(HermexPaper.knowledge, .wiki, "DESIGN.md: anything from the Brain wears wiki")
        XCTAssertEqual(HermexPaper.file, .notes, "DESIGN.md: a file as an object wears notes")
        XCTAssertEqual(HermexPaper.recall, .advisor, "DESIGN.md: the Memory and Skills screens wear advisor")
        XCTAssertEqual(HermexPaper.tool, .plain, "DESIGN.md: every tool step wears plain")
        XCTAssertEqual(HermexPaper.money, .past, "DESIGN.md: Money wears past")
        XCTAssertEqual(HermexPaper.feedback, .notes, "DESIGN.md: the Feedback inbox wears notes")
        XCTAssertEqual(HermexPaper.meal, .reading, "DESIGN.md: Meals wear reading")
        XCTAssertEqual(HermexPaper.training, .video, "DESIGN.md: Body and Sleep wear video")
        XCTAssertEqual(HermexPaper.goals, .book, "DESIGN.md: Goals' drawer row wears book")
        XCTAssertEqual(HermexPaper.prep, .orchid, "DESIGN.md: Interview prep, everywhere, wears orchid")
    }

    func testEveryToolStepWearsTheToolPaper() {
        let kinds: [ToolCallSummaryFormatter.Kind] = [.shell, .read, .write, .search, .web, .list, .skill, .memory, .delegate, .unknown]
        for kind in kinds {
            XCTAssertEqual(HermexPaper.forTool(kind), .tool, "DESIGN.md: every tool step wears .tool (\(kind))")
        }
    }

    // MARK: - The Brain

    func testEveryReviewBiteWearsTheBrainsPaper() {
        let kinds: [BrainBite.Kind] = [.idea, .quote, .highlight, .takeaway, .unknown]
        for kind in kinds {
            let bite = BrainBite(id: "b", kind: kind, text: "t", ref: BrainRef(module: .wiki, id: "wiki/a.md"))
            XCTAssertEqual(bite.paper, .knowledge, "DESIGN.md: every review bite wears wiki (\(kind))")
        }
    }

    func testBrainPagesWearTheirKindsPaper() {
        for module in [BrainModuleID.wiki, .journal, .articles, .highlights] {
            XCTAssertEqual(module.paper, .knowledge,
                           "DESIGN.md: inside the Brain, wiki, journal, articles and highlights wear wiki (\(module))")
        }
        XCTAssertEqual(BrainModuleID.people.paper, .advisor, "DESIGN.md: inside the Brain, a person wears advisor")
        XCTAssertEqual(BrainModuleID.letters.paper, .advisor, "DESIGN.md: inside the Brain, letters wear advisor (a letter is to a person)")
    }

    func testTheShelfWearsItsBooksPaper() {
        XCTAssertEqual(BrainShelfKind.letters.paper, .advisor, "DESIGN.md: the shelf's Letters book wears advisor")
        XCTAssertEqual(BrainShelfKind.takes.paper, .knowledge, "DESIGN.md: the shelf's My takes wears wiki")
        XCTAssertEqual(BrainShelfKind.memories.paper, .knowledge, "DESIGN.md: the shelf's Memories wears wiki")
    }

    @MainActor
    func testABrainBadgeWearsTheBrainsPaperByDefault() {
        XCTAssertEqual(BrainBadge(text: "3").paper, .knowledge, "DESIGN.md: a Brain badge wears wiki unless told otherwise")
    }

    // MARK: - The Daily Brief

    func testDailyBriefCardsWearTheirPapers() {
        let cases: [(DeckPalette, HermexPaper, String)] = [
            (.lookingBack, .dusk, "DESIGN.md: the Looking back card wears dusk"),
            (.lookingAhead, .dusk, "DESIGN.md: the Looking ahead card wears dusk"),
            (.week, .dusk, "DESIGN.md: a week's review cards wear dusk"),
            (.theme, .dusk, "DESIGN.md: dusk also carries Theme"),
            (.money, .past, "DESIGN.md: the Sunday review's money card wears past, Money's"),
            (.dinner, .reading, "DESIGN.md: the Brief's dinner card wears reading, Meals'"),
            (.sleep, .video, "DESIGN.md: the Sleep card wears video, Body's"),
            (.training, .video, "DESIGN.md: the training card wears video, Body's"),
            (.ask, .orchid, "DESIGN.md: the Brief's Daily Ask wears orchid (the job search)"),
            (.search, .orchid, "DESIGN.md: the Brief's search card wears orchid (the job search)"),
            (.dream, .plain, "DESIGN.md: Atlas asks wears plain"),
            (.followUps, .plain, "DESIGN.md: Follow-ups wear plain"),
            (.changes, .plain, "DESIGN.md: What changed wears plain"),
            (.recap, .plain, "DESIGN.md: Recap wears plain"),
            (.letter, .advisor, "DESIGN.md: the Dad card (Letter to her) wears advisor"),
            (.people, .advisor, "DESIGN.md: From your people wears advisor"),
            (.advisor, .advisor, "DESIGN.md: the Check-in wears advisor"),
            (.mood, .advisor, "DESIGN.md: Energy and mood wears advisor"),
            (.lessons, .notes, "DESIGN.md: Lessons wear notes"),
            (.mandarin, .mandarin, "DESIGN.md: the Mandarin practice card wears mandarin"),
        ]
        for (palette, paper, rule) in cases {
            XCTAssertEqual(palette.colors, paper, rule)
            XCTAssertFalse(palette.isNeutralCard, "\(rule): a glow card, not a neutral one")
        }
        XCTAssertEqual(DeckPalette.people.colors, BrainModuleID.people.paper,
                       "DESIGN.md: a person wears one paper in the Brief and the Brain")
    }

    func testDailyBriefBrainCardsWearTheBrainsPaper() {
        let cards: [(DeckPalette, String)] = [
            (.quote, "Quote"), (.book, "Book highlight"), (.wiki, "From your wiki"), (.reading, "From your reading"),
            (.notes, "From your notes"), (.video, "Video"), (.past, "A year ago"), (.journal, "Your journal"),
            (.plain, "Library"),
        ]
        for (palette, name) in cards {
            XCTAssertEqual(palette.colors, .knowledge, "DESIGN.md: a Daily Brief card from the Brain wears wiki (\(name))")
        }
    }

    func testDailyBriefSummaryCardsAreNeutral() {
        let cards: [(DeckPalette, String)] = [
            (.opener, "the opener"), (.section, "the This week divider"), (.weekQuestion, "the week's question"),
            (.tracker, "the habit tracker"), (.front("ai"), "a season front's divider"), (.front(nil), "the Also divider"),
            (.section(front: "Body"), "the week's divider wearing its front's symbol"),
        ]
        for (palette, name) in cards {
            XCTAssertTrue(palette.isNeutralCard, "DESIGN.md: \(name) is a neutral summary card")
            XCTAssertEqual(palette.colors, .opener, "DESIGN.md: \(name) keeps opener for its accents")
        }
    }

    func testReviewCardsWearDuskExceptSleepAndTheLetter() throws {
        let deck = try DailyDeck.decode(#"""
        {"date":"d","kind":"monthly","cards":[
         {"id":"cover","type":"month_cover","month":{"name":"October"}},
         {"id":"q","type":"month_question","color":"past","month":{}},
         {"id":"v","type":"value","color":"body","month":{}},
         {"id":"sleep","type":"month_sleep","color":"notes","month":{}},
         {"id":"letter","type":"week_letter","month":{}}]}
        """#)
        let papers = deck.cards.map { DeckPalette.of($0).colors }
        XCTAssertEqual(papers.count, 5)
        guard papers.count == 5 else { return }
        XCTAssertEqual(papers[0], .dusk, "DESIGN.md: a month's cover wears dusk")
        XCTAssertEqual(papers[1], .dusk, "DESIGN.md: a review card wears dusk whatever color the vault names")
        XCTAssertEqual(papers[2], .dusk, "DESIGN.md: every value card wears dusk")
        XCTAssertEqual(papers[3], .video, "DESIGN.md: the review's sleep card wears video, Body's")
        XCTAssertEqual(papers[4], .advisor, "DESIGN.md: the review's letter wears advisor, the Dad card's")
    }

    func testEachHabitOnTheTrackerWearsItsKindsPaper() throws {
        let rows = try JSONDecoder().decode([DeckFrontRow].self, from: Data(#"""
        [{"label":"Sleep by 11","front":"living-well"},{"label":"Lifted","front":"living-well"},
         {"label":"Letters to her","front":"fatherhood"},{"label":"Applications","kind":"pips","front":"ai"},
         {"label":"Mandarin","front":"relationships"},
         {"label":"Stretch","paper":"opener","front":"living-well"},{"label":"Unfiled","paper":"opener"}]
        """#.utf8))
        XCTAssertEqual(rows.count, 7)
        guard rows.count == 7 else { return }
        XCTAssertEqual(rows[0].habitPaper, .video, "DESIGN.md: the sleep habit wears video, Body's")
        XCTAssertEqual(rows[1].habitPaper, .video, "DESIGN.md: the lifting habit wears video, Body's")
        XCTAssertEqual(rows[2].habitPaper, .advisor, "DESIGN.md: the letter habit wears advisor")
        XCTAssertEqual(rows[3].habitPaper, .orchid, "DESIGN.md: the job search habit wears orchid")
        XCTAssertEqual(rows[4].habitPaper, .mandarin, "DESIGN.md: the Mandarin habit wears mandarin")
        for row in rows {
            XCTAssertNotEqual(row.habitPaper, .opener, "DESIGN.md: amber means waiting on you, so no habit wears opener (\(row.label))")
        }
    }

    // MARK: - Goals

    func testAGoalWearsItsOwnPaperButNeverOpener() {
        for name in GoalPaper.names {
            XCTAssertEqual(GoalPaper.palette(named: name, slug: "x").colors, HermexPaper.named(name),
                           "DESIGN.md: a goal wears its own paper (GoalPaper), here \(name)")
        }
        XCTAssertEqual(GoalPaper.palette(named: "opener", slug: "x").colors, .reading,
                       "DESIGN.md: a goal file's color: opener wears reading")
        for palette in GoalPaper.choices {
            XCTAssertNotEqual(palette.colors, .opener, "DESIGN.md: no goal wears opener")
        }
        for slug in ["marathon", "land-ai-role", "learn-piano", "a", "zz", "becoming-a-dad", "read-more", "sleep"] {
            XCTAssertNotEqual(GoalPaper.palette(named: "", slug: slug).colors, .opener,
                              "DESIGN.md: no goal wears opener, even one picked from its slug (\(slug))")
        }
    }

    // MARK: - Calls and filing receipts

    func testCallMemoriesWearTheirPagesPaper() {
        let cases: [(VoiceCallSourceKind, HermexPaper, String)] = [
            (.journal, .knowledge, "DESIGN.md: a call memory from a journal day wears wiki"),
            (.wiki, .knowledge, "DESIGN.md: a call memory from a wiki page wears wiki"),
            (.article, .knowledge, "DESIGN.md: a call memory from an article wears wiki"),
            (.book, .knowledge, "DESIGN.md: a call memory from a book highlight wears wiki"),
            (.person, .advisor, "DESIGN.md: a call memory of a person wears advisor"),
            (.note, .notes, "DESIGN.md: a call memory from a loose note wears notes, the file paper"),
        ]
        XCTAssertEqual(cases.count, VoiceCallSourceKind.allCases.count, "DESIGN.md names every call memory kind")
        for (kind, paper, rule) in cases {
            XCTAssertEqual(kind.paper, paper, rule)
        }
    }

    func testFiledPagesWearTheirPagesPaper() {
        let cases: [(FiledPageKind, HermexPaper, String)] = [
            (.person, .advisor, "DESIGN.md: a filed person wears advisor"),
            (.letter, .advisor, "DESIGN.md: a filed letter wears advisor"),
            (.journal, .knowledge, "DESIGN.md: a filed journal day wears wiki"),
            (.wiki, .knowledge, "DESIGN.md: a filed wiki page wears wiki"),
            (.story, .orchid, "DESIGN.md: a filed story wears orchid, Prep's"),
            (.note, .notes, "DESIGN.md: a filed loose note wears notes, the file paper"),
        ]
        XCTAssertEqual(cases.count, FiledPageKind.allCases.count, "DESIGN.md names every filed page kind")
        for (kind, paper, rule) in cases {
            XCTAssertEqual(kind.paper, paper, rule)
        }
    }

    // MARK: - The drawer

    func testDrawerSectionsInOrderEachWearADifferentHue() {
        XCTAssertEqual(DrawerSection.allCases, [.dailyBrief, .people, .brain, .interviewPrep, .goals, .body, .meals, .money],
                       "DESIGN.md: drawer sections, in order: Daily Brief, People, Brain, Interview prep, Goals, Body, Meals, Money")
        XCTAssertEqual(DrawerSection.allCases.map(\.paper),
                       [.opener, BrainModuleID.people.paper, .knowledge, .prep, .goals, .training, .meal, .money],
                       "DESIGN.md: each drawer section wears its object's paper")
        let papers = DrawerSection.allCases.map(\.paper)
        for (index, paper) in papers.enumerated() {
            XCTAssertFalse(papers[(index + 1)...].contains(paper), "DESIGN.md: each drawer section is a different hue")
        }
    }

    // MARK: - Retired papers

    func testNoPlaceWearsARetiredPaper() {
        var worn: [(HermexPaper, String)] = [
            (.request, "request"), (.knowledge, "knowledge"), (.file, "file"), (.recall, "recall"), (.tool, "tool"),
            (.money, "money"), (.feedback, "feedback"), (.meal, "meal"), (.training, "training"), (.goals, "goals"),
            (.prep, "prep"),
        ]
        let palettes: [DeckPalette] = [
            .opener, .section, .weekQuestion, .tracker, .quote, .book, .wiki, .reading, .notes, .video, .past, .journal,
            .money, .training, .sleep, .advisor, .letter, .lookingBack, .lookingAhead, .mandarin, .dinner, .dream,
            .plain, .people, .followUps, .theme, .mood, .lessons, .recap, .changes, .week, .ask, .search,
        ]
        worn += palettes.map { ($0.colors, "DeckPalette \($0.name)") }
        worn += GoalPaper.choices.map { ($0.colors, "GoalPaper \($0.name)") }
        worn += BrainModuleID.allCases.map { ($0.paper, "BrainModuleID.\($0)") }
        worn += BrainShelfKind.allCases.map { ($0.paper, "BrainShelfKind.\($0)") }
        worn += VoiceCallSourceKind.allCases.map { ($0.paper, "VoiceCallSourceKind.\($0)") }
        worn += FiledPageKind.allCases.map { ($0.paper, "FiledPageKind.\($0)") }
        worn += DrawerSection.allCases.map { ($0.paper, "DrawerSection.\($0)") }
        for (paper, place) in worn {
            XCTAssertNotEqual(paper, .ledger, "DESIGN.md: ledger is unused since 2026-11-13 (\(place))")
            XCTAssertNotEqual(paper, .kitchen, "DESIGN.md: kitchen is unused since 2026-11-13 (\(place))")
        }
    }
}
