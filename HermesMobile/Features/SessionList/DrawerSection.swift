import SwiftUI

/// The drawer's sections, in the order they are listed: the second brain's own screens,
/// ordered by how often they are used. Operator screens live in Settings' Tools card.
enum DrawerSection: Hashable, CaseIterable {
    case dailyBrief, people, brain, interviewPrep, goals, body, meals, money

    var title: String {
        switch self {
        case .dailyBrief: "Daily Brief"
        case .people: "People"
        case .brain: "Brain"
        case .interviewPrep: "Interview prep"
        case .goals: "Goals"
        case .body: "Body"
        case .meals: "Meals"
        case .money: "Money"
        }
    }

    var systemImage: String {
        switch self {
        case .dailyBrief: "sun.horizon"
        case .people: BrainModuleID.people.symbolName
        case .brain: "brain"
        case .interviewPrep: "target"
        case .goals: "flag.checkered"
        case .body: "figure.strengthtraining.traditional"
        case .meals: "fork.knife"
        case .money: "chart.line.uptrend.xyaxis"
        }
    }

    /// Each section's own hue (DESIGN.md § Object key, "Drawer sections").
    var paper: HermexPaper {
        switch self {
        case .dailyBrief: .opener
        case .people: BrainModuleID.people.paper
        case .brain: .knowledge
        case .interviewPrep: .prep
        case .goals: .goals
        case .body: .training
        case .meals: .meal
        case .money: .money
        }
    }

    var destination: ShellPushDestination {
        switch self {
        case .dailyBrief: .dailyDeck
        case .people: .brainRoute(.module(.people))
        case .brain: .brain
        case .interviewPrep: .brainRoute(.prep(.home))
        case .goals: .goals
        case .body: .body
        case .meals: .meals
        case .money: .money
        }
    }
}
