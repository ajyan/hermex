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
            Section(title: "Birthdays soon", rows: home.birthdays.map { birthdayRow($0, days: days) }),
            Section(title: "Recently seen", rows: home.recent.map { seenRow($0, isDue: false, days: days) }),
        ]
        return all.filter { !$0.rows.isEmpty }
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

    private static func seenRow(_ person: BrainPersonRow, isDue: Bool, days: BrainPersonLayout.DayMath) -> Row {
        let ago = person.lastSeen.flatMap(days.daysAgo)
        let spoken = [
            person.title,
            person.headline,
            ago.map { "seen " + BrainPersonLayout.relative(daysAgo: $0) },
            isDue ? "due for a catch-up" : nil,
        ]
        return Row(
            id: person.id,
            title: person.title,
            subtitle: person.headline ?? person.subtitle,
            trailing: ago.map(elapsed(days:)) ?? "",
            isDue: isDue,
            accessibilityLabel: spoken.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        )
    }

    private static func birthdayRow(_ person: BrainPersonRow, days: BrainPersonLayout.DayMath) -> Row {
        let ahead = person.nextBirthday.flatMap(days.daysAhead)
        let trailing: String
        let spoken: String?
        switch ahead {
        case .some(0): (trailing, spoken) = ("today", "birthday today")
        case .some(1): (trailing, spoken) = ("tomorrow", "birthday tomorrow")
        case .some(let n) where n > 1: (trailing, spoken) = ("in \(n)d", "birthday in \(n) days")
        default: (trailing, spoken) = ("", nil)
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
    private static let cacheKind = "people-home"

    init(client: any BrainDataClient, cache: BrainCacheHandle, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.cache = cache
        self.now = now
    }

    func load() async {
        do {
            let home = try await client.peopleHome()
            guard !Task.isCancelled else { return }
            show(home)
            cache.store(home, kind: Self.cacheKind, id: "")
        } catch is CancellationError {
            // The screen went away.
        } catch {
            guard !Task.isCancelled, sections.isEmpty,
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
                        Text(verbatim: "Everyone").tag(String?.none)
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
        relationships.first { $0.type == selected }?.label ?? "All"
    }
}
