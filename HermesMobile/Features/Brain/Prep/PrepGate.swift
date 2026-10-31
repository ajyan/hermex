import SwiftUI

/// Every Prep screen goes through this gate (`ChatShellView`'s `.prep` routes). On a weekday Prep
/// opens only once today's Daily Ask is acted on or skipped with a reason; the Ask sits right here
/// so it unlocks in place. It reads the shell's one `DailyAskModel`: the first load shows a spinner
/// (rather than starting a Prep screen the lock would then replace), later pushes refresh quietly,
/// and a server without the job search, a failure or a timeout leaves Prep open. The gate decides once per
/// screen: a screen that has opened stays open, so a later refresh (after midnight, or before the morning's
/// Ask lands) never swaps a run in progress, and its unsent answers, for the lock.
struct PrepGate<Content: View>: View {
    @Environment(DailyAskModel.self) private var model: DailyAskModel?
    @State private var opened = false
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    static func shouldGate(_ model: DailyAskModel) -> Bool { model.isLocked }
    static func showsSpinner(_ model: DailyAskModel) -> Bool { model.state == .loading }

    var body: some View {
        Group {
            if opened {
                content
            } else if let model, Self.showsSpinner(model) {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let model, Self.shouldGate(model), case .loaded(let ask) = model.state {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Label { Text(verbatim: "Prep opens after today's Ask") } icon: { Image(systemName: "lock.fill") }
                            .font(AppFont.headline())
                        // The Ask on its own paper, as on the Deck.
                        DailyAskBody(model: model, ask: ask)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                            .foregroundStyle(DeckPalette.ask.ink)
                            .tint(DeckPalette.ask.ink)
                            .hxCardSurface(DeckPalette.ask.cardRole)
                    }
                    .padding(16)
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
