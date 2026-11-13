import SwiftUI

/// Prep home's Pipeline: every open application as a hairline row in one neutral card (the company, then its
/// stage and next step in plain words), each opening its company page, and Add a company. The week's
/// applications sit in the header as pips, the same count the Ask and the Brief's search card show. An empty
/// pipeline says so over Add, so the first company can be added. Hidden until the pipeline loads and on a server
/// without one (404); a failed load shows one retry line instead.
struct PrepPipelineSection: View {
    let model: JobPipelineModel
    @State private var adding = false

    var body: some View {
        if let pipeline = model.pipeline {
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                HStack(alignment: .firstTextBaseline, spacing: BrainStyle.s) {
                    BrainSectionHeader(title: "Pipeline")
                    if let applied = pipeline.applicationsWeek {
                        JobCountPips(label: "Applications", count: applied, layout: .beside, compact: true)
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                }
                // A server that sends no pack still pins the next interview above the rows.
                if pipeline.pack == nil, let next = pipeline.upcoming.first {
                    JobNextInterviewCard(slot: next)
                }
                SectionCard {
                    VStack(spacing: 0) {
                        if pipeline.applications.isEmpty {
                            Text(verbatim: "No applications yet. Add the first company you're talking to.")
                                .font(BrainStyle.rowSubtitle)
                                .foregroundStyle(Color.hxTextSecondary)
                                .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(pipeline.applications.enumerated()), id: \.element.id) { offset, row in
                            if offset > 0 { PrepRowDivider() }
                            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.application(row.id)))) {
                                BrainRow(leading: { EmptyView() }, title: row.name, subtitle: JobCopy.pipelineLine(row),
                                         subtitleLineLimit: 2)
                            }
                            .buttonStyle(.plain)
                        }
                        PrepRowDivider()
                        Button { adding = true } label: {
                            Label { Text(verbatim: "Add a company") } icon: { Image(systemName: "plus") }
                                .font(BrainStyle.rowSubtitle)
                                .foregroundStyle(Color.accentColor)
                                .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !pipeline.closed.isEmpty {
                    Text(verbatim: "Closed: \(pipeline.closed.map(\.name).joined(separator: ", "))")
                        .font(BrainStyle.meta)
                        .foregroundStyle(Color.hxTextSecondary)
                        .lineLimit(2)
                }
            }
            .sheet(isPresented: $adding) { JobAddSheet(model: model) }
        } else if model.loadFailed {
            Button { Task { await model.load() } } label: {
                Label { Text(verbatim: "Couldn't load your pipeline · Try again") } icon: {
                    Image(systemName: "arrow.clockwise")
                }
                .font(BrainStyle.rowSubtitle)
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }
}

/// The interview pack, leading Prep's home while an interview is booked: one orchid glow card with who and
/// when, three hairline rows (the stories picked for it with told pips, the round's mock, the one-pager), and
/// the screen's one filled button, which starts the first step not done yet.
struct PrepInterviewPackCard: View {
    let pack: JobPack
    /// Starts the company mock call when that is the next step.
    let mock: PrepMockViewModel
    @Environment(\.openMockCall) private var openMockCall

    private var paper: HermexPaper { .prep }

    var body: some View {
        HXCard(.glow(paper), title: JobCopy.packTitle(pack), titleStyle: .title3, spacing: BrainStyle.s, kicker: {
            Text(verbatim: JobCopy.packKicker(pack))
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(paper.glow)
        }, content: {
            Text(verbatim: JobCopy.packRound(pack))
                .font(BrainStyle.rowSubtitle)
                .foregroundStyle(paper.secondaryInk)
            VStack(spacing: 0) {
                link(.application(pack.id), hint: "Opens the prep plan") {
                    row("Stories to tell", detail: pack.stories.map(\.name).joined(separator: ", ")) {
                        JobCountPips(label: "Told", count: pack.told, layout: .beside, compact: true, showsLabel: false)
                    }
                }
                if let step = pack.mock {
                    divider
                    link(pack.mockRoute, hint: "Opens the mock") {
                        row(step.title, detail: nil) { trailing(step.done == true ? "Done" : "To do") }
                    }
                }
                divider
                if pack.onePagerReady {
                    link(.onePager(pack.id), hint: "Opens the one-pager") {
                        row("One-pager", detail: nil) { trailing("Ready") }
                    }
                } else {
                    row("One-pager", detail: "Ask Atlas to write one from the posting and your stories.") {
                        trailing("Not written")
                    }
                }
            }
        }, footer: {
            start
            if let message = mock.errorMessage {
                Text(verbatim: message)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        })
    }

    @ViewBuilder
    private var start: some View {
        let title = JobCopy.packStart(pack)
        switch pack.start {
        case .route(let route):
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(route))) { PrepPrimaryLabel(title: title) }
                .buttonStyle(.plain)
        case .call(let part) where openMockCall.isAvailable:
            PrepPrimaryButton(title: mock.isStarting ? "Starting…" : title, enabled: !mock.isStarting) {
                Task { await mock.startCompanyCall(app: pack.id, part: part, open: openMockCall) }
            }
        case .call, .plan:
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.application(pack.id)))) {
                PrepPrimaryLabel(title: title)
            }
            .buttonStyle(.plain)
        }
    }

    private var divider: some View {
        Rectangle().fill(paper.edge).frame(height: 0.5).accessibilityHidden(true)
    }

    private func link<Label: View>(_ route: PrepRoute, hint: String, @ViewBuilder label: () -> Label) -> some View {
        NavigationLink(value: ShellPushDestination.brainRoute(.prep(route)), label: label)
            .buttonStyle(.plain)
            .accessibilityHint(Text(verbatim: hint))
    }

    private func row<Trailing: View>(_ title: String, detail: String?, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BrainStyle.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(BrainStyle.rowSubtitle).foregroundStyle(Color.hxTextPrimary)
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(BrainStyle.meta)
                        .foregroundStyle(paper.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: BrainStyle.s)
            trailing()
        }
        .padding(.vertical, BrainStyle.xs)
        .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func trailing(_ text: String) -> some View {
        Text(verbatim: text).font(BrainStyle.meta).foregroundStyle(paper.secondaryInk)
    }
}

/// The next booked interview: who, when, and the way into its one-pager.
struct JobNextInterviewCard: View {
    let slot: JobInterviewSlot

    var body: some View {
        HXCard(.wash(.prep), title: "\(slot.company ?? "Interview") · \(slot.label.lowercased())", titleStyle: .title3,
               spacing: BrainStyle.s, kicker: {
            Text(verbatim: "Next interview · \(JobCopy.when(inDays: slot.inDays))")
                .font(BrainStyle.meta)
                .foregroundStyle(Color.hxTextSecondary)
        }, content: {
            Text(verbatim: [JobCopy.day(slot.on), slot.time, slot.role].compactMap { $0 }.joined(separator: " · "))
                .font(BrainStyle.rowSubtitle)
                .foregroundStyle(Color.hxTextPrimary)
        }, footer: {
            HStack(spacing: BrainStyle.s) {
                NavigationLink(value: ShellPushDestination.brainRoute(.prep(.onePager(slot.id)))) {
                    HXChip(paper: .prep, symbol: "doc.text", label: "One-pager")
                }
                NavigationLink(value: ShellPushDestination.brainRoute(.prep(.application(slot.id)))) {
                    HXChip(paper: .prep, symbol: "list.bullet", label: "Prep plan")
                }
            }
            .buttonStyle(.plain)
        })
    }
}

/// A count as a row of pips (`DeckDot`s): `done` filled of its target, a faint ring for each one left, and one
/// faint ring for a count of none. The one way the job search shows a number: the Ask's and the search card's
/// week, and Prep's Pipeline header. Past `JobCount.maxPips` the count reads beside the pips.
struct JobCountPips: View {
    enum Layout {
        /// The label over its pips (a card's list of counts).
        case stacked
        /// The label, then its pips on the same line (a header, the Ask's week).
        case beside
    }

    let label: String
    let count: JobCount
    /// The card's ink; the Prep glow by default, the paper the job search wears everywhere.
    var ink: Color = HermexPaper.prep.glow
    var layout: Layout = .stacked
    /// Label and pip sizes for a section header's trailing edge.
    var compact = false
    /// Off when the row it sits in already names the count; VoiceOver still reads the label.
    var showsLabel = true

    var body: some View {
        Group {
            switch layout {
            case .stacked:
                VStack(alignment: .leading, spacing: 4) { if showsLabel { title }; dots }
            case .beside:
                HStack(spacing: 6) { if showsLabel { title }; dots }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(label): \(count.spoken)"))
    }

    private var title: some View {
        Text(verbatim: label).font(compact ? AppFont.caption() : AppFont.subheadline())
    }

    private var dots: some View {
        let column: CGFloat = compact ? 14 : DeckDots.column
        let size: CGFloat = compact ? 10 : DeckDots.dot
        return HStack(spacing: 0) {
            if count.shown == 0 {
                DeckDot(state: "missed", ink: ink, column: column, size: size)
            }
            ForEach(0..<count.shown, id: \.self) { index in
                DeckDot(state: index < count.done ? "done" : "missed", ink: ink, column: column, size: size)
            }
            if count.overflows {
                Text(verbatim: count.spoken).font(AppFont.caption()).foregroundStyle(.secondary).padding(.leading, 6)
            }
        }
    }
}

/// An application's stage as pips, Applied to Offer, filled through its stage; a closed one shows none.
struct JobStagePips: View {
    let step: Int?
    let count: Int
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 8

    var body: some View {
        if let step, count > 0 {
            HStack(spacing: 4) {
                ForEach(0..<count, id: \.self) { index in
                    Group {
                        if index <= step {
                            Circle().fill(HermexPaper.prep.glow)
                        } else {
                            Circle().strokeBorder(HermexPaper.prep.glow, lineWidth: 1.2)
                        }
                    }
                    .frame(width: side, height: side)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Add a company: the company (optional when a recruiter brought it), the role, who it came through, the
/// posting, and the stage it's at. A lead with no company starts at Recruiter screen.
struct JobAddSheet: View {
    let model: JobPipelineModel
    @State private var company = ""
    @State private var role = ""
    @State private var via = ""
    @State private var url = ""
    @State private var stage: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openBrainRoute) private var openBrainRoute

    private static let stages: [JobStage] = [
        JobStage(id: "applied", name: "Applied"), JobStage(id: "screen", name: "Recruiter screen"),
        JobStage(id: "technical", name: "Technical"), JobStage(id: "onsite", name: "Onsite"),
        JobStage(id: "offer", name: "Offer"),
    ]

    var body: some View {
        let c = trimmed(company), v = trimmed(via)
        NavigationStack {
            Form {
                Section {
                    TextField(text: $company) { Text(verbatim: "Company") }
                    TextField(text: $role) { Text(verbatim: "Role") }
                    TextField(text: $via) { Text(verbatim: "Via (recruiter, referral, LinkedIn)") }
                    TextField(text: $url) { Text(verbatim: "Posting link") }
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text(verbatim: "A recruiter lead can skip the company: it starts at Recruiter screen.")
                }
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(Self.stages, id: \.id) { option in
                            ChoiceButton(title: option.name, isSelected: (stage ?? (c.isEmpty ? "screen" : "applied")) == option.id) {
                                stage = option.id
                            }
                        }
                    }
                } header: {
                    Text(verbatim: "Where it is now")
                }
                if let error = model.error {
                    Text(verbatim: error).font(AppFont.footnote()).foregroundStyle(Color.hxDanger)
                }
            }
            .hxNavigationTitle("Add a company")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.pending {
                        ProgressView().accessibilityLabel(Text(verbatim: "Saving"))
                    } else {
                        Button("Add") {
                            Task {
                                let action = JobPipelineAction.add(company: c.isEmpty ? nil : c, role: nonEmpty(role),
                                                                   via: v.isEmpty ? nil : v, url: nonEmpty(url), stage: stage)
                                if let id = await model.add(action) {
                                    dismiss()
                                    if openBrainRoute.isAvailable { openBrainRoute(.prep(.application(id))) }
                                }
                            }
                        }
                        .disabled(c.isEmpty && v.isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func nonEmpty(_ text: String) -> String? { trimmed(text).isEmpty ? nil : trimmed(text) }
}
