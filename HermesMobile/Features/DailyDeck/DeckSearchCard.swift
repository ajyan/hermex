import SwiftUI

/// The Brief's job search card: the coming interviews with their dates (each opening its one-pager), then how
/// the search is going as pips: applied this week against the goal, interviews booked, replies to the last 30
/// days' applications, and the ones gone quiet. Read live from `/api/jobs/pipeline` (`JobPipelineModel`); the
/// brief's `fallback` stands in while loading, on an older deck, or when the server has no pipeline.
struct DeckSearchCard: View {
    let card: DeckCard
    let palette: DeckPalette
    /// The deck's day: the card is live only when it is the server's today.
    let deckDate: String

    @Environment(JobPipelineModel.self) private var model: JobPipelineModel?
    @Environment(DailyAskModel.self) private var askModel: DailyAskModel?
    @Environment(\.openBrainRoute) private var openBrainRoute

    /// More pips than this read as a count beside them.
    private static let maxPips = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: card.title ?? "Your job search").font(AppFont.display(style: .title2, weight: .semibold))
            if let model, let pipeline = model.pipeline, pipeline.today == deckDate {
                live(pipeline)
            } else if let fallback = card.fallback {
                Text(verbatim: fallback).font(AppFont.body()).padding(.top, 12)
            }
        }
        .task(id: deckDate) {
            guard let model, model.pipeline?.today != deckDate else { return }
            await model.load()
        }
    }

    @ViewBuilder
    private func live(_ pipeline: JobPipeline) -> some View {
        if !pipeline.upcoming.isEmpty {
            heading("Coming up")
            ForEach(Array(pipeline.upcoming.prefix(3).enumerated()), id: \.offset) { index, slot in
                if index > 0 { Divider().padding(.vertical, 4) }
                upcoming(slot)
            }
        }
        if let m = pipeline.metrics {
            heading("How it's going")
            VStack(alignment: .leading, spacing: 12) {
                if let week = applicationsWeek {
                    pips("Applied this week", filled: week.done, of: max(week.target, week.done))
                } else {
                    pips("Applied this week", filled: m.addedWeek, of: m.addedWeek)
                }
                pips("Interviews booked", filled: m.booked, of: m.booked)
                pips("Replies, last 30 days", filled: m.replies, of: m.recent)
                pips("Gone quiet, 14+ days", filled: m.quiet, of: m.quiet)
            }
            if m.quiet > 0 {
                Text(verbatim: "Follow up or close: \(m.quietNames.joined(separator: ", ")).")
                    .font(AppFont.subheadline())
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
        }
    }

    private var applicationsWeek: (done: Int, target: Int)? {
        guard let askModel, case .loaded(let ask) = askModel.state, let a = ask.week?.applications,
              let done = a.done, let target = a.target else { return nil }
        return (done, target)
    }

    private func heading(_ title: String) -> some View {
        Text(verbatim: title)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 20)
            .padding(.bottom, 8)
    }

    private func upcoming(_ slot: JobInterviewSlot) -> some View {
        Button {
            openBrainRoute(.prep(.onePager(slot.id)))
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(slot.company ?? "Interview") · \(slot.label.lowercased())").font(AppFont.headline())
                    Text(verbatim: "\(JobCopy.day(slot.on)) · \(JobCopy.when(inDays: slot.inDays))")
                        .font(AppFont.subheadline())
                }
                Spacer(minLength: 8)
                Text(verbatim: "One-pager").font(AppFont.caption(weight: .semibold)).foregroundStyle(Color.accentColor)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!openBrainRoute.isAvailable)
        .accessibilityHint(Text(verbatim: "Opens the one-pager"))
    }

    /// A label over a row of pips, `filled` of `of` filled; past `maxPips` the count reads beside them.
    private func pips(_ label: String, filled: Int, of total: Int) -> some View {
        let shown = min(max(total, filled), Self.maxPips)
        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: label).font(AppFont.subheadline())
            HStack(spacing: 0) {
                if shown == 0 {
                    DeckDot(state: "missed", ink: palette.ink)
                }
                ForEach(0..<shown, id: \.self) { index in
                    DeckDot(state: index < filled ? "done" : "missed", ink: palette.ink)
                }
                if max(total, filled) > Self.maxPips {
                    Text(verbatim: "\(filled) of \(total)").font(AppFont.caption()).foregroundStyle(.secondary).padding(.leading, 6)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(label): \(filled) of \(total)"))
    }
}
