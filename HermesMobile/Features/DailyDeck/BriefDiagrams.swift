import SwiftUI

/// The vault's interactive diagrams for technical Brief cards. `diagrams/index.json` names each
/// diagram's topic and the cards it belongs to, by a card's `ref.link` (without `.md`) or `ref.pool`;
/// `diagrams/<topic>.html` holds the diagram as an `atlas-ui` fragment, rendered like an interactive answer.
struct BriefDiagramIndex: Decodable, Equatable {
    struct Entry: Decodable, Equatable, Identifiable {
        let topic: String
        let title: String?
        let keys: [String]

        var id: String { topic }
        var fragmentPath: String { "\(BriefDiagramIndex.directory)/\(topic).html" }
    }

    static let directory = "diagrams"
    static let path = "\(directory)/index.json"
    static let empty = BriefDiagramIndex(diagrams: [])

    /// Entries whose topic is a safe file name; anything else is dropped, never the index.
    let diagrams: [Entry]

    init(diagrams: [Entry]) { self.diagrams = diagrams }

    private enum CodingKeys: String, CodingKey { case diagrams }

    /// An entry that failed to decode becomes nil instead of failing the index.
    private struct MaybeEntry: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        diagrams = ((try? c.decodeIfPresent([MaybeEntry].self, forKey: .diagrams)) ?? [])
            .compactMap(\.entry)
            .filter { Self.isSafeTopic($0.topic) }
    }

    static func decode(_ content: String) -> BriefDiagramIndex {
        (try? JSONDecoder().decode(BriefDiagramIndex.self, from: Data(content.utf8))) ?? .empty
    }

    /// The diagram for a card: the first entry naming the card's link or pool key.
    func diagram(for card: DeckCard) -> Entry? {
        let cardKeys = [card.link, card.pool].compactMap { $0.map(Self.normalized) }
        guard !cardKeys.isEmpty else { return nil }
        return diagrams.first { entry in entry.keys.contains { cardKeys.contains(Self.normalized($0)) } }
    }

    /// `/wiki/sources/kafka.md` and `wiki/sources/kafka` are the same key.
    static func normalized(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return (trimmed.hasSuffix(".md") ? String(trimmed.dropLast(3)) : trimmed).lowercased()
    }

    /// Lowercase letters, digits, and hyphens only, so a topic can't reach outside `diagrams/`.
    static func isSafeTopic(_ topic: String) -> Bool {
        !topic.isEmpty && topic.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }
}

/// A vault diagram, opened from "Open the diagram" on a Brief card or a Prep lesson: the live `atlas-ui` tool in
/// an interactive answer card. Neither screen has a composer, so the tool's "Ask Atlas" does nothing here.
struct DiagramSheet: View {
    let title: String
    /// Reads the diagram's `atlas-ui` fragment.
    let load: @MainActor () async throws -> String

    @Environment(\.dismiss) private var dismiss
    @State private var fragment: String?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(16)
                    .frame(maxWidth: .infinity)
            }
            .background(Color.hxCanvas.ignoresSafeArea())
            .navigationTitle(Text(verbatim: title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Done") }
                }
            }
            .task(id: attempt) { await load() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var content: some View {
        if let fragment {
            InteractiveAnswerCard(
                block: .card(fragment: fragment, title: InteractiveAnswerBlock.title(in: fragment) ?? title),
                source: fragment
            )
        } else if failed {
            ContentUnavailableView {
                Label { Text(verbatim: "Couldn't load the diagram") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(verbatim: "Check your connection to the server.")
            } actions: {
                Button { attempt += 1 } label: { Text(verbatim: "Try Again") }
                    .buttonStyle(.bordered)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 240)
                .accessibilityLabel(Text(verbatim: "Loading the diagram"))
        }
    }

    private func load() async {
        failed = false
        do {
            fragment = try await load()
        } catch is CancellationError {
            // The sheet closed.
        } catch {
            failed = true
        }
    }
}
