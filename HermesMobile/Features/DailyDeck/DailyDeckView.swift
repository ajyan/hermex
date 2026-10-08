import SwiftUI

/// Today's brief as a stack of cards, swiped left for the next and right for the
/// previous, with "File it" on the last card. "Not for Me" lives in the More menu. Filing opens today's session so the
/// agent's work on the answers is visible. Copy is English-only (personal fork).
struct DailyDeckView: View {
    @State private var viewModel: DailyDeckViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingCalendar = false
    @State private var feedbackCard: DeckCard?
    private let openSession: (String) -> Void

    init(server: URL, openSession: @escaping (String) -> Void) {
        _viewModel = State(initialValue: DailyDeckViewModel(server: server))
        self.openSession = openSession
    }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: "Daily Brief"))
            .navigationBarTitleDisplayMode(.inline)
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
                        Button { Task { await viewModel.load() } } label: {
                            Label { Text(verbatim: "Reload") } icon: { Image(systemName: "arrow.clockwise") }
                        }
                        if viewModel.workspace != nil {
                            Button { Task { await viewModel.resetWorkspace() } } label: {
                                Label { Text(verbatim: "Change Workspace") } icon: { Image(systemName: "folder") }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel(Text(verbatim: "More"))
                }
            }
            .task { await viewModel.load() }
            .sheet(isPresented: $isShowingCalendar) {
                DeckCalendarView(viewModel: viewModel) { day in
                    Task { await viewModel.show(date: day) }
                }
            }
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
            Text(verbatim: viewModel.currentPage?.eyebrow ?? " ")
                .textCase(.uppercase)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .accessibilityHidden(viewModel.currentPage?.eyebrow == nil)
            DeckStackView(viewModel: viewModel, feedbackCard: $feedbackCard, file: file)
        }
    }

    private func progress(count: Int) -> some View {
        VStack(spacing: 6) {
            ProgressView(value: Double(viewModel.index + 1), total: Double(max(count, 1)))
                .tint(.secondary)
            HStack(spacing: 6) {
                if viewModel.date != viewModel.today {
                    Text(verbatim: DailyDeckPaths.label(viewModel.date))
                    Text(verbatim: "·")
                }
                Text(verbatim: "\(viewModel.index + 1) of \(count)")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if viewModel.isFiled {
                    Text(verbatim: "·")
                    Label { Text(verbatim: viewModel.hasChanges ? "Edited" : "Filed") } icon: {
                        Image(systemName: viewModel.hasChanges ? "pencil" : "checkmark")
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
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
            if let sessionID = await viewModel.file() { openSession(sessionID) }
        }
    }
}
