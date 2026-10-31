import SwiftUI

/// A text box's mic: tap to talk into `text`, tap again to stop, and the dictated words are tidied.
/// After a tidy, "Original" beside the mic puts back the words as heard. It wears the tint: Nous blue,
/// or a card's ink on a Daily Brief card. Place it in the box's trailing corner.
struct DictationMicButton: View {
    @Binding var text: String
    var isSubmitting = false
    /// A box whose Done waits for the tidy (`DictationModel.finish()`) passes its own; else the mic keeps one.
    var model: DictationModel?
    @State private var ownModel = DictationModel()
    @State private var shownError: String?
    @Environment(\.dictationServer) private var server

    var body: some View {
        let dictation = model ?? ownModel
        let voiceInput = dictation.voiceInput
        HStack(spacing: 4) {
            if dictation.canUndoTidy {
                DictationOriginalButton(dictation: dictation)
            }
            Button {
                dictation.server = server
                dictation.toggle($text)
            } label: {
                Group {
                    if dictation.isTidying {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: voiceInput.isListening ? "stop.circle.fill" : "mic.fill")
                            .font(AppFont.body(weight: .semibold))
                    }
                }
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || dictation.isTidying || voiceInput.isRequestingPermission)
            .accessibilityLabel(Text(verbatim: DictationCopy.micLabel(dictation)))
            .accessibilityHint(Text(verbatim: voiceInput.isListening ? "" : DictationCopy.micHint))
        }
        .dictationLifecycle(dictation, text: text, isSubmitting: isSubmitting)
        .onChange(of: voiceInput.errorMessage) { _, message in shownError = message }
        .alert(Text(verbatim: "Dictation"), isPresented: Binding(
            get: { shownError != nil }, set: { if !$0 { shownError = nil } }
        )) {
            Button(role: .cancel) {} label: { Text(verbatim: "OK") }
        } message: {
            Text(verbatim: shownError ?? "")
        }
    }
}

/// "Original": puts back the words as heard, replacing the tidied version.
struct DictationOriginalButton: View {
    let dictation: DictationModel

    var body: some View {
        Button { dictation.undoTidy() } label: {
            Label {
                Text(verbatim: "Original")
            } icon: {
                Image(systemName: "arrow.uturn.backward")
            }
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(Color.hxSurface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.hxSeparator, lineWidth: 0.5))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "Put back what you said"))
        .accessibilityHint(Text(verbatim: "Replaces the tidied text with your words as heard"))
    }
}

enum DictationCopy {
    static let micHint = "Tidies your words when you stop"

    @MainActor
    static func micLabel(_ dictation: DictationModel) -> String {
        if dictation.isTidying { return "Tidying your words" }
        return dictation.voiceInput.isListening ? "Stop dictation" : "Dictate"
    }
}

extension View {
    /// Puts a mic for `text` at this box's trailing bottom edge, beside the words. Apply it after
    /// the field's padding and before its background, so the mic sits inside the box.
    func withDictation(_ text: Binding<String>, isSubmitting: Bool = false) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            frame(maxWidth: .infinity, alignment: .leading)
            DictationMicButton(text: text, isSubmitting: isSubmitting)
        }
    }

    /// Wires a mic's dictation to its box: stop on a keyboard edit, drop "Original" on an edit, stop on
    /// send, background, or the box going away. The model tidies on stop by itself.
    func dictationLifecycle(_ dictation: DictationModel, text: String, isSubmitting: Bool) -> some View {
        modifier(DictationLifecycle(dictation: dictation, text: text, isSubmitting: isSubmitting))
    }
}

private struct DictationLifecycle: ViewModifier {
    let dictation: DictationModel
    let text: String
    let isSubmitting: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: text) { _, newText in dictation.textChanged(newText) }
            .onChange(of: isSubmitting) { _, submitting in
                if submitting { dictation.cancel() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { dictation.voiceInput.resume() } else { dictation.voiceInput.suspend() }
            }
            .onDisappear { dictation.cancel() }
    }
}
