import Observation
import SwiftUI

/// Whether the active server takes feedback, and labels on generated content (the Rate
/// controls and Label recent cards). The server-keyed shell owns one, so a server switch
/// (which rebuilds the shell) checks again. Memory only.
@MainActor
@Observable
final class FeedbackAvailability {
    @ObservationIgnored let client: any FeedbackDataClient
    /// Nil where labels aren't wired up; `labelsAvailable` then stays false.
    @ObservationIgnored let labels: (any LabelsDataClient)?
    /// False until the server answers, so the item never flashes in on a server without it.
    private(set) var isAvailable = false
    /// False until the server answers; a 404 on `/api/labels` keeps every Rate control hidden.
    private(set) var labelsAvailable = false
    @ObservationIgnored private var isChecking = false

    init(client: any FeedbackDataClient, labels: (any LabelsDataClient)? = nil) {
        self.client = client
        self.labels = labels
    }

    /// Asks the server until it says yes to each. The shell calls this on launch and on each
    /// return to the foreground, so a server that gains a feature mid-session shows it.
    func check() async {
        let needsLabels = labels != nil && !labelsAvailable
        guard !isChecking, !isAvailable || needsLabels else { return }
        isChecking = true
        defer { isChecking = false }
        let client = client, labels = needsLabels ? labels : nil
        let hasFeedback = isAvailable, hasLabels = labelsAvailable
        async let feedback = hasFeedback ? true : client.isAvailable()
        async let labeled = labels == nil ? hasLabels : (await labels?.isAvailable() ?? false)
        let (feedbackResult, labelsResult) = await (feedback, labeled)
        isAvailable = feedbackResult
        labelsAvailable = labelsResult
    }
}

/// The screen's request to show the Send feedback sheet. A reference, so the menu item
/// can flip it without the screen's context modifier changing identity.
@MainActor
@Observable
final class FeedbackPresentation {
    var isPresented = false
    /// The screen as it looked when Send feedback was tapped; dropped when the sheet closes.
    @ObservationIgnored var screenshot: UIImage?

    /// Shows the sheet with `screenshot`, taken before the sheet covers the screen.
    func present(screenshot: UIImage?) {
        self.screenshot = screenshot
        isPresented = true
    }
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
            .sheet(isPresented: Bindable(presentation).isPresented, onDismiss: { presentation.screenshot = nil }) {
                if let availability {
                    FeedbackSheet(context: context, client: availability.client, screenshot: presentation.screenshot)
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
                presentation.present(screenshot: FeedbackScreenshot.capture(FeedbackScreenshot.keyWindow()))
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
