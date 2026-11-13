import SwiftUI

/// Body's landing screen: the next workout, Baki's card, the week, every lift, recent sessions,
/// and last night's sleep. Pushed from the drawer as `.body`; workouts, lifts, and the plan push from here.
struct BodyHomeView: View {
    @State private var viewModel: BodyHomeViewModel
    @State private var showsSleep = false
    @Environment(\.openDraftChat) private var openDraftChat
    private let client: BodyDataClient
    /// Pushes a screen on the shell's stack (the Other day menu's buttons).
    private let onOpen: (ShellPushDestination) -> Void

    init(server: URL, onAPIError: @escaping (Error) -> Void, onOpen: @escaping (ShellPushDestination) -> Void) {
        self.onOpen = onOpen
        let client = APIClientBodyAdapter(apiClient: APIClient(baseURL: server))
        self.client = client
        _viewModel = State(initialValue: BodyHomeViewModel(client: client, onAPIError: onAPIError))
    }

    private var paper: HermexPaper { .training }

    var body: some View {
        content
            .hxNavigationTitle("Body", subtitle: subtitle)
            .background(Color.hxCanvas.ignoresSafeArea())
            .toolbar {
                if case .loaded = viewModel.state {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: ShellPushDestination.bodyPlan) {
                            Label { Text(verbatim: "Plan") } icon: { Image(systemName: "pencil") }
                                .labelStyle(.titleAndIcon)
                        }
                        .accessibilityHint(Text(verbatim: "Edits the training plan"))
                    }
                }
            }
            // Every appear refreshes, so a finished workout shows on the way back.
            .task { await viewModel.load() }
            .sheet(isPresented: $showsSleep) {
                SleepView(viewModel: SleepViewModel(today: .now) { [client] in try await client.sleepHistory() })
            }
    }

    private var subtitle: String? {
        guard case .loaded(let home) = viewModel.state, !home.phaseLabel.isEmpty else { return nil }
        return home.phaseLabel
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label { Text(verbatim: "No Body on this server") } icon: {
                    Image(systemName: "figure.strengthtraining.traditional")
                }
            } description: {
                Text(verbatim: "This server doesn't serve Body. It needs the Body API from your hermes-webui fork.")
            }
        case .failed(let message):
            HXFailedView(title: "Couldn't load Body", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let home):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.l) {
                    upNext(home)
                    bakiCard(home.proposals)
                    thisWeek(home)
                    if !home.lifts.isEmpty { lifts(home.lifts) }
                    if !home.sessions.isEmpty { sessions(home.sessions) }
                    if let sleep = home.sleep { sleepRow(sleep) }
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
        }
    }

    // MARK: Baki

    /// Baki's one place on Body home: his note on the newest workout, each change waiting for a
    /// yes or no, and the way to ask him something.
    private func bakiCard(_ proposals: [BodyProposal]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Baki")
            HXCard(.wash(paper), spacing: 10) {
                BodyCoachKicker(text: BodyHomeCopy.bakiKicker(viewModel.latestNote))
            } content: {
                if let latest = viewModel.latestNote {
                    BakiNoteText(note: latest.note)
                } else if proposals.isEmpty {
                    Text(verbatim: "Ask about a lift, your plan, or how you feel. His note on each workout lands here.")
                        .font(AppFont.subheadline())
                        .foregroundStyle(paper.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(proposals) { proposal in
                    BakiRule()
                    proposalRows(proposal)
                }
                if let error = viewModel.decideError {
                    Text(verbatim: error)
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxDanger)
                }
            } footer: {
                if openDraftChat.isAvailable {
                    BakiRule()
                    BakiAskRow()
                }
            }
        }
    }

    /// One change to approve, inside Baki's card: what changes, why, and Accept or Skip.
    private func proposalRows(_ proposal: BodyProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "A change to approve")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(paper.glow)
            Text(verbatim: proposal.title)
                .font(AppFont.body(weight: .semibold))
                .foregroundStyle(Color.hxTextPrimary)
            ForEach(Array(proposal.why.enumerated()), id: \.offset) { _, reason in
                Text(verbatim: reason)
                    .font(AppFont.footnote())
                    .foregroundStyle(paper.secondaryInk)
            }
            HStack(spacing: 8) {
                Button { Task { await viewModel.decide(proposal, accept: true) } } label: {
                    Text(verbatim: "Accept").bodyTapHeight()
                }
                .buttonStyle(ChatDecisionButtonStyle(emphasis: .primary))
                .accessibilityLabel(Text(verbatim: "Accept: \(proposal.title)"))
                Button { Task { await viewModel.decide(proposal, accept: false) } } label: {
                    Text(verbatim: "Skip").bodyTapHeight()
                }
                .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
                .accessibilityLabel(Text(verbatim: "Skip: \(proposal.title)"))
            }
            .disabled(viewModel.deciding.contains(proposal.id))
            .padding(.top, 4)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Up next

    private func upNext(_ home: BodyHome) -> some View {
        let doneToday = BodyHomeCopy.doneToday(home.sessions, today: BodyHomeCopy.localDay(.now))
        return HXCard(.glow(paper), title: home.next?.label ?? doneToday ?? idleLine(home),
               titleStyle: home.next == nil ? .title3 : .title, spacing: 12) {
            if home.next != nil {
                Text(verbatim: doneToday.map { "\($0) · Up next" } ?? "Up next")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(paper.glow)
            }
        } content: {
            if home.next == nil, doneToday != nil {
                Text(verbatim: idleLine(home, liftedToday: true))
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let next = home.next {
                VStack(spacing: 7) {
                    ForEach(Array(next.preview.enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(verbatim: row.name)
                                .font(AppFont.subheadline())
                                .foregroundStyle(Color.hxTextPrimary)
                            Spacer(minLength: 8)
                            Text(verbatim: row.up ? "\(row.weightLabel) ↑" : row.weightLabel)
                                .font(AppFont.subheadline(weight: row.up ? .semibold : nil))
                                .foregroundStyle(row.up ? paper.glow : Color.hxTextPrimary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Text(verbatim: row.up
                            ? "\(row.name), \(row.weightLabel), going up" : "\(row.name), \(row.weightLabel)"))
                    }
                }
                if next.preview.contains(where: \.up) {
                    Text(verbatim: "↑ goes up today: every set hit the top of the range last time.")
                        .font(AppFont.footnote())
                        .foregroundStyle(paper.glow)
                }
            }
        } footer: {
            if let next = home.next {
                let others = BodyHomeCopy.otherDays(
                    than: next.day, sessions: home.sessions, today: BodyHomeCopy.localDay(.now))
                // Side by side when they fit; stacked at large text sizes.
                VStack(spacing: 4) { startButtons(next, others: others) }
                    .environment(\.hxPaper, paper)
                    .padding(.top, 4)
            } else {
                let days = BodyHomeCopy.otherDays(
                    than: "", sessions: home.sessions, today: BodyHomeCopy.localDay(.now))
                if !days.isEmpty { liftAnyway(days, phase: home.phase) }
            }
        }
    }

    /// With nothing scheduled: one button per day still open today. Before Re-entry the server
    /// prescribes a picked day at Re-entry weights.
    private func liftAnyway(_ days: [String], phase: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: ["before", "recover"].contains(phase) ? "Lift anyway, at Re-entry weights" : "Lift anyway")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(paper.glow)
            HStack(spacing: 10) {
                ForEach(days, id: \.self) { day in
                    NavigationLink(value: ShellPushDestination.bodyWorkout(day)) {
                        Text(verbatim: day.capitalized).bodyTapHeight()
                    }
                    .buttonStyle(ChatDecisionButtonStyle(emphasis: .secondary))
                    .accessibilityLabel(Text(verbatim: "Start \(day.capitalized)"))
                }
            }
        }
        .environment(\.hxPaper, paper)
        .padding(.top, 4)
    }

    /// With no next workout: when lifting starts, or the Recover week's line.
    private func idleLine(_ home: BodyHome, liftedToday: Bool = false) -> String {
        if let starts = home.starts { return liftedToday ? "The plan starts \(starts)." : "Starts \(starts)" }
        if home.phase == "recover" {
            return liftedToday ? "Recover week: walk, stretch, and sleep." : "Recover week: no lifting yet. Walk, stretch, and sleep."
        }
        return "Nothing is scheduled."
    }

    /// Start, and the Other day menu when a day is left to switch to.
    @ViewBuilder
    private func startButtons(_ next: BodyNext, others: [String]) -> some View {
        NavigationLink(value: ShellPushDestination.bodyWorkout(nil)) {
            Text(verbatim: "Start \(next.label)").bodyPrimaryHeight()
        }
        .buttonStyle(ChatDecisionButtonStyle(emphasis: .primary))
        if !others.isEmpty { otherDayMenu(others) }
    }

    private func otherDayMenu(_ days: [String]) -> some View {
        Menu {
            ForEach(days, id: \.self) { other in
                Button(other.capitalized) { onOpen(.bodyWorkout(other)) }
            }
        } label: {
            Text(verbatim: "Lift a different day")
                .font(AppFont.subheadline())
                .foregroundStyle(paper.glow)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityHint(Text(verbatim: "Do a different day"))
    }

    // MARK: This week

    private func thisWeek(_ home: BodyHome) -> some View {
        let week = home.week
        return VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "This week")
            VStack(alignment: .leading, spacing: 12) {
                BodyWeekDots(
                    title: "Lifted", subtitle: BodyHomeCopy.liftedLabels(week: week, sessions: home.sessions),
                    states: week.lifted, showsWeekdays: true)
                BodyWeekDots(title: "Ran", subtitle: "From Garmin", states: week.ran)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hxCard()
        }
    }

    // MARK: Sleep

    private func sleepRow(_ sleep: BodyHomeSleep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Sleep")
            Button { showsSleep = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "moon.fill")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(HermexPaper.training.glow)
                        .frame(width: 30, height: 30)
                        .background(HermexPaper.training.wash, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: BodyHomeCopy.sleepTitle(hours: sleep.hours))
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(Color.hxTextPrimary)
                        if let detail = BodyHomeCopy.sleepDetail(sleep) {
                            Text(verbatim: detail)
                                .font(AppFont.caption())
                                .foregroundStyle(Color.hxTextSecondary)
                        }
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        Text(verbatim: "Sleep trends")
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                    .font(AppFont.caption())
                    .foregroundStyle(Color.hxTextSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hxCard()
            .accessibilityHint(Text(verbatim: "Opens your sleep history"))
        }
    }

    // MARK: Lifts

    private func lifts(_ lifts: [BodyHomeLift]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Lifts")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(BodyHomeCopy.liftGroups(lifts).enumerated()), id: \.element.id) { groupOffset, group in
                    if groupOffset > 0 { Divider() }
                    Text(verbatim: group.title)
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(paper.glow)
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(group.lifts.enumerated()), id: \.element.id) { offset, lift in
                        if offset > 0 { Divider().padding(.leading, 14) }
                        NavigationLink(value: ShellPushDestination.bodyLift(lift.id)) {
                            liftRow(lift)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .hxCard()
        }
    }

    private func liftRow(_ lift: BodyHomeLift) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: lift.name)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                if !lift.dots.isEmpty { setDots(lift.dots) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: lift.weightLabel)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(Color.hxTextPrimary)
                if lift.up {
                    Text(verbatim: lift.upFromLabel.map { "↑ from \($0)" } ?? "↑ up").foregroundStyle(paper.glow)
                } else if let goal = lift.goalReps, !goal.isEmpty {
                    Text(verbatim: BodyHomeCopy.goalLabel(goal)).foregroundStyle(Color.hxTextSecondary)
                }
            }
            .font(AppFont.caption())
            BodyChevron()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: BodyHomeCopy.liftSummary(lift)))
    }

    /// One dot per work set of the last session: filled when it was done at the top of its range.
    private func setDots(_ dots: [Bool]) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(dots.enumerated()), id: \.offset) { _, hit in
                Circle()
                    .strokeBorder(paper.glow, lineWidth: 1.5)
                    .background(Circle().fill(hit ? paper.glow : Color.clear))
                    .frame(width: 10, height: 10)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Sessions

    /// A lift that went up reads in the training glow; a rough night's note in the `notes` glow.
    private func detailColor(_ session: BodySessionSummary) -> Color {
        if session.highlight != nil { return paper.glow }
        return session.trimmed ? HermexPaper.notes.glow : Color.hxTextSecondary
    }

    private func sessions(_ sessions: [BodySessionSummary]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Sessions")
            VStack(spacing: 0) {
                ForEach(Array(sessions.prefix(5).enumerated()), id: \.element.id) { offset, session in
                    if offset > 0 { Divider().padding(.leading, 14) }
                    NavigationLink(value: ShellPushDestination.bodySession(session.id)) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: session.label)
                                .font(AppFont.subheadline(weight: .semibold))
                                .foregroundStyle(Color.hxTextPrimary)
                            Text(verbatim: BodyHomeCopy.sessionSubtitle(session))
                                .font(AppFont.caption())
                                .foregroundStyle(Color.hxTextSecondary)
                        }
                        Spacer(minLength: 8)
                        if let detail = session.highlight ?? session.note {
                            Text(verbatim: detail)
                                .font(AppFont.caption())
                                .foregroundStyle(detailColor(session))
                                .multilineTextAlignment(.trailing)
                                .lineLimit(2)
                        }
                        BodyChevron()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(verbatim: "Opens this workout and Baki's note"))
                }
            }
            .hxCard()
        }
    }
}
