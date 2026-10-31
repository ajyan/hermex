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
                    Color.hxSurface
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
                .font(AppFont.footnote(weight: .semibold))
                .widgetAccentable()
            Text("Goals")
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
            Spacer()
            if let goals = entry.goals {
                if goals.syncFailed {
                    Label("Couldn't sync", systemImage: "exclamationmark.triangle")
                        .font(AppFont.caption())
                        .foregroundStyle(Color.hxDanger)
                } else if goals.streakDays > 0, !entry.isStale {
                    Text("\(goals.streakDays)-day streak")
                        .font(AppFont.caption())
                        .foregroundStyle(Color.hxTextSecondary)
                }
            }
        }
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(AppFont.subheadline())
            .foregroundStyle(Color.hxTextSecondary)
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
                    // The whole row's height takes the tap, though the widget keeps rows compact.
                    mark
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.isDone ? "Undo \(item.action)" : "Mark \(item.action) done")
            }
            Text(item.action)
                .font(AppFont.subheadline())
                .foregroundStyle(Color.hxTextPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            AtlasGoalPips(done: item.weekCount, target: item.target)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AtlasGoalPips.spoken(done: item.weekCount, target: item.target))
        }
        .frame(minHeight: 28)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var mark: some View {
        if item.isDone {
            Image(systemName: "checkmark.circle.fill")
                .font(AppFont.title3())
                .foregroundStyle(Color.hxSuccess)
        } else {
            Image(systemName: "circle")
                .font(AppFont.title3())
                .foregroundStyle(Color.hxTextSecondary)
        }
    }
}

/// The week's count as the Brief's pips (`DeckDot`, shared with the app): one per check-in of
/// the target, filled once done. Columns narrow so a long target still fits the row.
struct AtlasGoalPips: View {
    let done: Int
    let target: Int

    /// At most this wide, so the commitment's name keeps its room.
    static let maxWidth: CGFloat = 140

    var body: some View {
        let count = max(target, done)
        let column = Self.column(count: count)
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                DeckDot(state: index < done ? "done" : "missed", ink: Color.hxSuccess, column: column)
            }
        }
    }

    /// A day column's width, as the Brief's grid shares its seven when there are more pips.
    static func column(count: Int) -> CGFloat {
        guard count > 0 else { return DeckDots.dot }
        return max(DeckDots.dot, min(20, maxWidth / CGFloat(count)))
    }

    static func spoken(done: Int, target: Int) -> String {
        target > 0 ? "\(done) of \(target) this week" : "\(done) this week"
    }
}
