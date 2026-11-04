import AppIntents
import SwiftUI
import WidgetKit

/// Home and Lock Screen "Tonight" widget: tonight's meal from the snapshot the app publishes
/// (`AtlasWidgetMeals`), with an Eating it button that logs it through `MealsWidgetLogIntent`.
/// Tapping elsewhere opens Meals.
struct AtlasMealsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AtlasWidgetMeals.widgetKind, provider: AtlasMealsProvider()) { entry in
            AtlasMealsWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.hxSurface
                }
        }
        .configurationDisplayName("Tonight")
        .description("Tonight's dinner, and a tap to log it when you sit down.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct AtlasMealsEntry: TimelineEntry {
    let date: Date
    let meals: AtlasWidgetMeals?

    /// The snapshot when it's for this entry's day; after midnight, nothing until the app loads.
    var shown: AtlasWidgetMeals? {
        guard let meals, meals.day == AtlasWidgetMeals.localDay(date) else { return nil }
        return meals
    }
}

struct AtlasMealsProvider: TimelineProvider {
    func placeholder(in context: Context) -> AtlasMealsEntry { AtlasMealsEntry(date: .now, meals: nil) }

    func getSnapshot(in context: Context, completion: @escaping (AtlasMealsEntry) -> Void) {
        completion(AtlasMealsEntry(date: .now, meals: AtlasWidgetMealsStore().load()))
    }

    /// Now and the next local midnight, when the day's meal stops showing; the app reloads it
    /// whenever the week changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<AtlasMealsEntry>) -> Void) {
        let meals = AtlasWidgetMealsStore().load()
        let calendar = Calendar.current
        let now = Date.now
        let midnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        completion(Timeline(entries: [AtlasMealsEntry(date: now, meals: meals), AtlasMealsEntry(date: midnight, meals: meals)],
                            policy: .atEnd))
    }
}

private struct AtlasMealsWidgetView: View {
    let entry: AtlasMealsEntry
    @Environment(\.widgetFamily) private var family

    private var paper: HermexPaper { .kitchen }

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                lockScreen
            } else {
                home
            }
        }
        .widgetURL(HermesDeepLink.mealsURL)
    }

    // MARK: Home Screen

    private var home: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "fork.knife")
                    .font(AppFont.footnote(weight: .semibold))
                    .widgetAccentable()
                Text(verbatim: "Tonight")
                    .font(AppFont.footnote(weight: .semibold))
                Spacer(minLength: 4)
                if let meals = entry.shown, meals.servings != 3, !meals.dishes.isEmpty {
                    Text(verbatim: "Serves \(meals.servings)")
                        .font(AppFont.caption2(weight: .semibold))
                }
            }
            .foregroundStyle(paper.glow)
            if let meals = entry.shown, let main = meals.dishes.first {
                Text(verbatim: main.name)
                    .font(AppFont.display(style: .headline, weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .lineLimit(2)
                let sides = meals.dishes.dropFirst().map(\.name)
                if !sides.isEmpty {
                    Text(verbatim: sides.joined(separator: " · "))
                        .font(AppFont.caption())
                        .foregroundStyle(Color.hxTextSecondary)
                        .lineLimit(family == .systemSmall ? 1 : 2)
                }
                Spacer(minLength: 4)
                logRow(meals)
            } else {
                Text(verbatim: entry.shown == nil ? "Open Meals in Atlas to show tonight here." : "Nothing planned tonight.")
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextSecondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func logRow(_ meals: AtlasWidgetMeals) -> some View {
        if meals.logged {
            Label { Text(verbatim: "Logged") } icon: { Image(systemName: "checkmark.circle.fill") }
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(paper.glow)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Button(intent: MealsWidgetLogIntent()) {
                    Text(verbatim: "Eating it")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(paper.onGlow)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(paper.glow, in: Capsule())
                }
                .buttonStyle(.plain)
                if meals.syncFailed {
                    Text(verbatim: "Couldn't log. Try again.")
                        .font(AppFont.caption2())
                        .foregroundStyle(Color.hxTextSecondary)
                }
            }
        }
    }

    // MARK: Lock Screen

    private var lockScreen: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label { Text(verbatim: "Tonight") } icon: { Image(systemName: "fork.knife") }
                .font(AppFont.caption(weight: .semibold))
                .widgetAccentable()
            if let meals = entry.shown, let main = meals.dishes.first {
                Text(verbatim: main.name)
                    .font(AppFont.headline())
                    .lineLimit(1)
                Text(verbatim: meals.logged ? "Logged" : meals.dishes.dropFirst().map(\.name).joined(separator: " · "))
                    .font(AppFont.caption())
                    .lineLimit(1)
            } else {
                Text(verbatim: entry.shown == nil ? "Open Meals" : "Nothing planned")
                    .font(AppFont.headline())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
