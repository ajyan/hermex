import AppIntents
import SwiftUI
import WidgetKit

/// Home Screen "Ask Atlas" widget: an ask bar into the app's new-chat and voice deep
/// links, plus the most recent sessions the app last published (`AtlasWidgetRecents`).
/// It never calls the server; each recent row opens through its own server's route.
struct AtlasHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AtlasWidgetRecents.widgetKind, provider: AtlasHomeProvider()) { entry in
            AtlasHomeWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(uiColor: .secondarySystemGroupedBackground)
                }
        }
        .configurationDisplayName("Ask Atlas")
        .description("Start a chat, dictate, or jump back into a recent one.")
        .supportedFamilies([.systemMedium, .accessoryCircular])
    }
}

struct AtlasHomeEntry: TimelineEntry {
    let date: Date
    let recents: AtlasWidgetRecents?
}

struct AtlasHomeProvider: TimelineProvider {
    func placeholder(in context: Context) -> AtlasHomeEntry { AtlasHomeEntry(date: .now, recents: nil) }

    func getSnapshot(in context: Context, completion: @escaping (AtlasHomeEntry) -> Void) {
        completion(AtlasHomeEntry(date: .now, recents: AtlasWidgetRecentsStore().load()))
    }

    /// The app reloads this when recents change; the periodic refresh only keeps the
    /// relative times honest.
    func getTimeline(in context: Context, completion: @escaping (Timeline<AtlasHomeEntry>) -> Void) {
        let entry = AtlasHomeEntry(date: .now, recents: AtlasWidgetRecentsStore().load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

private struct AtlasHomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: AtlasHomeEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                AtlasMark(lineWidth: 1.6).frame(width: 26, height: 26)
            }
            .widgetURL(HermesDeepLink.newChatURL)
        default:
            AtlasAskMediumView(entry: entry)
        }
    }
}

private struct AtlasAskMediumView: View {
    let entry: AtlasHomeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            askBar

            if let recents = entry.recents, !recents.sessions.isEmpty {
                ForEach(recents.sessions, id: \.id) { session in
                    AtlasRecentRow(session: session, server: recents.server, now: entry.date)
                }
            } else {
                HStack(spacing: 8) {
                    AtlasActionChip(symbol: "phone", label: "Call Atlas", url: HermesDeepLink.newCallURL)
                    AtlasActionChip(symbol: "square.and.pencil", label: "New chat", url: HermesDeepLink.newChatURL)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var askBar: some View {
        HStack(spacing: 8) {
            Link(destination: HermesDeepLink.newChatURL ?? Self.fallbackURL) {
                HStack(spacing: 8) {
                    AtlasMark(lineWidth: 1.5).frame(width: 16, height: 16).widgetAccentable()
                    Text("Ask Atlas…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }

            Link(destination: HermesDeepLink.newChatVoiceURL ?? Self.fallbackURL) {
                Image(systemName: "mic")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.1), in: Circle())
            }
            .accessibilityLabel("Dictate")
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: 42)
        .background(Color.primary.opacity(0.1), in: Capsule())
    }

    fileprivate static let fallbackURL = URL(string: "\(HermesDeepLink.scheme)://")!
}

private struct AtlasRecentRow: View {
    let session: AtlasWidgetRecents.Session
    let server: URL
    let now: Date

    var body: some View {
        Link(destination: HermesDeepLink.webuiSessionURL(server: server, sessionID: session.id)
            ?? AtlasAskMediumView.fallbackURL) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Text(session.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let age = Self.age(of: session.lastActivity, now: now) {
                    Text(age)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
        }
    }

    /// "12m", "2h", "3d": one abbreviated unit, localized.
    private static func age(of date: Date, now: Date) -> String? {
        let interval = max(now.timeIntervalSince(date), 60)
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.minute, .hour, .day, .weekOfMonth]
        return formatter.string(from: interval)
    }
}

private struct AtlasActionChip: View {
    let symbol: String
    let label: String
    let url: URL?

    var body: some View {
        Link(destination: url ?? AtlasAskMediumView.fallbackURL) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(Color.primary.opacity(0.1), in: Capsule())
        }
        .accessibilityLabel(label)
    }
}

/// Control Center (and Action button) control that opens Atlas on a new chat.
struct AtlasNewChatControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "AtlasNewChatControl") {
            ControlWidgetButton(action: OpenAtlasNewChatIntent()) {
                Label("New Chat", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Atlas Chat")
        .description("Open Atlas on a new chat.")
    }
}

/// Opens the app's new-chat deep link. Lives in the widget extension only; the app
/// handles the URL through the same path as the New Chat App Intent.
struct OpenAtlasNewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "New Atlas Chat"
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(HermesDeepLink.newChatURL ?? AtlasAskMediumView.fallbackURL))
    }
}

/// The Atlas mark: a globe with one tilted orbit.
private struct AtlasMark: View {
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle().stroke(lineWidth: lineWidth)
                Ellipse()
                    .stroke(lineWidth: lineWidth)
                    .frame(width: side, height: side * 0.4)
                    .rotationEffect(.degrees(-25))
            }
            .frame(width: side, height: side)
        }
        .accessibilityHidden(true)
    }
}
