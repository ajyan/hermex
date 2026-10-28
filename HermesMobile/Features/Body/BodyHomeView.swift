import SwiftUI

/// Body's landing screen: the next workout, the week, last night's sleep, every lift, and recent
/// sessions. Pushed from the drawer as `.body`; workouts, lifts, and the plan push from here.
struct BodyHomeView: View {
    @State private var viewModel: BodyHomeViewModel
    @State private var showsSleep = false
    private let client: BodyDataClient

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
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
            PrepFailedView(title: "Couldn't load Body", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded(let home):
            ScrollView {
                VStack(alignment: .leading, spacing: BrainStyle.l) {
                    proposalSlot(home.proposals)
                    upNext(home)
                    thisWeek(home.week)
                    if let sleep = home.sleep { sleepRow(sleep) }
                    if !home.lifts.isEmpty { lifts(home.lifts) }
                    if !home.sessions.isEmpty { sessions(home.sessions) }
                }
                .padding(BrainStyle.l)
                .adaptiveReadableContent(maxWidth: AdaptiveReadableContentWidth.secondaryDestination)
            }
            .refreshable { await viewModel.load() }
        }
    }

    // MARK: Proposals

    /// Baki's pending proposals sit above Up next. Task 12 fills this slot with the proposal card.
    @ViewBuilder
    private func proposalSlot(_ proposals: [BodyProposal]) -> some View {
        EmptyView()
    }

    // MARK: Up next

    private func upNext(_ home: BodyHome) -> some View {
        HXCard(.glow(paper), title: home.next?.label ?? "Body", titleStyle: .title, spacing: 12) {
            Text(verbatim: "Up next")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(paper.glow)
        } content: {
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
            } else {
                Text(verbatim: idleLine(home))
                    .font(AppFont.subheadline())
                    .foregroundStyle(Color.hxTextSecondary)
            }
        } footer: {
            if let next = home.next {
                HStack(spacing: 10) {
                    NavigationLink(value: ShellPushDestination.bodyWorkout(nil)) {
                        Text(verbatim: "Start \(next.label)")
                            .font(AppFont.display(style: .headline, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(paper.glow)
                    otherDayMenu(than: next.day)
                }
                .padding(.top, 4)
            }
        }
    }

    /// With no next workout: when lifting starts, or the Recover week's line.
    private func idleLine(_ home: BodyHome) -> String {
        if let starts = home.starts { return "Starts \(starts)" }
        if home.phase == "recover" { return "Recover week: no lifting yet. Walk, stretch, and sleep." }
        return "Nothing is scheduled."
    }

    private func otherDayMenu(than day: String) -> some View {
        Menu {
            ForEach(BodyHomeCopy.otherDays(than: day), id: \.self) { other in
                NavigationLink(value: ShellPushDestination.bodyWorkout(other)) {
                    Text(verbatim: other.capitalized)
                }
            }
        } label: {
            Text(verbatim: "Other day")
                .font(AppFont.subheadline(weight: .semibold))
                .foregroundStyle(paper.glow)
                .padding(.horizontal, 18)
                .frame(minHeight: 44)
                .background(paper.wash, in: Capsule())
                .overlay(Capsule().strokeBorder(paper.edge, lineWidth: 0.5))
        }
        .accessibilityHint(Text(verbatim: "Do a different day"))
    }

    // MARK: This week

    private func thisWeek(_ week: BodyWeek) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "This week")
            VStack(alignment: .leading, spacing: 12) {
                BodyWeekDots(title: "Lifted", states: week.lifted, showsWeekdays: true)
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
                        .foregroundStyle(HermexPaper.notes.glow)
                        .frame(width: 30, height: 30)
                        .background(HermexPaper.notes.wash, in: RoundedRectangle(cornerRadius: HXRadius.sm, style: .continuous))
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
            VStack(spacing: 0) {
                ForEach(Array(lifts.enumerated()), id: \.element.id) { offset, lift in
                    if offset > 0 { Divider().padding(.leading, 14) }
                    NavigationLink(value: ShellPushDestination.bodyLift(lift.id)) {
                        liftRow(lift)
                    }
                    .buttonStyle(.plain)
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
                    Text(verbatim: "↑ up").foregroundStyle(paper.glow)
                } else if let goal = lift.goalReps, !goal.isEmpty {
                    Text(verbatim: BodyHomeCopy.goalLabel(goal)).foregroundStyle(Color.hxTextSecondary)
                } else {
                    Text(verbatim: "Hold").foregroundStyle(Color.hxTextSecondary)
                }
            }
            .font(AppFont.caption())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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

    private func sessions(_ sessions: [BodySessionSummary]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HXSectionHeader(title: "Sessions")
            VStack(spacing: 0) {
                ForEach(Array(sessions.prefix(5).enumerated()), id: \.element.id) { offset, session in
                    if offset > 0 { Divider().padding(.leading, 14) }
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
                                .foregroundStyle(session.highlight == nil ? Color.hxTextSecondary : paper.glow)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                }
            }
            .hxCard()
        }
    }
}
