import SwiftUI

/// Read-only list of the sidecar's current rules.
struct AtlasRulesView: View {
    let server: URL

    @State private var rules: [AtlasRule] = []
    /// What the server says is wrong with the rules file.
    @State private var errorMessage: String?
    /// Why the last load failed; the rules already shown stay.
    @State private var loadError: String?
    @State private var isLoaded = false

    var body: some View {
        List {
            if let loadError, !rules.isEmpty {
                HXFailedView(title: String(localized: "Couldn't load rules"), message: loadError, style: .inline) {
                    Task { await load() }
                }
                .buttonStyle(.borderless)
                .listRowBackground(Color.hxSurface)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.hxWarning)
                    .listRowBackground(Color.hxSurface)
            }
            ForEach(rules, id: \.id) { rule in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(rule.id).font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                        Spacer()
                        HXChip(paper: .tool, label: rule.action.capitalized)
                    }
                    Text(rule.description)
                        .font(AppFont.footnote())
                        .foregroundStyle(.hxTextSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(Color.hxSurface)
        }
        .scrollContentBackground(.hidden)
        .background(Color.hxCanvas.ignoresSafeArea())
        .overlay {
            if isLoaded, rules.isEmpty {
                if let loadError {
                    HXFailedView(title: String(localized: "Couldn't load rules"), message: loadError) {
                        Task { await load() }
                    }
                } else if errorMessage == nil {
                    ContentUnavailableView("No rules", systemImage: "list.bullet.clipboard")
                }
            }
        }
        .hxNavigationTitle(String(localized: "Rules"))
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let snapshot = try await APIClient(baseURL: server).atlasRules()
            rules = snapshot.rules
            errorMessage = snapshot.error
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
        isLoaded = true
    }
}
