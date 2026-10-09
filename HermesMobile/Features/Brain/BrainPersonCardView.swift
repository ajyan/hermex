import SwiftUI

/// A person page's title block: monogram, name and relationship, then a grid of the
/// page's facts (last contacted, birthday, location, industry; whichever exist).
/// Dates read in the one Brain format (`BrainStyle.displayDate`); anything else shows as is.
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
            .map { Fact(label: $0.label, value: BrainStyle.displayDate($0.value)) }
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
