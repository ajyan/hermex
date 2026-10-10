import AppIntents
import SwiftUI
import WidgetKit

/// Home Screen "Ask Atlas" widget: a launcher into the app's existing new-chat,
/// voice, and call deep links. It reads no server data, so it never needs the
/// active server's credentials and stays correct across server switches.
struct AtlasHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AtlasAskWidget", provider: AtlasHomeProvider()) { _ in
            AtlasHomeWidgetView()
                .containerBackground(for: .widget) {
                    Color(uiColor: .secondarySystemGroupedBackground)
                }
        }
        .configurationDisplayName("Ask Atlas")
        .description("Start a chat, dictate, or call Atlas.")
        .supportedFamilies([.systemMedium, .accessoryCircular])
    }
}

struct AtlasHomeEntry: TimelineEntry {
    let date: Date
}

struct AtlasHomeProvider: TimelineProvider {
    func placeholder(in context: Context) -> AtlasHomeEntry { AtlasHomeEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (AtlasHomeEntry) -> Void) {
        completion(AtlasHomeEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AtlasHomeEntry>) -> Void) {
        completion(Timeline(entries: [AtlasHomeEntry(date: .now)], policy: .never))
    }
}

private struct AtlasHomeWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                AtlasMark(lineWidth: 1.6).frame(width: 26, height: 26)
            }
            .widgetURL(HermesDeepLink.newChatURL)
        default:
            AtlasAskMediumView()
        }
    }
}

private struct AtlasAskMediumView: View {
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                AtlasMark(lineWidth: 1.7).frame(width: 18, height: 18).widgetAccentable()
                Text("Atlas").font(.subheadline.weight(.semibold))
                Spacer()
            }

            Link(destination: HermesDeepLink.newChatURL ?? Self.fallbackURL) {
                HStack(spacing: 8) {
                    Text("Ask Atlas…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 32, height: 32)
                        .background(Color.primary, in: Circle())
                        .widgetAccentable()
                }
                .padding(.leading, 16)
                .padding(.trailing, 6)
                .frame(height: 44)
                .background(Color.primary.opacity(0.1), in: Capsule())
            }

            HStack(spacing: 8) {
                AtlasActionChip(symbol: "mic", label: "Dictate", url: HermesDeepLink.newChatVoiceURL)
                AtlasActionChip(symbol: "phone", label: "Call Atlas", url: HermesDeepLink.newCallURL)
                AtlasActionChip(symbol: "square.and.pencil", label: "New chat", url: HermesDeepLink.newChatURL)
            }
        }
    }

    fileprivate static let fallbackURL = URL(string: "\(HermesDeepLink.scheme)://")!
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
