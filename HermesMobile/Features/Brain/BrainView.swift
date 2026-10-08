import SwiftUI

/// The Brain tab: the relationship CRM from the second brain, read-only.
/// A searchable list of contacts; tapping a row pushes their full profile
/// (the raw contact note, rendered as markdown).
struct BrainView: View {
    let server: URL
    let onAPIError: (Error) -> Void

    @State private var viewModel: BrainPeopleViewModel

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        self.server = server
        self.onAPIError = onAPIError
        _viewModel = State(initialValue: BrainPeopleViewModel(
            client: APIClientBrainAdapter(apiClient: APIClient(baseURL: server))
        ))
    }

    var body: some View {
        NavigationStack {
            listContent
                .navigationTitle("Brain")
                .searchable(text: $viewModel.query, prompt: "Name, relationship, or tag")
                .navigationDestination(for: BrainPersonSummary.self) { person in
                    BrainPersonDetailView(
                        person: person,
                        detail: viewModel.detail,
                        onRetry: {
                            Task { await viewModel.loadDetail(for: person) }
                        }
                    )
                }
        }
        .background(Color.hxCanvas.ignoresSafeArea())
        .task { await viewModel.loadList() }
    }

    @ViewBuilder
    private var listContent: some View {
        switch viewModel.list {
        case .loading:
            ProgressView("Loading contacts…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Brain", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task { await viewModel.loadList() }
                }
            }
        case .loaded:
            peopleList
        }
    }

    private var peopleList: some View {
        Group {
            if viewModel.filteredPeople.isEmpty {
                ContentUnavailableView.search
            } else {
                List(viewModel.filteredPeople) { person in
                    NavigationLink(value: person) {
                        BrainPersonRow(person: person)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable {
                    await viewModel.loadList()
                }
            }
        }
        .background(Color.hxCanvas)
    }
}

/// One contact row: name, relationship line, and the next birthday when known.
struct BrainPersonRow: View {
    let person: BrainPersonSummary

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !person.relationship.isEmpty {
                    Text(person.relationship)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let days = daysUntilNextBirthday {
                birthdayLabel(days)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var avatar: some View {
        Text(initials)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.accentColor.opacity(0.85)))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func birthdayLabel(_ days: Int) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Image(systemName: "gift")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(days == 0 ? "Today" : "\(days)d")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(days == 0 ? Color.hxSuccess : .secondary)
        }
        .accessibilityHidden(true)
    }

    /// Days from today to the next birthday occurrence, nil when unknown.
    private var daysUntilNextBirthday: Int? {
        guard let iso = person.nextBirthday else { return nil }
        let date: Date?
        if let parsed = ISO8601DateFormatter().date(from: iso) {
            date = parsed
        } else {
            // The server returns a bare ISO date (no time component).
            date = Self.bareDateFormatter.date(from: iso)
        }
        guard let date else { return nil }
        let today = Calendar.current.startOfDay(for: .now)
        let target = Calendar.current.startOfDay(for: date)
        return Calendar.current.dateComponents([.day], from: today, to: target).day
    }

    private static let bareDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var initials: String {
        let parts = person.name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

/// One contact's full profile: the raw contact note as markdown.
struct BrainPersonDetailView: View {
    let person: BrainPersonSummary
    let detail: BrainDetailState
    let onRetry: () -> Void

    var body: some View {
        content
            .navigationTitle(person.name)
            .navigationBarTitleDisplayMode(.large)
            .background(Color.hxCanvas.ignoresSafeArea())
    }

    @ViewBuilder
    private var content: some View {
        switch detail {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Profile", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", action: onRetry)
            }
        case .loaded(let response):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header(response)
                    Divider()
                    MarkdownRenderer(content: response.content ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                }
                .padding(.top, 8)
            }
            .refreshable { onRetry() }
        }
    }

    @ViewBuilder
    private func header(_ response: BrainPersonDetailResponse) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !((response.relationship)?.isEmpty ?? true) {
                Text(response.relationship ?? "")
                    .font(.headline)
            }
            if !(response.tags ?? []).isEmpty {
                Text((response.tags ?? []).joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal)
    }
}
