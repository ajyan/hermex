import Observation
import SwiftUI

/// Whether the active server takes feedback. The server-keyed shell owns one and checks
/// it once, so a server switch (which rebuilds the shell) checks again. Memory only.
@MainActor
@Observable
final class FeedbackAvailability {
    @ObservationIgnored let client: any FeedbackDataClient
    /// False until the server answers, so the item never flashes in on a server without it.
    private(set) var isAvailable = false
    @ObservationIgnored private var hasChecked = false

    init(client: any FeedbackDataClient) {
        self.client = client
    }

    func check() async {
        guard !hasChecked else { return }
        hasChecked = true
        isAvailable = await client.isAvailable()
    }
}

/// The screen's request to show the Send feedback sheet. A reference, so the menu item
/// can flip it without the screen's context modifier changing identity.
@MainActor
@Observable
final class FeedbackPresentation {
    var isPresented = false
}

private struct FeedbackContextKey: EnvironmentKey {
    static let defaultValue: FeedbackContext? = nil
}

extension EnvironmentValues {
    /// What the screen on display is, for the Send feedback sheet's About row.
    var feedbackContext: FeedbackContext? {
        get { self[FeedbackContextKey.self] }
        set { self[FeedbackContextKey.self] = newValue }
    }
}

extension View {
    /// Names this screen for feedback and hosts its Send feedback sheet. Put it outside the
    /// `.toolbar` that holds `FeedbackMenuItem()`.
    func feedbackContext(_ context: FeedbackContext) -> some View {
        modifier(FeedbackContextHost(context: context))
    }
}

/// Hosts the sheet on the screen itself: a sheet attached inside a `Menu` never presents.
private struct FeedbackContextHost: ViewModifier {
    let context: FeedbackContext
    @State private var presentation = FeedbackPresentation()
    @Environment(FeedbackAvailability.self) private var availability: FeedbackAvailability?

    func body(content: Content) -> some View {
        content
            .environment(\.feedbackContext, context)
            .environment(presentation)
            .sheet(isPresented: Bindable(presentation).isPresented) {
                if let availability {
                    FeedbackSheet(context: context, client: availability.client)
                }
            }
    }
}

/// "Send feedback", the last item in a screen's More menu. Hidden when the screen names
/// no context or the server has no feedback inbox.
struct FeedbackMenuItem: View {
    @Environment(\.feedbackContext) private var context
    @Environment(FeedbackPresentation.self) private var presentation: FeedbackPresentation?
    @Environment(FeedbackAvailability.self) private var availability: FeedbackAvailability?

    var body: some View {
        if context != nil, let presentation, availability?.isAvailable == true {
            Button {
                presentation.isPresented = true
            } label: {
                Label { Text(verbatim: "Send feedback") } icon: { Image(systemName: "message") }
            }
        }
    }
}

/// A More menu holding only "Send feedback", for screens that have no More menu of their
/// own. Hidden with the item, so a server without feedback never shows an empty menu.
struct FeedbackMoreMenu: View {
    @Environment(FeedbackAvailability.self) private var availability: FeedbackAvailability?

    var body: some View {
        if availability?.isAvailable == true {
            Menu {
                FeedbackMenuItem()
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}
