import SwiftUI
import UIKit

/// The Daily Ask card: today's three roles, read live from `/api/jobs/ask` (`DailyAskModel`), so it
/// stays true after a tap or a later reopen. The brief's `fallback` stands in while loading, on an
/// older deck, or when the server has no job search.
struct DeckAskCard: View {
    let card: DeckCard
    /// The deck's day ("2026-10-19"): the card is live only when it is the server's today.
    let deckDate: String

    @Environment(DailyAskModel.self) private var model: DailyAskModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let model, model.isLive(for: deckDate), case .loaded(let ask) = model.state {
                DailyAskBody(model: model, ask: ask)
            } else {
                Text(verbatim: card.title ?? "Today's Ask").font(AppFont.display(style: .title2, weight: .semibold))
                if let fallback = card.fallback {
                    Text(verbatim: fallback).font(AppFont.body()).padding(.top, 12)
                }
            }
        }
        .task(id: deckDate) {
            guard let model else { return }
            if case .loaded(let ask) = model.state, ask.today == deckDate { return }
            if case .unavailable = model.state { return }
            await model.load()
        }
    }
}

/// The Ask itself, shared by the Deck card and the Prep gate: the week's counts, three role rows
/// (one open at a time) with the drafted note or opener and the decision card's buttons, Skip today
/// with a reason, and a Pass sheet whose Company and Title choices become filter rules. Keyed by
/// the Ask's day, so what was typed or opened yesterday never carries into today's Ask.
struct DailyAskBody: View {
    let model: DailyAskModel
    let ask: DailyAsk

    var body: some View {
        DailyAskForm(model: model, ask: ask).id(ask.today)
    }

    static func doneLine(_ outcome: DailyAskOutcome) -> String {
        switch outcome.event {
        case "applied": return "Applied to \(outcome.company ?? "the role") — Prep is open"
        case "sent":
            let who = outcome.name.map { "\($0) at " } ?? ""
            return "Reached out to \(who)\(outcome.company ?? "them") — Prep is open"
        default: return "Skipped: \(outcome.reason ?? "")"
        }
    }

    static func neverMissTwiceLine(_ ask: DailyAsk) -> String? {
        guard ask.needsNeverMissTwice, let previous = ask.previous else { return nil }
        return "Yesterday's Ask was \(previous) — never miss twice."
    }

    static func weekLine(_ ask: DailyAsk) -> String? {
        guard let a = ask.week?.applications, let o = ask.week?.outreach,
              let aDone = a.done, let aTarget = a.target, let oDone = o.done, let oTarget = o.target else { return nil }
        return "Applications \(aDone)/\(aTarget) · Outreach \(oDone)/\(oTarget)"
    }
}

private struct DailyAskForm: View {
    let model: DailyAskModel
    let ask: DailyAsk

    @State private var expandedID: String?
    /// Rows switched to the other way in ("Reach out instead" / "Apply instead").
    @State private var flipped: Set<String> = []
    @State private var names: [String: String] = [:]
    @State private var isSkipping = false
    @State private var skipReason = ""
    @State private var passing: DailyAskRole?
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: "Today's Ask").font(AppFont.display(style: .title2, weight: .semibold))
                if model.pending {
                    ProgressView().accessibilityLabel(Text(verbatim: "Saving"))
                }
            }
            if let week = DailyAskBody.weekLine(ask) {
                Text(verbatim: week).font(AppFont.subheadline()).foregroundStyle(.secondary).padding(.top, 4)
            }
            if let outcome = ask.outcome {
                Text(verbatim: DailyAskBody.doneLine(outcome)).font(AppFont.body()).padding(.top, 16)
            } else {
                if let line = DailyAskBody.neverMissTwiceLine(ask) {
                    Text(verbatim: line).font(AppFont.subheadline(weight: .semibold)).padding(.top, 12)
                }
                ForEach(Array((ask.roles ?? []).enumerated()), id: \.element.id) { index, role in
                    if index > 0 { Divider().padding(.vertical, 4) } else { Spacer().frame(height: 16) }
                    row(role)
                }
                skip.padding(.top, 20)
            }
            if let error = model.error {
                Text(verbatim: error).font(AppFont.footnote()).foregroundStyle(Color.hxDanger).padding(.top, 12)
            }
        }
        .disabled(model.pending)
        .sheet(item: $passing) { role in
            // Closes only once the server saved the Pass, so a failure keeps the typed reason.
            DailyAskPassSheet(role: role, model: model) { reason, rule in
                if await model.act(.pass(role: role.id, reason: reason, rule: rule)) { passing = nil }
            }
        }
    }

    @ViewBuilder
    private func row(_ role: DailyAskRole) -> some View {
        let isOpen = expandedID == role.id
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { expandedID = isOpen ? nil : role.id }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: role.company).font(AppFont.headline())
                        Text(verbatim: role.title).font(AppFont.subheadline())
                        let detail = [role.location, role.bandLabel].compactMap { $0 }.joined(separator: " · ")
                        if !detail.isEmpty {
                            Text(verbatim: detail).font(AppFont.caption()).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: [role.company, role.title, role.location, role.bandLabel]
                .compactMap { $0 }.joined(separator: ", ")))
            .accessibilityHint(Text(verbatim: isOpen ? "Hides the draft" : "Shows the draft and actions"))
            if isOpen { expanded(role) }
        }
    }

    @ViewBuilder
    private func expanded(_ role: DailyAskRole) -> some View {
        let reach = ask.isReachFirst != flipped.contains(role.id)
        if reach {
            if let text = role.opener { draftBlock(heading: "Opener", text: text) }
        } else {
            if let text = role.note { textBlock(heading: "The role", text: text) }
            if let text = role.catch, !text.isEmpty { textBlock(heading: "Might not fit", text: text) }
        }
        if reach {
            TextField(text: Binding(get: { names[role.id] ?? "" }, set: { names[role.id] = $0 })) {
                Text(verbatim: "Who you messaged (optional)")
            }
            .font(AppFont.body())
            .textContentType(.name)
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actions(role, reach: reach) }
            VStack(alignment: .leading, spacing: 8) { actions(role, reach: reach) }
        }
    }

    @ViewBuilder
    private func actions(_ role: DailyAskRole, reach: Bool) -> some View {
        if reach {
            if let link = role.searchUrl.flatMap(URL.init(string:)) {
                ChoiceButton(title: "Open LinkedIn search", isSelected: false) { openURL(link) }
            }
            ChoiceButton(title: "Sent", isSelected: false) {
                let name = names[role.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await model.act(.sent(role: role.id, name: name?.isEmpty == false ? name : nil)) }
            }
            ChoiceButton(title: "Apply instead", isSelected: false) { flip(role) }
        } else {
            if let link = role.url.flatMap(URL.init(string:)) {
                ChoiceButton(title: "Open posting", isSelected: false) { openURL(link) }
            }
            ChoiceButton(title: "Applied", isSelected: false) { Task { await model.act(.applied(role: role.id)) } }
            ChoiceButton(title: "Reach out instead", isSelected: false) { flip(role) }
        }
        ChoiceButton(title: "Pass", isSelected: false) { passing = role }
    }

    private func flip(_ role: DailyAskRole) {
        if flipped.contains(role.id) { flipped.remove(role.id) } else { flipped.insert(role.id) }
    }

    /// A labeled read-only paragraph: what the role is, or its catch.
    private func textBlock(heading: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: heading)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: text).font(AppFont.body()).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The follow-up card's draft block, read-only, with Copy.
    private func draftBlock(heading: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(verbatim: heading)
                Spacer(minLength: 8)
                Button { UIPasteboard.general.string = text } label: {
                    Label { Text(verbatim: "Copy") } icon: { Image(systemName: "doc.on.doc") }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "Copy \(heading.lowercased())"))
            }
            .font(AppFont.caption(weight: .semibold))
            .foregroundStyle(.secondary)
            Text(verbatim: text).font(AppFont.body()).textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var skip: some View {
        ChoiceButton(title: "Skip today", isSelected: isSkipping) { isSkipping.toggle() }
        if isSkipping {
            HStack(spacing: 8) {
                TextField(text: $skipReason, axis: .vertical) { Text(verbatim: "Why are you skipping?") }
                    .font(AppFont.body())
                    .padding(10)
                    .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                let reason = skipReason.trimmingCharacters(in: .whitespacesAndNewlines)
                ChoiceButton(title: "Skip", isSelected: !reason.isEmpty) {
                    guard !reason.isEmpty else { return }
                    Task { await model.act(.skip(reason: reason)) }
                }
                .disabled(reason.isEmpty)
            }
            .padding(.top, 10)
        }
    }
}

/// Pass on one role: a reason and what was wrong. Company and Title become filter rules on the server.
private struct DailyAskPassSheet: View {
    let role: DailyAskRole
    let model: DailyAskModel
    let pass: (String, String) async -> Void
    @State private var reason = ""
    @State private var rule: String?
    @Environment(\.dismiss) private var dismiss

    private static let rules: [(id: String, label: String)] = [
        ("company", "Company"), ("title", "Title"), ("level", "Level"),
        ("location", "Location"), ("comp", "Comp"), ("other", "Other"),
    ]

    var body: some View {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: "\(role.company) — \(role.title)").font(AppFont.headline())
                TextField(text: $reason, axis: .vertical) { Text(verbatim: "Why pass?") }
                    .font(AppFont.body())
                    .padding(10)
                    .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(verbatim: "What was wrong").font(AppFont.subheadline(weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Self.rules, id: \.id) { option in
                        ChoiceButton(title: option.label, isSelected: rule == option.id) { rule = option.id }
                    }
                }
                Text(verbatim: "Company and Title stop roles like this from coming back.")
                    .font(AppFont.footnote()).foregroundStyle(.secondary)
                if let error = model.error {
                    Text(verbatim: error).font(AppFont.footnote()).foregroundStyle(Color.hxDanger)
                }
                Spacer()
            }
            .padding(24)
            .hxNavigationTitle("Pass")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.pending {
                        ProgressView().accessibilityLabel(Text(verbatim: "Saving"))
                    } else {
                        Button("Pass") { if let rule { Task { await pass(trimmed, rule) } } }
                            .disabled(trimmed.isEmpty || rule == nil)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
