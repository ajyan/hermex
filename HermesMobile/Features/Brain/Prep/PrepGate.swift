import SwiftUI

/// Every Prep screen goes through this gate (`ChatShellView`'s `.prep` routes). On a weekday Prep
/// opens only once today's Daily Ask is acted on or skipped with a reason; the Ask sits right here
/// so it unlocks in place. It reads the shell's one `DailyAskModel`: the first load shows a spinner
/// (rather than starting a Prep screen the lock would then replace), later pushes refresh quietly,
/// and a server without the job search, a failure or a timeout leaves Prep open.
struct PrepGate<Content: View>: View {
    @Environment(DailyAskModel.self) private var model: DailyAskModel?
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    static func shouldGate(_ model: DailyAskModel) -> Bool { model.isLocked }
    static func showsSpinner(_ model: DailyAskModel) -> Bool { model.state == .loading }

    var body: some View {
        Group {
            if let model, Self.showsSpinner(model) {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let model, Self.shouldGate(model), case .loaded(let ask) = model.state {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Label { Text(verbatim: "Prep opens after today's Ask") } icon: { Image(systemName: "lock.fill") }
                            .font(AppFont.headline())
                            .padding(.bottom, 20)
                        DailyAskBody(model: model, ask: ask, palette: DeckPalette.ask)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(Color.hxCanvas.ignoresSafeArea())
            } else {
                content
            }
        }
        .task { await model?.load() }
    }
}
