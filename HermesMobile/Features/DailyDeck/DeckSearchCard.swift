import SwiftUI

/// The Brief's job search card: the coming interviews with their dates (each opening its one-pager), then how
/// the search is going as pips: applications and outreach this week against the goal (the pipeline's one
/// count, `JobPipeline.week`), interviews booked, replies to the last 30 days' applications, and the ones gone
/// quiet. Read live from `/api/jobs/pipeline` (`JobPipelineModel`), and again whenever the Ask's week moves, so
/// the two cards never disagree; the brief's `fallback` stands in while loading, on an older deck, or when the
/// server has no pipeline.
struct DeckSearchCard: View {
    let card: DeckCard
    let palette: DeckPalette
    /// The deck's day: the card is live only when it is the server's today.
    let deckDate: String

    @Environment(JobPipelineModel.self) private var model: JobPipelineModel?
    @Environment(DailyAskModel.self) private var askModel: DailyAskModel?
    @Environment(\.openBrainRoute) private var openBrainRoute

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
        // An Ask action (Applied, Sent, Applied elsewhere) changes the week: read the pipeline again.
        .onChange(of: askWeek) { _, _ in
            guard let model else { return }
            Task { await model.load() }
        }
    }

    private var askWeek: DailyAskWeek? {
        guard let askModel, case .loaded(let ask) = askModel.state else { return nil }
        return ask.week
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
                if let applied = pipeline.applicationsWeek {
                    JobCountPips(label: "Applied this week", count: applied, ink: palette.ink)
                }
                if let outreach = pipeline.week?.outreach {
                    JobCountPips(label: "Outreach this week", count: outreach, ink: palette.ink)
                }
                JobCountPips(label: "Interviews booked", count: JobCount(done: m.booked, target: nil), ink: palette.ink)
                JobCountPips(label: "Replies, last 30 days", count: JobCount(done: m.replies, target: m.recent), ink: palette.ink)
                JobCountPips(label: "Gone quiet, 14+ days", count: JobCount(done: m.quiet, target: nil), ink: palette.ink)
            }
            if m.quiet > 0 {
                Text(verbatim: "Follow up or close: \(m.quietNames.joined(separator: ", ")).")
                    .font(AppFont.subheadline())
                    .foregroundStyle(palette.secondaryInk)
                    .padding(.top, 12)
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(verbatim: title)
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(palette.secondaryInk)
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
}
