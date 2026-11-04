import SwiftData
import SwiftUI

extension VoiceCallSource {
    /// The Brain page this memory opens: a note by its vault path, a person by their contact file
    /// or name (the server resolves either). Nil for book highlights and notes outside the Brain.
    var brainRoute: BrainRoute? {
        let page = path.map(VoiceCallSources.vaultKey(of:)) ?? id
        switch kind {
        case .person: return .page(.people, path.map(VoiceCallSources.vaultKey(of:)) ?? label)
        case .journal: return .page(.journal, page)
        case .wiki: return .page(.wiki, page)
        case .article: return .page(.articles, page)
        case .book, .note: return nil
        }
    }
}

/// The memories a turn of a call drew on, in a sheet over the call: the list, and each memory's
/// Brain page. The call goes on underneath, and closing the sheet returns to it.
struct VoiceCallSourcesSheet: View {
    struct Request: Identifiable {
        let id = UUID()
        /// The turn's memories when the sheet opened; a new turn doesn't change an open sheet.
        let sources: [VoiceCallSource]
        /// The memory tapped, opened at once over the list; nil opens the list.
        let opened: VoiceCallSource?
    }

    let request: Request
    let server: URL
    let onAPIError: (Error) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var path: [BrainRoute]

    init(request: Request, server: URL, onAPIError: @escaping (Error) -> Void) {
        self.request = request
        self.server = server
        self.onAPIError = onAPIError
        _path = State(initialValue: request.opened?.brainRoute.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List(request.sources) { source in
                if let route = source.brainRoute {
                    NavigationLink(value: route) { row(source) }
                } else {
                    row(source)
                }
            }
            .hxNavigationTitle(String(localized: "Sources"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: BrainRoute.self, destination: destination)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ source: VoiceCallSource) -> some View {
        HStack {
            HXChip(paper: source.kind.paper, symbol: source.kind.symbol, label: source.label)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func destination(_ route: BrainRoute) -> some View {
        switch route {
        case .page(let module, let id) where BrainHighlightsBookView.isBook(module: module, id: id):
            BrainHighlightsBookView(id: id, server: server, modelContext: modelContext, onAPIError: onAPIError)
        case .page(let module, let id):
            BrainReaderView(module: module, id: id, server: server, modelContext: modelContext,
                            onAPIError: onAPIError, push: { path.append($0) })
        case .pageInHub(let module, let id, let hub):
            BrainReaderView(module: module, id: id, hub: hub, server: server, modelContext: modelContext,
                            onAPIError: onAPIError, push: { path.append($0) })
        case .moduleTagged(let module, let tag):
            BrainModuleListView(module: module, tag: tag, server: server, modelContext: modelContext,
                                onAPIError: onAPIError, push: { path.append($0) })
        case .module(let module):
            BrainModuleListView(module: module, server: server, modelContext: modelContext,
                                onAPIError: onAPIError, push: { path.append($0) })
        case .bite, .searchAll, .review, .prep:
            // A page's links and tags reach only the routes above.
            EmptyView()
        }
    }
}
