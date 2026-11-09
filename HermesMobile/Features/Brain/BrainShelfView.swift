import SwiftData
import SwiftUI

/// One page of the shelf for his writing: Letters (a book, oldest first), My takes (newest
/// first, each under the idea it answered) or Memories (a memoir, oldest first). Read-only:
/// the pages grow as he files answers from the Daily Brief. Pushed onto the shell's stack as
/// `BrainRoute.shelf(_:)`. Copy is English-only (personal fork).
struct BrainShelfView: View {
    @State private var viewModel: BrainShelfViewModel

    init(kind: BrainShelfKind, server: URL, modelContext: ModelContext, onAPIError: @escaping (Error) -> Void) {
        _viewModel = State(initialValue: BrainShelfViewModel(
            kind: kind,
            client: APIClientBrainAdapter(apiClient: APIClient(baseURL: server)),
            cache: BrainCacheHandle(server: server, context: modelContext),
            onAPIError: onAPIError
        ))
    }

    /// A page over a view model built elsewhere (a fixture, for previews and screenshots).
    init(viewModel: BrainShelfViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    private var kind: BrainShelfKind { viewModel.kind }

    var body: some View {
        content
            .hxNavigationTitle(kind.title, subtitle: viewModel.cards.isEmpty ? nil : kind.countLabel(viewModel.cards.count))
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label { Text(verbatim: "No Brain on this server") } icon: { Image(systemName: "brain") }
            } description: {
                Text(verbatim: "This server doesn't serve the Second Brain. It needs the Brain API from your hermes-webui fork.")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label { Text(verbatim: "Couldn't load \(kind.title)") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(verbatim: message)
            } actions: {
                Button { Task { await viewModel.load() } } label: { Text(verbatim: "Try again") }
            }
        case .loaded:
            BrainShelfPage(kind: kind, cards: viewModel.cards, isShowingCachedCopy: viewModel.isShowingCachedCopy)
                .refreshable { await viewModel.load() }
        }
    }
}

/// A loaded shelf page: its cards top to bottom, or the line saying what will appear here.
struct BrainShelfPage: View {
    let kind: BrainShelfKind
    let cards: [BrainShelfLayout.Card]
    var isShowingCachedCopy = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BrainStyle.l) {
                if cards.isEmpty {
                    ContentUnavailableView {
                        Label { Text(verbatim: kind.emptyTitle) } icon: { Image(systemName: kind.symbolName) }
                    } description: {
                        Text(verbatim: kind.emptyDescription)
                    }
                    .padding(.top, BrainStyle.xl)
                }
                ForEach(cards) { card in
                    BrainShelfCard(card: card, paper: kind.paper)
                }
                if isShowingCachedCopy {
                    Text(verbatim: "Offline, showing saved copy")
                        .brainText(.meta)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, BrainStyle.s)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, BrainStyle.m)
        }
        .background(Color.hxCanvas.ignoresSafeArea())
    }
}

/// One thing he wrote, as a glow card in its page's paper: when or where it belongs in the
/// glow, the title in the display voice, the question he answered, then his words in the serif.
/// A take whose idea has a Brain page ends on a chip that opens it.
struct BrainShelfCard: View {
    let card: BrainShelfLayout.Card
    let paper: HermexPaper

    var body: some View {
        HXCard(.glow(paper), title: card.title, spacing: BrainStyle.s) {
            if !card.kicker.isEmpty {
                Text(verbatim: card.kicker)
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(paper.glow)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } content: {
            if !card.prompt.isEmpty {
                Text(verbatim: card.prompt)
                    .font(AppFont.subheadline())
                    .foregroundStyle(paper.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(verbatim: "Question: \(card.prompt)"))
            }
            if !card.text.isEmpty {
                Text(verbatim: card.text)
                    .brainText(.quote)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, BrainStyle.xs)
            }
        } footer: {
            if let route = card.source {
                NavigationLink(value: ShellPushDestination.brainRoute(route)) {
                    // A secondary button in the card's own paper, like "Open the diagram".
                    HXChip(paper: paper, symbol: card.sourceModule?.symbolName, label: card.sourceLabel)
                        .frame(minHeight: BrainStyle.minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(verbatim: "Opens the idea this answers"))
            }
        }
    }
}

/// The Brain home's "Your writing": one row per shelf page, on the home's neutral card.
struct BrainShelfHomeSection: View {
    let rows: [BrainShelfLayout.HomeRow]

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            HXSectionHeader(title: "Your writing")
                .padding(.horizontal, 4)
            BrainHomeCard {
                ForEach(rows) { row in
                    let destination = ShellPushDestination.brainRoute(.shelf(row.kind))
                    if row.id != rows.first?.id { BrainHomeDivider() }
                    NavigationLink(value: destination) {
                        BrainRow(
                            leading: { BrainModuleIcon(systemName: row.kind.symbolName, paper: row.kind.paper) },
                            title: row.kind.title,
                            subtitle: row.kind.subtitle,
                            trailing: row.count.flatMap { $0 > 0 ? "\($0)" : nil },
                            subtitleLineLimit: 1
                        )
                        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
                        .zoomSource(for: destination, cornerRadius: HXRadius.sm)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

#if DEBUG
/// Made-up writing for previews and screenshots. Nothing here is real.
enum BrainShelfFixtures {
    static let letters = BrainShelf(kind: "letters", entries: [
        BrainShelfEntry(id: "daughter/letters/2026-10-02.md", date: "2026-10-02", title: "October 2, 2026",
                        context: "15 weeks before you arrive", prompt: "What do you hope she finds funny?",
                        text: "Mira, I hope you laugh at the kettle. It whistles one flat note and your mother salutes it every morning.\n\nI hope you find us a little ridiculous, and that it makes the house feel safe."),
        BrainShelfEntry(id: "daughter/letters/2026-11-05.md", date: "2026-11-05", title: "November 5, 2026",
                        context: "10 weeks before you arrive", prompt: "What should she know about today?",
                        text: "Today I built the shelf for your books and put it up crooked. I left it that way.\n\nYou should know that most things I make for you will be a little crooked and meant completely."),
    ])

    static let takes = BrainShelf(kind: "takes", entries: [
        BrainShelfEntry(id: "takes/2026-W45.md", date: "2026-11-06", context: "Your take",
                        prompt: "What makes a tool worth keeping?",
                        text: "The ones I keep are the ones I stop noticing. If I have to admire it, it is still in my way.",
                        group: "AI & the industry"),
        BrainShelfEntry(id: "takes/2026-W45.md", date: "2026-11-04", prompt: "What makes a tool worth keeping?",
                        text: "I agree with half of this. Small tools win when one person holds the whole picture.\n\nOnce three people share it, the seams between the tools become the work.",
                        group: "AI & the industry",
                        source: BrainShelfSource(module: .wiki, id: "wiki/sources/small-tools.md", title: "Small tools, loosely joined")),
        BrainShelfEntry(id: "takes/2026-W44.md", date: "2026-10-29", prompt: "Where does patience pay?",
                        text: "Bread, mostly. And any conversation where I already know what I want to say.",
                        group: "Craft",
                        source: BrainShelfSource(title: "The long proof")),
    ])

    static let memories = BrainShelf(kind: "memories", entries: [
        BrainShelfEntry(id: "memories/2026-10-12.md", date: "2026-10-12", context: "The lake house",
                        prompt: "What did summer sound like when you were ten?",
                        text: "Screen doors. Every house on the lake had one and none of them closed quietly.\n\nI could tell whose mother was calling by the pitch of the slam."),
        BrainShelfEntry(id: "memories/2026-11-01.md", date: "2026-11-01", context: "Uncle Teo",
                        prompt: "Who taught you to fix things?",
                        text: "Teo never explained anything. He handed me the wrong wrench and waited until I asked for the right one."),
    ])

    static func shelf(_ kind: BrainShelfKind) -> BrainShelf {
        switch kind {
        case .letters: letters
        case .takes: takes
        case .memories: memories
        }
    }

    static let homeRows = BrainShelfLayout.homeRows([.letters: 2, .takes: 3, .memories: 2])

    /// A page ready to show: `NavigationStack { BrainShelfFixtures.page(.takes) }`.
    @MainActor
    static func page(_ kind: BrainShelfKind, cached: Bool = false) -> BrainShelfView {
        BrainShelfView(viewModel: BrainShelfViewModel(kind: kind, shelf: shelf(kind), cached: cached))
    }
}

#Preview("Letters") { NavigationStack { BrainShelfFixtures.page(.letters) } }
#Preview("My takes") { NavigationStack { BrainShelfFixtures.page(.takes) } }
#Preview("Memories, offline") { NavigationStack { BrainShelfFixtures.page(.memories, cached: true) } }
#Preview("Empty") {
    NavigationStack { BrainShelfView(viewModel: BrainShelfViewModel(kind: .letters, shelf: BrainShelf())) }
}
#Preview("Your writing") {
    NavigationStack {
        ScrollView { BrainShelfHomeSection(rows: BrainShelfFixtures.homeRows).padding(16) }
            .background(Color.hxCanvas)
    }
}
#endif
