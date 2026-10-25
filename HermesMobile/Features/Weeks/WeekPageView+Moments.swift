import SwiftUI

// MARK: Moments record

/// A moments record (`WeekRecord.isMomentsRecord`): the week as he sealed it, in the order of
/// the review: moments, how it ended, last week's intention, what he reflected on, each value,
/// next week's intention, and the note. A section with nothing in it is left out.
extension WeekPageView {
    @ViewBuilder func momentsSections(_ record: WeekRecord) -> some View {
        if !record.moments.isEmpty || Self.nonEmpty(record.ended) != nil {
            section("Moments") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(record.moments.enumerated()), id: \.offset) { _, moment in
                        momentRow(moment)
                    }
                    if let ended = Self.nonEmpty(record.ended) {
                        (Text(verbatim: "Ended: ").foregroundStyle(palette.ink).fontWeight(.semibold)
                            + Text(verbatim: ended).foregroundStyle(Color.hxTextPrimary))
                            .font(AppFont.subheadline())
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }
            }
        }
        if let last = record.lastIntention, let text = Self.nonEmpty(last.text) {
            section("Last week") { lastIntentionView(last, text: text) }
        }
        let reflections = [record.reflect?.proud, record.reflect?.lesson].compactMap { $0 }
            .filter { Self.nonEmpty($0.answer) != nil }
        if !reflections.isEmpty {
            section("Reflect") {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(reflections.enumerated()), id: \.offset) { _, reflection in
                        VStack(alignment: .leading, spacing: 8) {
                            if let question = Self.nonEmpty(reflection.question) {
                                Text(verbatim: question)
                                    .font(AppFont.display(style: .headline, weight: .semibold))
                                    .foregroundStyle(Color.hxTextPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            saved(Self.nonEmpty(reflection.answer) ?? "")
                        }
                    }
                }
            }
        }
        let scored = record.values.filter { $0.score != nil || Self.nonEmpty($0.answer) != nil }
        if !scored.isEmpty {
            section("Values") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(scored) { valueRow($0) }
                }
            }
        }
        if let intention = record.intention, !Self.intentionRows(intention).isEmpty {
            section("This week") { intentionView(intention) }
        }
        if let note = record.note, let text = Self.nonEmpty(note.text) {
            noteRow(text: text, opensOn: note.opensOn)
                .padding(.top, 28)
        }
    }

    private func momentRow(_ moment: WeekRecord.Moment) -> some View {
        let value = WeekValues.shortName(moment.value)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: moment.day)
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(Color.hxTextSecondary)
                .frame(minWidth: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: moment.line)
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let value { HXChip(paper: palette.colors, label: value) }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: WeekValues.spokenMoment(day: moment.day, line: moment.line, value: moment.value)))
    }

    /// The words of last week's intention, how it went, and what he said got in the way.
    private func lastIntentionView(_ last: WeekRecord.LastIntention, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: text)
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = last.status.flatMap({ Self.intentionStatus[$0] }) {
                HXChip(paper: palette.colors, label: status)
            }
            if let note = Self.nonEmpty(last.note) { saved(note) }
        }
        .accessibilityElement(children: .combine)
    }

    private static let intentionStatus = ["held": "Held", "partly": "Partly", "didnt": "Didn't"]

    /// A value's name and score, the week's fact, and his answer in serif.
    private func valueRow(_ value: WeekRecord.Value) -> some View {
        let name = value.name ?? value.id.capitalized
        let fact = [value.fact?.big, value.fact?.line].compactMap(Self.nonEmpty).joined(separator: " \u{b7} ")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: name)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let score = value.score {
                    HXChip(paper: palette.colors, label: "\(score)")
                        .accessibilityHidden(true)
                }
            }
            if !fact.isEmpty {
                Text(verbatim: fact)
                    .font(AppFont.footnote())
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let answer = Self.nonEmpty(value.answer) { saved(answer) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: [value.score.map { "\(name), \($0) of 10" } ?? name, fact, Self.nonEmpty(value.answer) ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ". ")))
    }

    /// The intention card's own labels, in its order; a blank field has no row.
    private static func intentionRows(_ intention: WeekRecord.Intention) -> [(label: String, text: String)] {
        [("Thread", intention.thread), ("Intention", intention.text), ("Obstacle", intention.obstacle), ("If-then", intention.ifThen)]
            .compactMap { label, text in nonEmpty(text).map { (label, $0) } }
    }

    private func intentionView(_ intention: WeekRecord.Intention) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.intentionRows(intention), id: \.label) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.label)
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(Color.hxTextSecondary)
                    saved(row.text)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
