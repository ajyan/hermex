import SwiftUI

/// The Status screen: the verdict, each tile's last seven days, and what fixed itself. Read-only;
/// a tile opens its details. Every color here is a status color beside a word (DESIGN.md).
struct AtlasStatusView: View {
    @State private var viewModel: AtlasStatusViewModel
    private let onOpen: (ShellPushDestination) -> Void

    init(server: URL, onAPIError: @escaping (Error) -> Void, onOpen: @escaping (ShellPushDestination) -> Void) {
        self.onOpen = onOpen
        let client = APIClientAtlasStatusAdapter(apiClient: APIClient(baseURL: server))
        _viewModel = State(initialValue: AtlasStatusViewModel(client: client, onAPIError: onAPIError))
    }

    var body: some View {
        content
            .hxNavigationTitle("Status", subtitle: subtitle)
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
    }

    private var subtitle: String? {
        if viewModel.refreshFailed { return "Couldn't refresh" }
        guard case .loaded(let status) = viewModel.state else { return nil }
        return AtlasStatusCopy.checked(status.checkedAt, now: Date())
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label { Text(verbatim: "No Status on this server") } icon: { Image(systemName: "waveform.path.ecg") }
            } description: {
                Text(verbatim: "This server doesn't serve Status. It needs the Status API from your hermes-webui fork.")
            }
        case .failed(let message):
            HXFailedView(title: "Couldn't load Status", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let status):
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    AtlasStatusVerdict(status: status)
                    HXSectionHeader(title: "The last 7 days")
                        .padding(.top, 12)
                    week(status)
                    if !status.fixed.isEmpty {
                        HXSectionHeader(title: "Fixed itself", trailing: "Last 24 h")
                            .padding(.top, 12)
                        fixed(status)
                    }
                }
                .padding(16)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
        }
    }

    private func week(_ status: AtlasStatus) -> some View {
        VStack(spacing: 0) {
            AtlasStatusLetters()
                .padding(.bottom, 2)
            ForEach(Array(status.tiles.enumerated()), id: \.element.id) { index, tile in
                if index > 0 { Divider().overlay(Color.hxSeparator) }
                Button { onOpen(.statusTile(tile.id)) } label: { row(tile) }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: AtlasStatusCopy.accessibility(tile)))
                    .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .hxCard()
    }

    private func row(_ tile: AtlasStatus.Tile) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: tile.title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                Text(verbatim: AtlasStatusCopy.word(tile.state))
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(AtlasStatusCopy.color(tile.state))
                if let fact = tile.fact {
                    Text(verbatim: fact)
                        .font(AppFont.caption())
                        .foregroundStyle(Color.hxTextSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AtlasStatusDays(days: tile.days)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func fixed(_ status: AtlasStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(status.fixed.enumerated()), id: \.offset) { index, fix in
                if index > 0 { Divider().overlay(Color.hxSeparator) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: fix.text)
                        .font(AppFont.subheadline())
                        .foregroundStyle(Color.hxTextPrimary)
                    Text(verbatim: AtlasStatusCopy.fixed(fix, title: status.tile(fix.tile)?.title ?? fix.tile.capitalized,
                                                         now: Date()))
                        .font(AppFont.caption())
                        .foregroundStyle(Color.hxTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .hxCard()
    }
}

/// One tile opened: its week, each problem in the watcher's words, what it checks, and Ask Atlas.
struct AtlasStatusTileView: View {
    let id: String
    @State private var viewModel: AtlasStatusViewModel
    private let ask: (String) -> Void

    init(id: String, server: URL, onAPIError: @escaping (Error) -> Void, ask: @escaping (String) -> Void) {
        self.id = id
        self.ask = ask
        let client = APIClientAtlasStatusAdapter(apiClient: APIClient(baseURL: server))
        _viewModel = State(initialValue: AtlasStatusViewModel(client: client, onAPIError: onAPIError))
    }

    private var tile: AtlasStatus.Tile? {
        guard case .loaded(let status) = viewModel.state else { return nil }
        return status.tile(id)
    }

    var body: some View {
        content
            .hxNavigationTitle(tile?.title ?? "Status", subtitle: tile.map { AtlasStatusCopy.word($0.state) })
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView(String("No Status on this server"), systemImage: "waveform.path.ecg")
        case .failed(let message):
            HXFailedView(title: "Couldn't load Status", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded:
            if let tile {
                loaded(tile)
            } else {
                ContentUnavailableView(String("Nothing to show"), systemImage: "waveform.path.ecg")
            }
        }
    }

    private func loaded(_ tile: AtlasStatus.Tile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(verbatim: "Last 7 days")
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 4) {
                        AtlasStatusLetters()
                        AtlasStatusDays(days: tile.days)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .hxCard()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: AtlasStatusCopy.accessibility(tile)))

                ForEach(problemGroups(tile), id: \.level) { group in
                    HXSectionHeader(title: AtlasStatusCopy.word(group.level))
                        .padding(.top, 12)
                    ForEach(Array(group.problems.enumerated()), id: \.offset) { _, problem in
                        problemCard(problem)
                    }
                }

                if !tile.checks.isEmpty {
                    HXSectionHeader(title: "What it checks")
                        .padding(.top, 12)
                    checks(tile.checks)
                }
            }
            .padding(16)
            .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
        }
        .refreshable { await viewModel.load() }
        .safeAreaInset(edge: .bottom) {
            if !tile.problems.isEmpty {
                Button { ask(AtlasStatusCopy.ask(tile)) } label: {
                    Text(verbatim: "Ask Atlas about this")
                        .font(AppFont.body(weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private struct ProblemGroup {
        let level: AtlasStatusLevel
        let problems: [AtlasStatus.Problem]
    }

    /// "Needs you" first, then "Look this week".
    private func problemGroups(_ tile: AtlasStatus.Tile) -> [ProblemGroup] {
        let levels = Set(tile.problems.map(\.state)).sorted { $0.severity > $1.severity }
        return levels.map { level in ProblemGroup(level: level, problems: tile.problems.filter { $0.state == level }) }
    }

    private func problemCard(_ problem: AtlasStatus.Problem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let since = AtlasStatusCopy.since(problem.since, now: Date()) {
                Label {
                    Text(verbatim: since)
                } icon: {
                    Image(systemName: AtlasStatusCopy.symbol(problem.state))
                }
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(AtlasStatusCopy.color(problem.state))
            }
            Text(verbatim: problem.text)
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .hxCard()
        .accessibilityElement(children: .combine)
    }

    private func checks(_ checks: [AtlasStatus.Check]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(checks.enumerated()), id: \.offset) { index, check in
                if index > 0 { Divider().overlay(Color.hxSeparator) }
                HStack(spacing: 8) {
                    Text(verbatim: check.name)
                        .font(AppFont.subheadline())
                        .foregroundStyle(Color.hxTextPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: check.value)
                        .font(AppFont.subheadline(weight: check.state == .ok ? nil : .semibold))
                        .foregroundStyle(check.state == .ok ? Color.hxTextSecondary : AtlasStatusCopy.color(check.state))
                }
                .padding(.vertical, 11)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .hxCard()
    }
}

/// The verdict at the top: a status symbol, the server's headline, and its one-line summary.
private struct AtlasStatusVerdict: View {
    let status: AtlasStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: AtlasStatusCopy.symbol(status.overall))
                .font(AppFont.title2())
                .foregroundStyle(AtlasStatusCopy.color(status.overall))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: status.headline.isEmpty ? AtlasStatusCopy.word(status.overall) : status.headline)
                    .font(AppFont.display(style: .title3))
                    .foregroundStyle(Color.hxTextPrimary)
                if let summary = status.stale == nil ? status.summary : nil {
                    Text(verbatim: summary)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .hxCard()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The weekday letters over the seven day columns, today bold (the Brief close's grid).
private struct AtlasStatusLetters: View {
    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            let letters = AtlasStatusCopy.letters(now: Date())
            ForEach(Array(letters.enumerated()), id: \.offset) { index, letter in
                Text(verbatim: letter)
                    .font(AppFont.caption(weight: index == letters.count - 1 ? .bold : nil))
                    .foregroundStyle(index == letters.count - 1 ? Color.hxTextPrimary : Color.hxTextSecondary)
                    .frame(width: DeckDots.column)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Seven `DeckDot`s, oldest first: a filled dot in the day's status color, or the small mark for a
/// day with nothing recorded.
private struct AtlasStatusDays: View {
    let days: [AtlasStatusLevel]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(padded.enumerated()), id: \.offset) { _, day in
                DeckDot(state: day == .none ? "off" : "done", ink: AtlasStatusCopy.color(day))
            }
        }
        .accessibilityHidden(true)
    }

    /// Always seven columns, so rows line up even if the server sends fewer days.
    private var padded: [AtlasStatusLevel] {
        let last = Array(days.suffix(7))
        return Array(repeating: AtlasStatusLevel.none, count: 7 - last.count) + last
    }
}

/// The drawer's Status bar, pinned above Settings with the same anatomy. Its note is the one
/// drawer note that may carry a status mark (DESIGN.md, Decisions and exceptions).
struct AtlasStatusDrawerBar: View {
    let note: AtlasStatusDrawerNote
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg")
                    .accessibilityHidden(true)
                Text(verbatim: "Status")
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 8)
                if let level = note.level {
                    Circle()
                        .fill(AtlasStatusCopy.color(level))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                Text(verbatim: note.text)
                    .font(AppFont.subheadline(weight: note.level == nil ? nil : .semibold))
                    .foregroundStyle(note.level.map(AtlasStatusCopy.color) ?? Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .accessibilityLabel(Text(verbatim: "Status, \(note.text)"))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.hxSeparator)
                .frame(height: 1 / UIScreen.main.scale)
        }
    }
}
