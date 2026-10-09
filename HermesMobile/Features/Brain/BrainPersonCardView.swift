import SwiftUI

/// A person page's title block: monogram, name and relationship, then a grid of the
/// page's facts (last contacted, birthday, location, industry; whichever exist).
/// Dates read as long dates; any value that isn't a `yyyy-MM-dd` date shows as is.
struct BrainPersonCardView: View {
    private struct Fact {
        let label: String
        let value: String
    }

    let item: BrainItem
    /// Formatted once, never in `body`.
    private let facts: [Fact]
    @ScaledMetric(relativeTo: .title) private var monogramSide: CGFloat = 56
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(item: BrainItem, facts: [BrainFact]) {
        self.item = item
        self.facts = facts
            .filter { !$0.label.isEmpty && !$0.value.isEmpty }
            .map { Fact(label: $0.label, value: Self.displayValue($0.value)) }
    }

    /// Parses only whole `yyyy-MM-dd` dates, in UTC so the day never shifts.
    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    /// A fact value for display: a `yyyy-MM-dd` date as a long date in `locale`,
    /// anything else (or an impossible date) unchanged.
    static func displayValue(_ value: String, locale: Locale = .current) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 10, let date = isoDay.date(from: trimmed) else { return value }
        var style = Date.FormatStyle(date: .long, time: .omitted)
        style.locale = locale
        style.calendar = Calendar(identifier: .gregorian)
        style.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return date.formatted(style)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BrainStyle.l) {
            HStack(alignment: .center, spacing: BrainStyle.m) {
                BrainMonogram(name: item.title, size: monogramSide, font: BrainStyle.readerTitle)
                VStack(alignment: .leading, spacing: BrainStyle.xs) {
                    Text(verbatim: item.title)
                        .brainText(.readerTitle)
                        .accessibilityAddTraits(.isHeader)
                    if !item.subtitle.isEmpty {
                        Text(verbatim: item.subtitle)
                            .brainText(.rowSubtitle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !facts.isEmpty {
                factGrid
            }
        }
    }

    private var factGrid: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: BrainStyle.m, alignment: .topLeading),
            count: BrainListLayout.columnCount(2, dynamicType: dynamicTypeSize)
        )
        return LazyVGrid(columns: columns, alignment: .leading, spacing: BrainStyle.m) {
            // Facts arrive in a fixed server order, so position is a stable id.
            ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                VStack(alignment: .leading, spacing: BrainStyle.xs) {
                    Text(verbatim: fact.label)
                        .brainText(.meta)
                    Text(verbatim: fact.value)
                        .brainText(.rowTitle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, BrainStyle.cardHorizontalPadding)
        .padding(.vertical, BrainStyle.cardVerticalPadding)
        .brainCardSurface()
    }
}
