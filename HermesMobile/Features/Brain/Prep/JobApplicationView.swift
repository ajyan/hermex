import SwiftUI

/// One application's company page: where it stands (stage pips, Move stage, Close or Reopen), its interviews
/// (book, move or cancel one), the prep plan for the round it's in (the one-pager, then the plan's steps: the pitch
/// and the company mock start their calls here, stories open their Prep pages, ladder mocks their briefs; each
/// checked once done this round), other roles to ask about, notes, and the timeline.
/// Pushed as `.brainRoute(.prep(.application(id)))`.
struct JobApplicationView: View {
    @State private var model: JobApplicationModel
    /// Starts the plan's company mock calls.
    @State private var mock: PrepMockViewModel
    @State private var booking: JobInterviewDraft?
    @State private var note = ""
    @Environment(\.openURL) private var openURL
    @Environment(\.openMockCall) private var openMockCall

    init(id: String, server: URL, onAPIError: @escaping (Error) -> Void) {
        _model = State(initialValue: JobApplicationModel(
            id: id, client: APIClientJobPipelineAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
        _mock = State(initialValue: PrepMockViewModel(
            client: APIClientPrepAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
    }

    var body: some View {
        content
            .hxNavigationTitle(title)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { FeedbackMoreMenu() } }
            .feedbackContext(FeedbackContext(feature: "Prep", screen: "Company", item: title))
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await model.load() }
            .sheet(item: $booking) { draft in
                JobInterviewSheet(draft: draft, model: model)
            }
    }

    private var title: String {
        if case .loaded(let app) = model.state { return app.row.name }
        return "Company"
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView(label: { Label { Text(verbatim: "Not in your pipeline") } icon: { Image(systemName: "briefcase") } },
                                   description: { Text(verbatim: "This application isn't on the server anymore.") })
        case .failed(let message):
            PrepFailedView(title: "Couldn't load this application", message: message) { Task { await model.load() } }
        case .loaded(let app):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.xl) {
                    header(app)
                    interviews(app)
                    plan(app)
                    if !app.also.isEmpty { also(app) }
                    notes(app)
                    timeline(app)
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .disabled(model.pending)
            .refreshable { await model.load() }
        }
    }

    // MARK: Where it stands

    private func header(_ app: JobApplication) -> some View {
        HXCard(.wash(.prep), title: app.row.role ?? app.row.name, titleStyle: .title3, spacing: BrainStyle.s, kicker: {
            let detail = [app.row.company == nil ? app.row.via.map { "Via \($0)" } : app.row.via.map { "Via \($0)" },
                          app.comp, app.location].compactMap { $0 }
            if !detail.isEmpty {
                Text(verbatim: detail.joined(separator: " · "))
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }, content: {
            HStack(spacing: BrainStyle.s) {
                JobStagePips(step: app.row.step, count: app.stages.count)
                Text(verbatim: JobCopy.stageLine(app.row))
                    .font(BrainStyle.rowSubtitle)
                    .foregroundStyle(Color.hxTextPrimary)
            }
            .accessibilityElement(children: .combine)
        }, footer: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { stageButtons(app) }
                VStack(alignment: .leading, spacing: 8) { stageButtons(app) }
            }
            if let error = model.error {
                Text(verbatim: error).font(AppFont.footnote()).foregroundStyle(Color.hxDanger)
            }
        })
    }

    @ViewBuilder
    private func stageButtons(_ app: JobApplication) -> some View {
        if app.row.open {
            Menu {
                ForEach(app.stages, id: \.id) { stage in
                    Button(stage.name) { Task { await model.act(.stage(id: app.row.id, stage: stage.id)) } }
                        .disabled(stage.id == app.row.stage)
                }
            } label: { menuLabel("Move stage") }
            Menu {
                ForEach(JobCopy.outcomes, id: \.id) { outcome in
                    Button(outcome.label) { Task { await model.act(.close(id: app.row.id, outcome: outcome.id)) } }
                }
            } label: { menuLabel("Close") }
        } else {
            ChoiceButton(title: "Reopen", isSelected: false) { Task { await model.act(.reopen(id: app.row.id)) } }
        }
        if let link = app.url.flatMap(URL.init(string:)) {
            ChoiceButton(title: "Open posting", isSelected: false) { openURL(link) }
        }
    }

    /// A menu that looks like the card's other buttons.
    private func menuLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: title)
            Image(systemName: "chevron.down").font(AppFont.caption2(weight: .semibold))
        }
        .font(AppFont.subheadline(weight: .medium))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.hxSurface, in: Capsule())
    }

    // MARK: Interviews

    private func interviews(_ app: JobApplication) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Interviews")
            SectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(app.interviews.enumerated()), id: \.element.key) { offset, interview in
                        if offset > 0 { PrepRowDivider() }
                        Button { booking = JobInterviewDraft(appID: app.row.id, interview: interview) } label: {
                            BrainRow(leading: { Image(systemName: "calendar").foregroundStyle(HermexPaper.prep.glow) },
                                     title: interview.label,
                                     subtitle: [JobCopy.day(interview.on), interview.time].compactMap { $0 }.joined(separator: " · "),
                                     trailing: "Change")
                        }
                        .buttonStyle(.plain)
                    }
                    if !app.interviews.isEmpty { PrepRowDivider() }
                    Button { booking = JobInterviewDraft(appID: app.row.id, interview: nil) } label: {
                        Label { Text(verbatim: "Book an interview") } icon: { Image(systemName: "plus") }
                            .font(BrainStyle.rowSubtitle)
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity, minHeight: BrainStyle.minTapTarget, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Prep plan

    private func plan(_ app: JobApplication) -> some View {
        let told = app.plan.filter(\.told).count
        let trailing = !app.steps.isEmpty ? "\(app.steps.filter(\.done).count) of \(app.steps.count) done"
            : app.plan.isEmpty ? nil : "\(told) of \(app.plan.count) told"
        return VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: Self.planTitle(app), trailing: trailing)
            SectionCard {
                VStack(spacing: 0) {
                    if app.onepager != nil {
                        NavigationLink(value: ShellPushDestination.brainRoute(.prep(.onePager(app.row.id)))) {
                            BrainRow(leading: { Image(systemName: "doc.text").foregroundStyle(HermexPaper.prep.glow) },
                                     title: "Read the one-pager", subtitle: app.onepager?.forLabel, trailing: "›")
                        }
                        .buttonStyle(.plain)
                    } else {
                        BrainRow(leading: { Image(systemName: "doc.text").foregroundStyle(Color.hxTextSecondary) },
                                 title: "No one-pager yet", subtitle: "Ask Atlas to write one from the posting and your stories.")
                    }
                    if app.steps.isEmpty {
                        ForEach(app.plan) { story in
                            PrepRowDivider()
                            NavigationLink(value: ShellPushDestination.brainRoute(.prep(.storyPage(story.id)))) {
                                stepRow(done: story.told, title: "Tell \(story.name)", subtitle: story.title, trailing: "›")
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(Text(verbatim: story.told ? "Told" : "Not told yet"))
                        }
                    }
                    ForEach(app.steps) { step in
                        PrepRowDivider()
                        planStep(step, app: app)
                    }
                }
            }
            if let message = mock.errorMessage {
                Text(verbatim: message)
                    .font(BrainStyle.meta)
                    .foregroundStyle(Color.hxDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A pitch or mock step starts its call here; a story opens its Prep page, a ladder mock its brief.
    @ViewBuilder
    private func planStep(_ step: JobPlanStep, app: JobApplication) -> some View {
        if let part = step.callPart {
            Button {
                Task { await mock.startCompanyCall(app: app.row.id, part: part, open: openMockCall) }
            } label: {
                stepRow(done: step.done, title: step.title, subtitle: step.subtitle, trailing: mock.isStarting ? "Starting…" : "Call")
            }
            .buttonStyle(.plain)
            .disabled(mock.isStarting || !openMockCall.isAvailable)
            .accessibilityValue(Text(verbatim: step.done ? "Done" : "Not done yet"))
        } else if let route = Self.route(step) {
            NavigationLink(value: ShellPushDestination.brainRoute(.prep(route))) {
                stepRow(done: step.done, title: step.title, subtitle: step.subtitle, trailing: "›")
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(verbatim: step.done ? "Done" : "Not done yet"))
        }
    }

    /// "Prep for First round" (the next interview), else the round ("Prep for the recruiter screen").
    static func planTitle(_ app: JobApplication) -> String {
        guard !app.steps.isEmpty else { return "Prep plan" }
        if let next = app.row.next { return "Prep for \(next.label)" }
        return app.round.map { "Prep for the \($0.lowercased())" } ?? "Prep plan"
    }

    /// The Prep screen a story or ladder step opens.
    static func route(_ step: JobPlanStep) -> PrepRoute? {
        switch step.kind {
        case "story": return .storyPage(step.id)
        case "ladder": return PrepMockKind(rawValue: step.id).map { .mockLadder($0) }
        default: return nil
        }
    }

    private func stepRow(done: Bool, title: String, subtitle: String?, trailing: String) -> some View {
        BrainRow(leading: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(HermexPaper.prep.glow)
        }, title: title, subtitle: subtitle, trailing: trailing)
    }

    // MARK: Also, notes, timeline

    private func also(_ app: JobApplication) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Also asking about")
            SectionCard {
                VStack(spacing: 0) {
                    ForEach(Array(app.also.enumerated()), id: \.offset) { offset, other in
                        if offset > 0 { PrepRowDivider() }
                        Button { other.url.flatMap(URL.init(string:)).map { openURL($0) } } label: {
                            BrainRow(leading: { EmptyView() }, title: other.role,
                                     subtitle: [other.comp, other.note].compactMap { $0 }.joined(separator: " · "),
                                     trailing: other.url == nil ? nil : "Posting")
                        }
                        .buttonStyle(.plain)
                        .disabled(other.url == nil)
                    }
                }
            }
        }
    }

    private func notes(_ app: JobApplication) -> some View {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Notes")
            HStack(alignment: .bottom, spacing: 8) {
                TextField(text: $note, axis: .vertical) { Text(verbatim: "What happened, who you met, what's next") }
                    .font(AppFont.body())
                    .padding(10)
                    .withDictation($note)
                    .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
                ChoiceButton(title: "Add", isSelected: !text.isEmpty) {
                    guard !text.isEmpty else { return }
                    Task { if await model.act(.note(id: app.row.id, text: text)) { note = "" } }
                }
                .disabled(text.isEmpty)
            }
        }
    }

    private func timeline(_ app: JobApplication) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: "Timeline")
            VStack(alignment: .leading, spacing: BrainStyle.s) {
                ForEach(Array(app.timeline.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: BrainStyle.m) {
                        Text(verbatim: item.date.map(JobCopy.day) ?? "")
                            .font(BrainStyle.meta)
                            .foregroundStyle(Color.hxTextSecondary)
                            .monospacedDigit()
                            .frame(minWidth: 76, alignment: .leading)
                        Text(verbatim: item.text)
                            .font(item.note == true ? AppFont.body() : BrainStyle.rowSubtitle)
                            .foregroundStyle(Color.hxTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// The interview being booked or changed: a new one has no `interview`.
struct JobInterviewDraft: Identifiable {
    let appID: String
    let interview: JobInterview?
    var id: String { "\(appID)/\(interview?.key ?? "new")" }
}

/// Book an interview (a name and a day), or move or cancel a booked one.
struct JobInterviewSheet: View {
    let draft: JobInterviewDraft
    let model: JobApplicationModel
    @State private var label: String
    @State private var day: Date
    @Environment(\.dismiss) private var dismiss

    init(draft: JobInterviewDraft, model: JobApplicationModel) {
        self.draft = draft
        self.model = model
        _label = State(initialValue: draft.interview?.label ?? "")
        _day = State(initialValue: draft.interview.flatMap { JobCopy.isoFormatter.date(from: $0.on) } ?? Date())
    }

    var body: some View {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        NavigationStack {
            Form {
                TextField(text: $label) { Text(verbatim: "First round, Hello call, Onsite") }
                DatePicker(selection: $day, displayedComponents: .date) { Text(verbatim: "Day") }
                if let interview = draft.interview {
                    Button(role: .destructive) {
                        Task {
                            if await model.act(.interview(id: draft.appID, label: interview.label, on: nil, key: interview.key)) {
                                dismiss()
                            }
                        }
                    } label: { Text(verbatim: "Cancel this interview") }
                }
                if let error = model.error {
                    Text(verbatim: error).font(AppFont.footnote()).foregroundStyle(Color.hxDanger)
                }
            }
            .hxNavigationTitle(draft.interview == nil ? "Book an interview" : "Change interview")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.pending {
                        ProgressView().accessibilityLabel(Text(verbatim: "Saving"))
                    } else {
                        Button("Save") {
                            Task {
                                let on = JobCopy.isoFormatter.string(from: day)
                                if await model.act(.interview(id: draft.appID, label: name, on: on, key: draft.interview?.key)) {
                                    dismiss()
                                }
                            }
                        }
                        .disabled(name.isEmpty)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The page to read before an interview, in the app: the pitch, the company in a few lines, their asks against
/// his proof, another role to raise, likely questions, his questions for them, and what to keep in mind. Each
/// story name opens that story's Prep page. Pushed as `.brainRoute(.prep(.onePager(id)))`; reads its
/// application, so it is always the server's latest.
struct JobOnePagerView: View {
    @State private var model: JobApplicationModel
    @Environment(\.openURL) private var openURL

    init(id: String, server: URL, onAPIError: @escaping (Error) -> Void) {
        _model = State(initialValue: JobApplicationModel(
            id: id, client: APIClientJobPipelineAdapter(apiClient: APIClient(baseURL: server)), onAPIError: onAPIError))
    }

    var body: some View {
        content
            .hxNavigationTitle(title, subtitle: subtitle)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { FeedbackMoreMenu() } }
            .feedbackContext(FeedbackContext(feature: "Prep", screen: "One-pager", item: title))
            .background(Color.hxCanvas.ignoresSafeArea())
            .task { await model.load() }
    }

    private var title: String {
        if case .loaded(let app) = model.state { return app.row.name }
        return "One-pager"
    }

    private var subtitle: String? {
        if case .loaded(let app) = model.state { return app.onepager?.forLabel }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView(label: { Label { Text(verbatim: "Not in your pipeline") } icon: { Image(systemName: "doc.text") } },
                                   description: { Text(verbatim: "This application isn't on the server anymore.") })
        case .failed(let message):
            PrepFailedView(title: "Couldn't load the one-pager", message: message) { Task { await model.load() } }
        case .loaded(let app):
            if let page = app.onepager {
                ScrollView {
                    VStack(alignment: .leading, spacing: BrainStyle.xl) {
                        if let pitch = page.pitch { block("Your pitch") { Text(verbatim: pitch).font(AppFont.body()) } }
                        if !page.company.isEmpty { block("\(app.row.company ?? "The company") in 30 seconds") { bullets(page.company) } }
                        if !page.proof.isEmpty { block("What they ask for → your proof") { proofRows(page.proof) } }
                        if let raise = page.raise { raiseBlock(raise) }
                        if !page.questions.isEmpty { block("Likely questions") { questions(page.questions) } }
                        if !page.ask.isEmpty { block("Ask them") { bullets(page.ask) } }
                        if !page.watch.isEmpty { block("Keep in mind") { bullets(page.watch) } }
                        if !page.sources.isEmpty { sources(page.sources, updated: page.updated) }
                    }
                    .padding(BrainStyle.l)
                    .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
                }
                .refreshable { await model.load() }
            } else {
                ContentUnavailableView(label: { Label { Text(verbatim: "No one-pager yet") } icon: { Image(systemName: "doc.text") } },
                                       description: { Text(verbatim: "Ask Atlas to write one from the posting and your stories.") })
            }
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            BrainSectionHeader(title: title)
            HXCard(.neutral, spacing: BrainStyle.m) { content() }
        }
    }

    private func bullets(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.s) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "•").foregroundStyle(HermexPaper.prep.glow).accessibilityHidden(true)
                    Text(verbatim: line).font(AppFont.body()).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func proofRows(_ rows: [JobProofRow]) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.m) {
            ForEach(Array(rows.enumerated()), id: \.offset) { offset, row in
                if offset > 0 { PrepRowDivider() }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if row.gap {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(Color.hxWarning)
                                .accessibilityLabel(Text(verbatim: "Gap"))
                        }
                        Text(verbatim: row.need).font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(row.gap ? Color.hxWarning : Color.hxTextPrimary)
                    }
                    Text(verbatim: row.proof).font(AppFont.body()).fixedSize(horizontal: false, vertical: true)
                    storyLinks(row.stories)
                }
            }
        }
    }

    private func raiseBlock(_ raise: JobOnePagerRaise) -> some View {
        block("Raising \(raise.role)") {
            if let comp = raise.comp {
                Text(verbatim: comp).font(BrainStyle.meta).foregroundStyle(Color.hxTextSecondary)
            }
            if let when = raise.when {
                Text(verbatim: when).font(AppFont.body()).fixedSize(horizontal: false, vertical: true)
            }
            proofRows(raise.rows)
        }
    }

    private func questions(_ items: [JobOnePagerQuestion]) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.m) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, q in
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: q.text).font(AppFont.body()).fixedSize(horizontal: false, vertical: true)
                    storyLinks(q.stories)
                }
            }
        }
    }

    /// Each story as a chip that opens its Prep page.
    @ViewBuilder
    private func storyLinks(_ stories: [JobStoryRef]) -> some View {
        if !stories.isEmpty {
            FlowRow(spacing: 6) {
                ForEach(stories) { story in
                    NavigationLink(value: ShellPushDestination.brainRoute(.prep(.storyPage(story.id)))) {
                        HXChip(paper: .prep, symbol: "quote.bubble", label: story.name)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(verbatim: "Opens the story"))
                }
            }
        }
    }

    private func sources(_ items: [JobSource], updated: String?) -> some View {
        VStack(alignment: .leading, spacing: BrainStyle.xs) {
            BrainSectionHeader(title: "Sources", trailing: updated.map { "Updated \(JobCopy.day($0))" })
            ForEach(items, id: \.url) { source in
                if let url = URL(string: source.url) {
                    Button { openURL(url) } label: {
                        Text(verbatim: source.title).font(BrainStyle.meta).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
