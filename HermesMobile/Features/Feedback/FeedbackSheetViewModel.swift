import Foundation
import Observation
import UIKit

/// The Send feedback sheet's state: the text, the screenshot (kept unless removed), one
/// send at a time, and an inline error that keeps the text so a failed send can be retried.
@MainActor
@Observable
final class FeedbackSheetViewModel {
    let context: FeedbackContext
    var text = ""
    /// The screen when Send feedback was tapped. Sent unless the user removes it.
    private(set) var screenshot: UIImage?
    private(set) var isSending = false
    private(set) var error: String?

    @ObservationIgnored private let client: any FeedbackDataClient
    @ObservationIgnored private let build: String?
    /// Bumped by every send and by `dismiss()`, so a reply that lands for an older
    /// generation (or after the sheet closed) changes nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isDismissed = false

    init(
        context: FeedbackContext,
        client: any FeedbackDataClient,
        build: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        screenshot: UIImage? = nil
    ) {
        self.context = context
        self.client = client
        self.build = build
        self.screenshot = screenshot
    }

    func removeScreenshot() {
        screenshot = nil
    }

    /// What goes along with the text, e.g. "Screenshot · Chat session (last turn)". Nil
    /// when nothing does. A Chat `session_id` makes the server add the session's last turn.
    var attachmentSummary: String? {
        var parts: [String] = []
        if screenshot != nil { parts.append("Screenshot") }
        if context.state["session_id"] != nil {
            parts.append("Chat session (last turn)")
        } else if !context.state.isEmpty {
            parts.append("Screen state")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSend: Bool {
        !trimmedText.isEmpty && !isSending && !isDismissed
    }

    /// Posts the feedback. True only when the server stored it and the sheet is still open.
    func send() async -> Bool {
        guard canSend else { return false }
        generation += 1
        let token = generation
        isSending = true
        error = nil
        do {
            let body = FeedbackCreate(
                context: context, build: build, text: trimmedText,
                screenshot: screenshot.flatMap(FeedbackScreenshot.jpegBase64))
            _ = try await client.create(body)
            guard token == generation else { return false }
            isSending = false
            return true
        } catch {
            guard token == generation else { return false }
            isSending = false
            self.error = "Couldn't send. Your note is still here; try again."
            return false
        }
    }

    /// The sheet closed: drop any reply still in flight and refuse further sends.
    func dismiss() {
        isDismissed = true
        generation += 1
    }
}
