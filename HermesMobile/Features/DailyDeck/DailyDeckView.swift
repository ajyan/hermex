import SwiftUI

/// Today's brief as a deck: one card at a time, swiped or stepped with the
/// buttons, with "File it" on the last card. Filing opens today's session so the
/// agent's work on the answers is visible. Copy is English-only (personal fork).
struct DailyDeckView: View {
    @State private var viewModel: DailyDeckViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
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
            }
        case .filed:
            ContentUnavailableView {
                Label { Text(verbatim: "Filed") } icon: { Image(systemName: "checkmark.circle") }
            } description: {
                Text(verbatim: "Today's answers are in the journal.")
            } actions: {
                if let sessionID = viewModel.sessionID {
                    Button { openSession(sessionID) } label: { Text(verbatim: "Open Today's Session") }
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
        let pages = viewModel.pages
        return VStack(spacing: 0) {
            progress(count: pages.count)
            TabView(selection: $viewModel.index) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { offset, page in
                    DeckPageView(page: page, viewModel: viewModel, file: file)
                        .padding(.horizontal, 16)
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            stepper(count: pages.count)
        }
    }

    private func progress(count: Int) -> some View {
        VStack(spacing: 6) {
            ProgressView(value: Double(viewModel.index + 1), total: Double(max(count, 1)))
                .tint(.secondary)
            Text(verbatim: "\(viewModel.index + 1) of \(count)")
                .font(AppFont.caption())
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    /// Back and Next for VoiceOver, Switch Control, and anyone who'd rather tap than swipe.
    private func stepper(count: Int) -> some View {
        HStack {
            Button { step(-1) } label: {
                Label { Text(verbatim: "Back") } icon: { Image(systemName: "chevron.backward") }
            }
            .disabled(viewModel.index == 0)
            Spacer()
            Button { step(1) } label: {
                Label { Text(verbatim: "Next") } icon: { Image(systemName: "chevron.forward") }
                    .labelStyle(TrailingIconLabelStyle())
            }
            .disabled(viewModel.index >= count - 1)
        }
        .font(AppFont.subheadline(weight: .medium))
        .padding(.horizontal, 20)
        .frame(minHeight: 44)
        .padding(.bottom, 8)
    }

    private func step(_ delta: Int) {
        let target = min(max(viewModel.index + delta, 0), max(viewModel.pages.count - 1, 0))
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

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}
