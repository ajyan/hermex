import Foundation
import Observation
import SwiftUI

/// The People screen's sections above Everyone, shaped from `GET /api/brain/people/home`
/// with the day math done once, when the home loads.
enum BrainPeopleLayout {
    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        let subtitle: String
        /// "6d", "4 mo", "in 3d"; empty when the date is missing.
        let trailing: String
        /// Due rows wear the opener glow on `trailing`.
        let isDue: Bool
        let accessibilityLabel: String
    }

    struct Section: Equatable, Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    /// Due, Birthdays soon and Recently seen, in that order, each dropped when empty.
    static func sections(_ home: BrainPeopleHome, today: Date, calendar: Calendar = .current) -> [Section] {
        let days = BrainPersonLayout.DayMath(today: today, calendar: calendar)
        let all = [
            Section(title: "Due for a catch-up", rows: home.due.map { seenRow($0, isDue: true, days: days) }),
            Section(title: "Birthdays soon", rows: home.birthdays.compactMap { birthdayRow($0, days: days) }),
            Section(title: "Recently seen", rows: home.recent.map { seenRow($0, isDue: false, days: days) }),
        ]
        return all.filter { !$0.rows.isEmpty }
    }

    /// A due row's usual gap: "Every day", "Every 5 days", "Every 3 wk", "Every 6 mo", "Every 2 yr".
    static func cadence(days: Int) -> (shown: String, spoken: String) {
        let days = max(1, days)
        switch days {
        case 1: return ("Every day", "every day")
        case ..<14: return ("Every \(days) days", "every \(days) days")
        case ..<60: let w = (days + 3) / 7; return ("Every \(w) wk", "every \(w) weeks")
        case ..<730: let m = (days + 15) / 30; return ("Every \(m) mo", m == 1 ? "every month" : "every \(m) months")
        default: let y = (days + 182) / 365; return ("Every \(y) yr", y == 1 ? "every year" : "every \(y) years")
        }
    }

    /// "today", then "6d" under two weeks, "3 wk" under 60 days, "4 mo" under two years, then "2 yr".
    static func elapsed(days: Int) -> String {
        let days = max(0, days)
        switch days {
        case 0: return "today"
        case ..<14: return "\(days)d"
        case ..<60: return "\(days / 7) wk"
        case ..<730: return "\(days / 30) mo"
        default: return "\(days / 365) yr"
        }
    }

    /// A due row leads its subtitle with their usual gap ("Every 3 wk · Dinner at Sola"), so "due" explains itself.
    /// How far past their rhythm a due person is before the row says "Lapsed" instead of the rhythm
    /// itself ("Every 8 wk" beside "13 mo" read as a rhythm still kept).
    static let lapsedFactor = 3

    private static func seenRow(_ person: BrainPersonRow, isDue: Bool, days: BrainPersonLayout.DayMath) -> Row {
        let ago = person.lastSeen.flatMap(days.daysAgo)
        let gap = isDue ? person.cadenceDays.map(cadence(days:)) : nil
        let lapsed = isDue && ago.flatMap { ago in person.cadenceDays.map { ago >= lapsedFactor * max($0, 1) } } == true
        // A due row says why now: their Catch up's first open thread, else the newest note.
        let detail = [isDue ? person.hook : nil, person.headline, person.subtitle]
            .compactMap { $0?.withoutInvisibleMarks }.first { !$0.isEmpty } ?? ""
        let spoken = [
            person.title,
            detail.isEmpty ? nil : detail,
            ago.map { "seen " + BrainPersonLayout.relative(daysAgo: $0) },
            isDue ? "due for a catch-up" : nil,
            gap.map { (lapsed ? "lapsed, usually " : "usually ") + $0.spoken },
        ]
        return Row(
            id: person.id,
            title: person.title,
            subtitle: [lapsed ? "Lapsed" : gap?.shown, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
            trailing: ago.map(elapsed(days:)) ?? "",
            isDue: isDue,
            accessibilityLabel: spoken.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        )
    }

    /// nil once the birthday has passed: a saved or overnight copy of the home must not list it.
    private static func birthdayRow(_ person: BrainPersonRow, days: BrainPersonLayout.DayMath) -> Row? {
        guard let ahead = person.nextBirthday.flatMap(days.daysAhead), ahead >= 0 else { return nil }
        let (trailing, spoken) = switch ahead {
        case 0: ("today", "birthday today")
        case 1: ("tomorrow", "birthday tomorrow")
        default: ("in \(ahead)d", "birthday in \(ahead) days")
        }
        return Row(
            id: person.id,
            title: person.title,
            subtitle: person.headline ?? person.subtitle,
            trailing: trailing,
            isDue: false,
            accessibilityLabel: [person.title, person.headline, spoken].compactMap { $0 }
                .filter { !$0.isEmpty }.joined(separator: ", ")
        )
    }

    // MARK: Relationship filter

    struct Relationship: Equatable, Identifiable {
        /// The server's lowercased `relationship_type`.
        let type: String
        let label: String
        let count: Int
        var id: String { type }
    }

    /// The relationship types among `items`, most common first (ties by name).
    static func relationships(_ items: [BrainItem]) -> [Relationship] {
        var counts: [String: Int] = [:]
        for item in items {
            guard let type = item.relationshipType?.trimmingCharacters(in: .whitespaces), !type.isEmpty else { continue }
            counts[type, default: 0] += 1
        }
        return counts
            .map { Relationship(type: $0.key, label: $0.key.prefix(1).uppercased() + $0.key.dropFirst(), count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.type < $1.type }
    }

    /// The filter's name: "All" with none picked, else the type's label, even once no loaded
    /// person has it (a refresh), so the menu never says "All" over an empty list.
    static func relationshipLabel(_ type: String?, in relationships: [Relationship]) -> String {
        guard let type else { return "All" }
        return relationships.first { $0.type == type }?.label ?? (type.prefix(1).uppercased() + type.dropFirst())
    }

    /// `items` of one relationship type; all of them when `type` is nil.
    static func filtered(_ items: [BrainItem], relationship type: String?) -> [BrainItem] {
        guard let type else { return items }
        return items.filter { $0.relationshipType == type }
    }
}

/// Loads the People sections. An older server (404) or a failure with nothing saved leaves the
/// screen as Everyone alone; the list beside it reports errors, so this one stays quiet.
@MainActor
@Observable
final class BrainPeopleHomeViewModel {
    private(set) var sections: [BrainPeopleLayout.Section] = []

    private let client: any BrainDataClient
    private let cache: BrainCacheHandle
    private let now: () -> Date
    /// Bumped per load, so an older load that finishes last (the first load and a foreground reload) can't win.
    private var generation = 0
    private static let cacheKind = "people-home"

    init(client: any BrainDataClient, cache: BrainCacheHandle, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.cache = cache
        self.now = now
    }

    /// Offline, the saved copy is shown again with today's day math, so its "6d" and birthdays move on too.
    func load() async {
        generation += 1
        let token = generation
        do {
            let home = try await client.peopleHome()
            guard !Task.isCancelled, token == generation else { return }
            show(home)
            cache.store(home, kind: Self.cacheKind, id: "")
        } catch is CancellationError {
            // The screen went away.
        } catch {
            guard !Task.isCancelled, token == generation,
                  let saved = cache.load(BrainPeopleHome.self, kind: Self.cacheKind, id: "")
            else { return }
            show(saved)
        }
    }

    private func show(_ home: BrainPeopleHome) {
        sections = BrainPeopleLayout.sections(home, today: now())
    }
}

/// A person in a People section: monogram, name, headline, and how long ago (or how soon the
/// birthday). Due rows wear the opener glow on the trailing time.
struct BrainPeopleSectionRow: View {
    let row: BrainPeopleLayout.Row
    @ScaledMetric(relativeTo: .body) private var side = BrainStyle.thumbnailSize

    var body: some View {
        BrainRow(
            leading: { BrainMonogram(name: row.title, size: side) },
            title: row.title,
            subtitle: row.subtitle,
            trailing: row.trailing,
            trailingTint: row.isDue ? HermexPaper.opener.glow : nil,
            subtitleLineLimit: 1
        )
        .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
    }
}

/// Everyone's header: the count, and a menu that narrows the list to one relationship.
struct BrainPeopleEveryoneHeader: View {
    let count: Int
    let relationships: [BrainPeopleLayout.Relationship]
    @Binding var selected: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Everyone", count: count)
            if !relationships.isEmpty {
                Menu {
                    Picker(selection: $selected) {
                        Text(verbatim: "All").tag(String?.none)
                        ForEach(relationships) { relationship in
                            Text(verbatim: "\(relationship.label) (\(relationship.count))")
                                .tag(Optional(relationship.type))
                        }
                    } label: {
                        EmptyView()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(verbatim: selectedLabel)
                        Image(systemName: "chevron.down")
                            .font(AppFont.caption2(weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .font(AppFont.caption(weight: .medium))
                    .frame(minHeight: BrainStyle.minTapTarget)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(verbatim: "Relationship"))
                .accessibilityValue(Text(verbatim: selectedLabel))
            }
        }
    }

    private var selectedLabel: String {
        BrainPeopleLayout.relationshipLabel(selected, in: relationships)
    }
}
