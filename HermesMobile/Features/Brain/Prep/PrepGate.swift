import SwiftUI

/// Every Prep screen goes through this gate (`ChatShellView`'s `.prep` routes). On a weekday Prep
/// opens only once today's Daily Ask is acted on or skipped with a reason; the Ask sits right here
/// so it unlocks in place. A server without the job search, and failures, leave Prep open; the first
/// load shows a spinner rather than starting a Prep screen the lock would then replace.
struct PrepGate<Content: View>: View {
    @State private var model: DailyAskModel
    private let content: Content

    init(server: URL, onAPIError: @escaping (Error) -> Void, @ViewBuilder content: () -> Content) {
        _model = State(initialValue: DailyAskModel(
            client: APIClientDailyAskAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
        self.content = content()
    }

    static func shouldGate(_ model: DailyAskModel) -> Bool { model.isLocked }

    var body: some View {
        Group {
            if case .loading = model.state {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if Self.shouldGate(model), case .loaded(let ask) = model.state {
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
        .task { await model.load() }
    }
}
