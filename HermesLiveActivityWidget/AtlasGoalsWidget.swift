import AppIntents
import SwiftUI
import WidgetKit

/// Home Screen "Goals" widget: today's commitments from the snapshot the app publishes
/// (`AtlasWidgetGoals`), each with a check button that records it on the server through
/// `GoalWidgetCheckInIntent` (or, on a done row, clears it). Tapping elsewhere opens Goals.
struct AtlasGoalsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AtlasWidgetGoals.widgetKind, provider: AtlasGoalsProvider()) { entry in
            AtlasGoalsWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(uiColor: .secondarySystemGroupedBackground)
                }
        }
        .configurationDisplayName("Goals")
        .description("Check off today's goal commitments and see your streak.")
        .supportedFamilies([.systemMedium])
    }
}

struct AtlasGoalsEntry: TimelineEntry {
    let date: Date
    let goals: AtlasWidgetGoals?

    /// The phone's day has turned since the app saved the snapshot (`AtlasWidgetGoals.isStale`),
    /// so its check-ins may land on a day the server has left.
    var isStale: Bool { goals?.isStale(at: date) ?? false }
}

struct AtlasGoalsProvider: TimelineProvider {
    func placeholder(in context: Context) -> AtlasGoalsEntry { AtlasGoalsEntry(date: .now, goals: nil) }

    func getSnapshot(in context: Context, completion: @escaping (AtlasGoalsEntry) -> Void) {
        completion(AtlasGoalsEntry(date: .now, goals: AtlasWidgetGoalsStore().load()))
    }

    /// The app reloads this when goals change; the midnight entry turns a finished
    /// day's snapshot stale.
    func getTimeline(in context: Context, completion: @escaping (Timeline<AtlasGoalsEntry>) -> Void) {
        let goals = AtlasWidgetGoalsStore().load()
        let midnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(24 * 60 * 60))
        completion(Timeline(
            entries: [AtlasGoalsEntry(date: .now, goals: goals), AtlasGoalsEntry(date: midnight, goals: goals)],
            policy: .never
        ))
    }
}

private struct AtlasGoalsWidgetView: View {
    let entry: AtlasGoalsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let goals = entry.goals, !entry.isStale {
                if goals.items.isEmpty {
                    message("Nothing due today.")
                } else {
                    ForEach(goals.items) { item in
                        AtlasGoalRow(item: item)
                    }
                }
            } else if entry.goals != nil {
                message("Open Atlas to load today's goals.")
            } else {
                message("Open Goals in Atlas to show them here.")
            }
            Spacer(minLength: 0)
        }
        .widgetURL(HermesDeepLink.goalsURL)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "target")
                .font(.system(size: 13, weight: .semibold))
                .widgetAccentable()
            Text("Goals")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if let goals = entry.goals {
                if goals.syncFailed {
                    Label("Couldn't sync", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if goals.streakDays > 0, !entry.isStale {
                    Text("\(goals.streakDays)-day streak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AtlasGoalRow: View {
    let item: AtlasWidgetGoals.Item

    var body: some View {
        HStack(spacing: 10) {
            if item.isDone && !item.isUndoable {
                // Only the row's source (such as Prep) counts today; clearing would change nothing.
                mark
                    .accessibilityLabel("Done")
            } else {
                Button(intent: GoalWidgetCheckInIntent(slug: item.slug, commitment: item.commitment, done: !item.isDone)) {
                    mark
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.isDone ? "Undo \(item.action)" : "Mark \(item.action) done")
            }
            Text(item.action)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: "\(item.weekCount)/\(item.target)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(item.weekCount) of \(item.target) this week")
        }
        .frame(minHeight: 28)
    }

    @ViewBuilder
    private var mark: some View {
        if item.isDone {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.green)
        } else {
            Image(systemName: "circle")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        }
    }
}
