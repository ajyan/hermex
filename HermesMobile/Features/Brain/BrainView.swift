import SwiftUI

/// The Brain: the Second Brain's people (CRM), read-only. A searchable list of
/// contacts; a row pushes that person's Markdown file. Pushed onto the shell's
/// navigation stack, so it must not own a `NavigationStack` of its own.
/// Copy is English-only (personal fork).
struct BrainView: View {
    private let client: any BrainDataClient
    private let onAPIError: (Error) -> Void
    @State private var viewModel: BrainPeopleViewModel

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        let client = APIClientBrainAdapter(apiClient: APIClient(baseURL: server))
        self.client = client
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: BrainPeopleViewModel(client: client, onAPIError: onAPIError))
    }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: "Brain"))
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
                Label { Text(verbatim: "No Brain on This Server") } icon: { Image(systemName: "brain") }
            } description: {
                Text(verbatim: "This server doesn't serve the Second Brain. It needs the Brain API from your hermes-webui fork.")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label { Text(verbatim: "Couldn't Load People") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                Text(message)
            } actions: {
                Button { Task { await viewModel.load() } } label: { Text(verbatim: "Try Again") }
            }
        case .loaded:
            peopleList
        }
    }

    private var peopleList: some View {
        let people = viewModel.filteredPeople
        return List(people) { person in
            NavigationLink {
                BrainPersonView(person: person, client: client, onAPIError: onAPIError)
            } label: {
                BrainPersonRow(person: person)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if people.isEmpty {
                if viewModel.query.isEmpty {
                    ContentUnavailableView {
                        Label { Text(verbatim: "No People Yet") } icon: { Image(systemName: "person.2") }
                    } description: {
                        Text(verbatim: "Contacts appear here once crm/contacts has notes.")
                    }
                } else {
                    ContentUnavailableView.search(text: viewModel.query)
                }
            }
        }
        .searchable(
            text: $viewModel.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(verbatim: "Search people")
        )
        .autocorrectionDisabled()
        .refreshable { await viewModel.load() }
    }
}

/// One contact row: name and relationship.
private struct BrainPersonRow: View {
    let person: BrainPerson

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(person.name)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
            if !person.relationship.isEmpty {
                Text(person.relationship)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One person's contact file, rendered as Markdown.
struct BrainPersonView: View {
    @State private var viewModel: BrainPersonViewModel

    init(person: BrainPerson, client: any BrainDataClient, onAPIError: @escaping (Error) -> Void) {
        _viewModel = State(initialValue: BrainPersonViewModel(person: person, client: client, onAPIError: onAPIError))
    }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: viewModel.person.name))
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await viewModel.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable, .failed:
            ContentUnavailableView {
                Label { Text(verbatim: "Couldn't Load Contact") } icon: { Image(systemName: "exclamationmark.triangle") }
            } description: {
                if case .failed(let message) = viewModel.state { Text(message) }
            } actions: {
                Button { Task { await viewModel.load() } } label: { Text(verbatim: "Try Again") }
            }
        case .loaded(let body):
            ScrollView {
                MarkdownRenderer(content: body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .refreshable { await viewModel.load() }
        }
    }
}
