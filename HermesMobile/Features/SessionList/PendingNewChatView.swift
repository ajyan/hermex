import SwiftUI
import SwiftData

/// The composer for a chat that does not exist yet. It creates the server session on
/// appear, then swaps itself for `ChatView` without changing identity, so the first
/// message's stream is never torn down by the shell.
struct PendingNewChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppHaptics.isEnabledKey) private var isHapticsEnabled = true

    let server: URL
    let viewModel: SessionListViewModel
    let onAPIError: (Error) -> Void
    let onSessionCreated: (SessionSummary) -> Void
    /// The first turn went out (typed or spoken on a call).
    let onConversationStarted: () -> Void
    let initialAttachments: [SharedAttachmentImport]
    let autoStartsVoiceInput: Bool
    let profileName: String?
    let projectID: String?
    let startsCall: Bool
    let callRequest: Int
    let draftStore: ChatDraftStore
    /// True while the shell still has this chat as its root. A push over the root
    /// also fires `onDisappear`; only a replaced root abandons the draft.
    let isStillRoot: () -> Bool

    @State private var attachmentLease: ChatDraftAttachmentLease?
    @State private var createdSession: SessionSummary?
    @State private var draftMessage = ""
    @State private var draftQuotes: [ComposerQuote] = []
    @State private var didStartCreation = false
    @State private var didStartConversation = false
    @State private var didRequestComposerFocus = false
    @State private var creationErrorMessage: String?
    @FocusState private var composerIsFocused: Bool

    init(
        initialDraft: String = "",
        initialAttachments: [SharedAttachmentImport] = [],
        autoStartsVoiceInput: Bool = false,
        profileName: String? = nil,
        projectID: String? = nil,
        startsCall: Bool = false,
        callRequest: Int = 0,
        server: URL,
        viewModel: SessionListViewModel,
        onAPIError: @escaping (Error) -> Void,
        onSessionCreated: @escaping (SessionSummary) -> Void = { _ in },
        onConversationStarted: @escaping () -> Void = {},
        draftStore: ChatDraftStore? = nil,
        isStillRoot: @escaping () -> Bool = { false }
    ) {
        self.server = server
        self.viewModel = viewModel
        self.onAPIError = onAPIError
        self.onSessionCreated = onSessionCreated
        self.onConversationStarted = onConversationStarted
        self.initialAttachments = initialAttachments
        self.autoStartsVoiceInput = autoStartsVoiceInput
        self.profileName = profileName
        self.projectID = projectID
        self.startsCall = startsCall
        self.callRequest = callRequest
        self.draftStore = draftStore ?? .shared
        self.isStillRoot = isStillRoot
        _draftMessage = State(initialValue: initialDraft)
    }

    var body: some View {
        Group {
            if let createdSession {
                ChatView(
                    session: createdSession,
                    server: server,
                    onAPIError: onAPIError,
                    initialDraft: draftMessage,
                    initialQuotes: draftQuotes,
                    initialAttachments: initialAttachments,
                    loadsInitialMessages: false,
                    autoStartsVoiceInput: autoStartsVoiceInput,
                    startsCall: startsCall,
                    callRequest: callRequest,
                    draftStore: draftStore,
                    restoresDraftSettings: true,
                    onConversationStarted: markConversationStarted
                )
            } else {
                pendingContent
            }
        }
        .background(
            NavigationAppearanceCompletionObserver(action: requestPendingComposerFocus)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
        .task {
            await prepareNewChat()
        }
        .onChange(of: scenePhase) {
            if scenePhase != .active {
                flushDraftsBestEffort()
            }
        }
        .onDisappear {
            if !isStillRoot() {
                restoreAbandonedDraftIfNeeded()
            }
            flushDraftsBestEffort()
        }
    }

    private var pendingContent: some View {
        ZStack(alignment: .bottom) {
            Color.hxCanvas
                .ignoresSafeArea()

            ContentUnavailableView {
                Image(systemName: "bubble.left.and.bubble.right")
            } description: {
                Text("Send a message to start the conversation.")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                composerIsFocused = false
            }

            VStack(spacing: 10) {
                if let creationErrorMessage {
                    pendingErrorBanner(creationErrorMessage)
                }

                pendingComposer
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .navigationTitle("New Chat")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pendingComposer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Atlas", text: persistedDraftBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($composerIsFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color(.separator).opacity(0.18), lineWidth: 0.5)
                }
                .submitLabel(.send)

            Button {} label: {
                Image(systemName: "arrow.up")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color(.secondaryLabel))
                    .frame(width: 44, height: 44)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(true)
            .accessibilityLabel("Send")
        }
    }

    private func pendingErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.hxWarning)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            Button("Retry") {
                Task { await retryCreateSession() }
            }
            .font(.footnote.weight(.semibold))
            .disabled(viewModel.isCreatingSession)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func createSessionIfNeeded() async {
        guard !didStartCreation, createdSession == nil else { return }

        didStartCreation = true
        creationErrorMessage = nil
        let session = await viewModel.createSession(
            modelContext: modelContext,
            profile: profileName,
            projectID: projectID
        )
        // A push over this root cancels the task; let the next appearance retry
        // instead of leaving creation marked as started forever.
        guard !Task.isCancelled else {
            didStartCreation = false
            return
        }
        if let lastError = viewModel.lastError {
            onAPIError(lastError)
        }

        if let session {
            let sessionKey = draftKey(for: session)
            draftStore.setDraft(draftMessage, for: draftKey)
            let movedDraft = draftStore.moveDraft(from: draftKey, to: sessionKey)
            draftMessage = movedDraft.text
            draftQuotes = movedDraft.quotes
            SessionHaptics.sessionCreated(isEnabled: isHapticsEnabled)
            onSessionCreated(session)
            createdSession = session
        } else {
            creationErrorMessage = viewModel.actionErrorMessage
                ?? viewModel.lastError?.localizedDescription
                ?? String(localized: "Could not start a new chat.")
            viewModel.clearActionError()
            didStartCreation = false
        }
    }

    private func retryCreateSession() async {
        didStartCreation = false
        creationErrorMessage = nil
        viewModel.clearActionError()
        await createSessionIfNeeded()
    }

    private var draftKey: ChatDraftKey {
        .newChat(server: server)
    }

    private func draftKey(for session: SessionSummary) -> ChatDraftKey {
        let normalizedSessionID = session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = normalizedSessionID.flatMap { $0.isEmpty ? nil : $0 } ?? session.id
        return .session(server: server, sessionID: sessionID)
    }

    private var persistedDraftBinding: Binding<String> {
        Binding(
            get: { draftMessage },
            set: { newValue in
                draftMessage = newValue
                draftStore.setDraft(newValue, for: draftKey)
            }
        )
    }

    private func prepareNewChat() async {
        await hydrateDraft()
        guard !Task.isCancelled else { return }
        await createSessionIfNeeded()
    }

    private func hydrateDraft() async {
        if attachmentLease == nil { attachmentLease = draftStore.makeAttachmentLease(key: draftKey) }
        await draftStore.markUsed(draftKey)
        let textBeforeHydration = draftMessage
        let persistedDraft = await draftStore.draft(for: draftKey)
        guard !Task.isCancelled, draftMessage == textBeforeHydration else { return }

        if textBeforeHydration.isEmpty {
            if let persistedDraft, !persistedDraft.text.isEmpty {
                draftMessage = persistedDraft.text
            }
        } else {
            draftStore.setDraft(textBeforeHydration, for: draftKey)
        }
    }

    private func flushDraftsBestEffort() {
        Task {
            try? await draftStore.flush()
        }
    }

    private func markConversationStarted() {
        didStartConversation = true
        onConversationStarted()
    }

    private func restoreAbandonedDraftIfNeeded() {
        guard let createdSession else { return }
        draftMessage = draftStore.restoreAbandonedNewChatDraft(
            from: draftKey(for: createdSession),
            to: draftKey,
            didStartConversation: didStartConversation
        )?.text ?? draftMessage
    }

    private func requestPendingComposerFocus() {
        // A new chat opened for a call goes straight to the call screen.
        guard !startsCall, !didRequestComposerFocus else { return }
        didRequestComposerFocus = true

        Task { @MainActor in
            await Task.yield()
            guard createdSession == nil else { return }
            composerIsFocused = true
        }
    }
}
