import SwiftUI

/// Read-only list of the sidecar's current rules.
struct AtlasRulesView: View {
    let server: URL

    @State private var rules: [AtlasRule] = []
    @State private var errorMessage: String?
    @State private var isLoaded = false

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.hxWarning)
            }
            ForEach(rules, id: \.id) { rule in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(rule.id).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(rule.action.capitalized)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.hxSeparator.opacity(0.4), in: Capsule())
                    }
                    Text(rule.description)
                        .font(.footnote)
                        .foregroundStyle(.hxTextSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .overlay {
            if isLoaded, rules.isEmpty, errorMessage == nil {
                ContentUnavailableView("No rules", systemImage: "list.bullet.clipboard")
            }
        }
        .navigationTitle("Rules")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let snapshot = try await APIClient(baseURL: server).atlasRules()
            rules = snapshot.rules
            errorMessage = snapshot.error
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoaded = true
    }
}
