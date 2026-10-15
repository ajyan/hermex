import SwiftUI

/// Today's brief as a stack of cards, swiped left for the next and right for the
/// previous, with "File it" on the last card. "Not for Me" lives in the More menu. Filing stays on the
/// deck when the server files it alone, and opens the session when the agent has work to do, so that
/// work is visible. Copy is English-only (personal fork).
struct DailyDeckView: View {
    @State private var viewModel: DailyDeckViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingCalendar = false
    @State private var feedbackCard: DeckCard?
    @AppStorage(DailyBriefReminder.enabledKey) private var notifies = false
    /// Good/not-good labels on reflect cards; shown only where the server has labels.
    @State private var labels: LabelsViewModel
    /// The goal card's live check-ins, read once per screen from the Goals API.
    @State private var goals: GoalCheckInCardViewModel
    @Environment(FeedbackAvailability.self) private var availability: FeedbackAvailability?
    private let openSession: (String) -> Void

    init(server: URL, openSession: @escaping (String) -> Void) {
        _viewModel = State(initialValue: DailyDeckViewModel(server: server))
        _labels = State(initialValue: LabelsViewModel(client: APIClientLabelsAdapter(apiClient: APIClient(baseURL: server))))
        _goals = State(initialValue: GoalCheckInCardViewModel(client: APIClientGoalsAdapter(apiClient: APIClient(baseURL: server))))
        self.openSession = openSession
    }

    private var labelsAvailable: Bool { availability?.labelsAvailable == true }
    /// Rate rows show once the server has labels and this screen has read them.
    private var showsLabels: Bool {
        labelsAvailable && labels.isLoaded(feature: LabelKey.dailyDeckFeature)
    }

    var body: some View {
        content
            .environment(showsLabels ? labels : nil)
            .environment(goals)
            .task(id: labelsAvailable) {
                // Every deck's labels in one read, once per screen; a failed read retries on the next appear.
                if labelsAvailable, !showsLabels { try? await labels.load(feature: LabelKey.dailyDeckFeature) }
            }
            .hxNavigationTitle(viewModel.title, subtitle: viewModel.state == .ready ? progressSubtitle : nil)
            .background(Color.hxCanvas.ignoresSafeArea())
            .toolbar {
                if viewModel.workspace != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { isShowingCalendar = true } label: { Image(systemName: "calendar") }
                            .accessibilityLabel(Text(verbatim: "Journal Calendar"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if viewModel.state == .ready {
                            Section {
                                if case .card(let card) = viewModel.currentPage, card.takesFeedback {
                                    Button { feedbackCard = card } label: {
                                        Label { Text(verbatim: "Not for Me…") } icon: { Image(systemName: "hand.thumbsdown") }
                                    }
                                }
                                if viewModel.skippedCount > 0 {
                                    Button { withAnimation { viewModel.restoreSkipped() } } label: {
                                        Label { Text(verbatim: "Restore Skipped Cards (\(viewModel.skippedCount))") } icon: {
                                            Image(systemName: "arrow.uturn.backward")
                                        }
                                    }
                                }
                            }
                        }
                        Toggle(isOn: Binding(get: { notifies }, set: { on in Task { await DailyBriefReminder.setEnabled(on) } })) {
                            Label { Text(verbatim: "Notify Me at 8:00") } icon: { Image(systemName: "bell") }
                        }
                        Button { Task { await viewModel.load() } } label: {
                            Label { Text(verbatim: "Reload") } icon: { Image(systemName: "arrow.clockwise") }
                        }
                        if viewModel.workspace != nil {
                            Button { Task { await viewModel.resetWorkspace() } } label: {
                                Label { Text(verbatim: "Change Workspace") } icon: { Image(systemName: "folder") }
                            }
                        }
                        FeedbackMenuItem()
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(Text(verbatim: "More"))
                }
            }
            .feedbackContext(feedbackContext)
            .task {
                if let review = DailyBriefLaunch.take() {
                    await viewModel.show(date: review.date, kind: review.kind, cardID: review.cardID)
                } else {
                    await viewModel.load()
                }
                await DailyBriefReminder.enableOnFirstOpen()
            }
            .onChange(of: DailyBriefLaunch.shared.pending) { _, request in
                guard request != nil, viewModel.workspace != nil, let review = DailyBriefLaunch.take() else { return }
                Task { await viewModel.show(date: review.date, kind: review.kind, cardID: review.cardID) }
            }
            .onChange(of: scenePhase) { _, phase in
                // Left open overnight, the brief moves on to the new day's deck.
                if phase == .active { Task { await viewModel.refreshDay() } }
            }
            .onChange(of: viewModel.state) {
                // Opening today's brief is the answer the 09:00 reminder waits for.
                if viewModel.state == .ready, !viewModel.isReview, viewModel.date == viewModel.today {
                    Task { await DailyBriefReminder.noteOpened() }
                }
            }
            .sheet(isPresented: $isShowingCalendar) {
                DeckCalendarView(viewModel: viewModel) { day, kind in
                    Task { await viewModel.show(date: day, kind: kind) }
                }
            }
    }

    private var feedbackContext: FeedbackContext {
        .dailyDeck(title: viewModel.title, date: viewModel.date, kind: viewModel.kind, page: viewModel.currentPage)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsWorkspace(let paths):
            workspacePicker(paths)
        case .noDeck:
            ContentUnavailableView {
                Label { Text(verbatim: "No brief yet today") } icon: { Image(systemName: "sun.horizon") }
            } description: {
                Text(verbatim: "The morning brief writes today's deck to briefs/ in \(viewModel.workspace ?? "the workspace").")
            } actions: {
                Button { Task { await viewModel.load() } } label: { Text(verbatim: "Check Again") }
                if let latest = viewModel.availableDates.first(where: { $0 != viewModel.date }) {
                    Button { Task { await viewModel.show(date: latest) } } label: {
                        Text(verbatim: "Open \(DailyDeckPaths.label(latest))")
                    }
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label { Text(verbatim: "Couldn't load the brief") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(verbatim: message)
            } actions: {
                Button { Task { await viewModel.load() } } label: { Text(verbatim: "Retry") }
            }
        case .ready:
            deck
        }
    }

    private func workspacePicker(_ paths: [String]) -> some View {
        List {
            Section {
                ForEach(paths, id: \.self) { path in
                    Button { Task { await viewModel.chooseWorkspace(path) } } label: {
                        Text(verbatim: path).font(AppFont.body()).foregroundStyle(.primary)
                    }
                }
            } header: {
                Text(verbatim: "Which workspace holds briefs/?")
            }
        }
    }

    private var deck: some View {
        VStack(alignment: .leading, spacing: 0) {
            progress(count: viewModel.visiblePages.count)
            DeckStackView(viewModel: viewModel, feedbackCard: $feedbackCard, file: file)
        }
    }

    /// "Oct 9 · 3 of 10 · Filed": which day (when it isn't today), where you are, and whether
    /// it's filed. The header's subtitle.
    private var progressSubtitle: String {
        var parts: [String] = []
        if viewModel.isReview {
            parts.append(viewModel.reviews.first { $0.date == viewModel.date && $0.kind == viewModel.kind }?.label
                         ?? DailyDeckPaths.label(viewModel.date))
        } else if viewModel.date != viewModel.today {
            parts.append(DailyDeckPaths.label(viewModel.date))
        }
        parts.append("\(viewModel.index + 1) of \(viewModel.visiblePages.count)")
        if viewModel.isFiled { parts.append(viewModel.hasChanges ? "Edited" : "Filed") }
        return parts.joined(separator: " · ")
    }

    private func progress(count: Int) -> some View {
        VStack(spacing: 6) {
            ProgressView(value: Double(viewModel.index + 1), total: Double(max(count, 1)))
                .tint(viewModel.currentPage.map { DeckPalette.of($0).ink } ?? .secondary)
                .accessibilityValue(Text(verbatim: progressSubtitle))
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: viewModel.index)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: count)
        .accessibilityElement(children: .combine)
        // Swipe up or down on the counter to move through the deck.
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    private func step(_ delta: Int) {
        let target = min(max(viewModel.index + delta, 0), max(viewModel.visiblePages.count - 1, 0))
        if reduceMotion {
            viewModel.index = target
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { viewModel.index = target }
        }
    }

    private func file() {
        Task {
            // A filing the server finished stays here: the close card shows it as filed.
            if case .openSession(let sessionID) = await viewModel.file() { openSession(sessionID) }
        }
    }
}

/// A review a notification tap (or a goal card's "Next week's plan is waiting") asked for, at
/// `cardID` when set. The Daily Brief screen opens it when it appears, or right away when it is
/// already on screen.
@MainActor
@Observable
final class DailyBriefLaunch {
    struct Request: Equatable {
        let id = UUID()
        let date: String
        let kind: String
        let cardID: String?
    }

    static let shared = DailyBriefLaunch()
    private(set) var pending: Request?

    static func request(date: String, kind: String, cardID: String? = nil) {
        shared.pending = Request(date: date, kind: kind, cardID: cardID)
    }

    static func take() -> Request? {
        defer { shared.pending = nil }
        return shared.pending
    }
}

extension FeedbackContext {
    /// "Daily Deck · Daily Brief · <card title>" on a card; the deck alone elsewhere. State
    /// names the deck file (`slot`, "<date>.<kind>") and the page on display (`card`).
    static func dailyDeck(title: String, date: String, kind: String, page: DeckPage?) -> FeedbackContext {
        var cardTitle: String?
        if case .card(let card) = page { cardTitle = card.title }
        return FeedbackContext(
            feature: "Daily Deck", screen: title, item: cardTitle,
            state: ["slot": "\(date).\(kind)", "card": page?.id])
    }
}
