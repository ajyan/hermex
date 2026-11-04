import SwiftUI

/// Every Prep screen goes through this gate (`ChatShellView`'s `.prep` routes). On a weekday Prep
/// opens only once today's Daily Ask is acted on or skipped with a reason; the Ask sits right here
/// so it unlocks in place. It reads the shell's one `DailyAskModel`: the first load shows a spinner
/// (rather than starting a Prep screen the lock would then replace), later pushes refresh quietly,
/// and a server without the job search, a failure or a timeout leaves Prep open. The gate decides once per
/// screen: a screen that has opened stays open, so a later refresh (after midnight, or before the morning's
/// Ask lands) never swaps a run in progress, and its unsent answers, for the lock. Under the Ask the lock
/// offers the soonest interview's prep plan (`DailyAsk.prep`): a screen `route` names as one of its steps
/// opens past the lock, and doing a step is the day's action.
struct PrepGate<Content: View>: View {
    @Environment(DailyAskModel.self) private var model: DailyAskModel?
    @State private var opened = false
    private let route: PrepRoute?
    private let content: Content

    init(route: PrepRoute? = nil, @ViewBuilder content: () -> Content) {
        self.route = route
        self.content = content()
    }

    static func shouldGate(_ model: DailyAskModel, route: PrepRoute? = nil) -> Bool {
        guard model.isLocked else { return false }
        guard let route, case .loaded(let ask) = model.state, let prep = ask.prep else { return true }
        return !prep.opens(route)
    }
    static func showsSpinner(_ model: DailyAskModel) -> Bool { model.state == .loading }

    var body: some View {
        Group {
            if opened {
                content
            } else if let model, Self.showsSpinner(model) {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let model, Self.shouldGate(model, route: route), case .loaded(let ask) = model.state {
                ScrollView {
                    VStack(alignment: .leading, spacing: BrainStyle.l) {
                        Label { Text(verbatim: "Prep opens after today's Ask") } icon: { Image(systemName: "lock.fill") }
                            .font(AppFont.headline())
                        // The Ask on its own paper, as on the Deck.
                        DailyAskBody(model: model, ask: ask)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(BrainStyle.xl)
                            .foregroundStyle(DeckPalette.ask.ink)
                            .tint(DeckPalette.ask.ink)
                            .hxCardSurface(DeckPalette.ask.cardRole)
                        if let prep = ask.prep { PrepGateOffer(prep: prep) }
                    }
                    .padding(BrainStyle.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
                .hxNavigationTitle("Interview prep")
                .background(Color.hxCanvas.ignoresSafeArea())
            } else {
                content.onAppear { opened = true }
            }
        }
        // Every Prep screen answers in text fields, multi-line ones included.
        .hxKeyboardDoneButton()
        .task { await model?.load() }
    }
}

/// Under the lock's Ask: the soonest interview's prep plan, which opens past the lock. Any step done is the
/// day's action.
struct PrepGateOffer: View {
    let prep: DailyAskPrep

    var body: some View {
        let done = prep.steps.filter(\.done).count
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Or prep for an interview")
            SectionCard {
                NavigationLink(value: ShellPushDestination.brainRoute(.prep(.application(prep.id)))) {
                    BrainRow(leading: { Image(systemName: "calendar").foregroundStyle(HermexPaper.prep.glow) },
                             title: Self.title(prep), subtitle: Self.subtitle(done: done, of: prep.steps.count),
                             trailing: "›")
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// "Obin AI · First round, Tue Nov 10".
    static func title(_ prep: DailyAskPrep) -> String {
        "\(prep.company ?? "Interview") · \(prep.label), \(JobCopy.day(prep.on))"
    }

    static func subtitle(done: Int, of total: Int) -> String {
        "\(done) of \(total) prep steps done. One more opens Prep for today."
    }
}
