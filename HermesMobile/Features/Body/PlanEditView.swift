import SwiftUI

/// The plan editor (board 4), pushed as `.bodyPlan` from Body home's Plan button or a lift's page.
/// A day at a time: exercises grouped by section, dragged to reorder, tapped to open their
/// numbers. Nothing is sent until Save, which sends the whole plan; the server's 400 message
/// shows at the top while his edits stay.
struct PlanEditView: View {
    @State private var viewModel: PlanEditViewModel
    @State private var day = ""
    @State private var openID: String?
    @State private var removal: Removal?
    @State private var isAdding = false
    @State private var newName = ""
    @State private var confirmsDiscard = false
    @Environment(\.dismiss) private var dismiss

    private struct Removal: Identifiable {
        let day: String
        let id: String
        let name: String
    }

    init(server: URL, onAPIError: @escaping (Error) -> Void) {
        let client = APIClientBodyAdapter(apiClient: APIClient(baseURL: server))
        _viewModel = State(initialValue: PlanEditViewModel(client: client, onAPIError: onAPIError))
    }

    private var paper: HermexPaper { .training }

    var body: some View {
        content
            .hxNavigationTitle("Plan")
            .background(Color.hxCanvas.ignoresSafeArea())
            // With unsaved edits, Back would lose them silently; Cancel asks first.
            .navigationBarBackButtonHidden(viewModel.dirty)
            .toolbar {
                if viewModel.dirty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { confirmsDiscard = true } label: { Text(verbatim: "Cancel") }
                    }
                }
                if viewModel.phase == .loaded {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { save() } label: { Text(verbatim: "Save").fontWeight(.semibold) }
                            .disabled(!viewModel.dirty || viewModel.isSaving)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button { Self.endEditing() } label: { Text(verbatim: "Done") }
                }
            }
            .task {
                await viewModel.load()
                if day.isEmpty { day = viewModel.dayKeys.first { $0 != "warmup" } ?? viewModel.dayKeys.first ?? "" }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .confirmationDialog(
                removal.map { "Remove \($0.name) from \(PlanEditCopy.dayTitle($0.day))?" } ?? "Remove this exercise?",
                isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
                titleVisibility: .visible, presenting: removal
            ) { item in
                Button("Remove", role: .destructive) {
                    viewModel.remove(day: item.day, id: item.id)
                    if openID == item.id { openID = nil }
                }
                Button("Keep it", role: .cancel) {}
            } message: { item in
                Text(verbatim: "Past sessions keep their history. It leaves \(PlanEditCopy.dayTitle(item.day)) once you save.")
            }
            .alert("Add exercise", isPresented: $isAdding) {
                TextField("Name", text: $newName)
                Button("Add") { addExercise() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(verbatim: "It goes at the end of \(PlanEditCopy.dayTitle(day)). Set its sets and weights after.")
            }
    }

    private static func endEditing() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label { Text(verbatim: "No Body on this server") } icon: { Image(systemName: "figure.strengthtraining.traditional") }
            } description: {
                Text(verbatim: "This server doesn't serve Body. It needs the Body API from your hermes-webui fork.")
            }
        case .failed(let message):
            PrepFailedView(title: "Couldn't load the plan", message: message) {
                Task { await viewModel.load() }
            }
        case .loaded:
            VStack(spacing: 0) {
                if let error = viewModel.saveError { errorBanner(error) }
                Picker(selection: $day) {
                    ForEach(viewModel.dayKeys, id: \.self) { Text(verbatim: PlanEditCopy.dayTitle($0)).tag($0) }
                } label: { Text(verbatim: "Day") }
                .pickerStyle(.segmented)
                .padding(.horizontal, BrainStyle.l)
                .padding(.vertical, 8)
                .onChange(of: day) { openID = nil }
                list
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Text(verbatim: message)
            .font(AppFont.subheadline())
            .foregroundStyle(Color.hxDanger)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.hxDanger.opacity(0.10), in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
            .padding(.horizontal, BrainStyle.l)
            .padding(.top, 8)
            .accessibilityAddTraits(.isStaticText)
    }

    /// Sections in the order a workout runs them, only the ones this day has.
    private static let sectionOrder: [BodySection] = [.warmup, .main, .superset, .optional, .finisher]

    private var list: some View {
        let exercises = viewModel.exercises(day: day)
        let groups = Self.sectionOrder.compactMap { section -> (BodySection, [BodyPlanExercise])? in
            let items = exercises.filter { $0.section == section }
            return items.isEmpty ? nil : (section, items)
        }
        return List {
            ForEach(groups, id: \.0) { section, items in
                Section {
                    ForEach(items) { exercise in
                        PlanExerciseRow(
                            exercise: exercise, day: day, isOpen: openID == exercise.id,
                            toggle: { openID = openID == exercise.id ? nil : exercise.id },
                            update: { change in viewModel.update(day: day, id: exercise.id, change) },
                            remove: { removal = Removal(day: day, id: exercise.id, name: exercise.name) })
                        .listRowBackground(rowBackground(open: openID == exercise.id))
                    }
                    .onMove { source, destination in
                        viewModel.move(day: day, section: section, from: source, to: destination)
                    }
                } header: {
                    HXSectionHeader(title: WorkoutCopy.sectionTitle(section)).textCase(nil)
                }
            }
            Section {
                Button {
                    newName = ""
                    isAdding = true
                } label: {
                    Text(verbatim: "+ Add exercise")
                        .font(AppFont.subheadline(weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .listRowBackground(Color.hxSurface)
            }
            Section { phases }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // Drag handles show all the time, as on the board.
        .environment(\.editMode, .constant(.active))
        .scrollDismissesKeyboard(.interactively)
    }

    /// The open exercise sits in the training wash over the card; the rest are plain.
    @ViewBuilder
    private func rowBackground(open: Bool) -> some View {
        if open {
            Color.hxSurface.overlay(paper.wash)
        } else {
            Color.hxSurface
        }
    }

    private func addExercise() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let section: BodySection = day == "warmup" ? (viewModel.exercises(day: day).first?.section ?? .warmup) : .main
        openID = viewModel.add(day: day, exercise: .draft(name: name, section: section))
    }

    private func save() {
        Task {
            do {
                try await viewModel.save()
                dismiss()
            } catch {
                // The reason is on screen (`saveError`); his edits stay.
            }
        }
    }

    // MARK: Phases

    private static let phaseOrder = ["recover", "reentry", "build", "newborn"]

    private var phases: some View {
        DisclosureGroup {
            ForEach(Self.phaseOrder.filter { viewModel.plan.phases[$0] != nil }, id: \.self) { name in
                phaseDates(name)
            }
        } label: {
            Text(verbatim: "Phases").font(AppFont.subheadline(weight: .semibold))
        }
        .listRowBackground(Color.hxSurface)
    }

    @ViewBuilder
    private func phaseDates(_ name: String) -> some View {
        let title = WorkoutCopy.phaseLabel(name, deload: false) ?? name.capitalized
        if let spec = viewModel.plan.phases[name] {
            VStack(alignment: .leading, spacing: 2) {
                datePicker("\(title) starts", iso: spec.start) { viewModel.setPhase(name, end: false, to: $0) }
                if let end = spec.end {
                    datePicker("\(title) ends", iso: end) { viewModel.setPhase(name, end: true, to: $0) }
                }
            }
        }
    }

    private func datePicker(_ title: String, iso: String, set: @escaping (Date) -> Void) -> some View {
        DatePicker(selection: Binding(
            get: { PlanEditCopy.parse(iso) ?? Date() },
            set: set
        ), displayedComponents: .date) {
            Text(verbatim: title).font(AppFont.subheadline())
        }
        .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .current)
        .frame(minHeight: 44)
    }
}

// MARK: - One exercise

/// An exercise in the day: its name and prescription, and, when opened, every number the plan
/// keeps for it.
private struct PlanExerciseRow: View {
    let exercise: BodyPlanExercise
    let day: String
    let isOpen: Bool
    let toggle: () -> Void
    let update: ((inout BodyPlanExercise) -> Void) -> Void
    let remove: () -> Void

    private var paper: HermexPaper { .training }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Text(verbatim: exercise.name)
                        .font(AppFont.body(weight: isOpen ? .semibold : nil))
                        .foregroundStyle(isOpen ? paper.glow : Color.hxTextPrimary)
                    Spacer(minLength: 8)
                    if isOpen {
                        Image(systemName: "chevron.up")
                            .font(AppFont.caption(weight: .semibold))
                            .foregroundStyle(Color.hxTextSecondary)
                            .accessibilityHidden(true)
                    } else {
                        Text(verbatim: PlanEditCopy.summary(exercise))
                            .font(AppFont.subheadline())
                            .foregroundStyle(Color.hxTextSecondary)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(verbatim: isOpen ? "Closes the editor" : "Edits this exercise"))
            if isOpen { editor }
        }
    }

    // MARK: Editor

    private var editor: some View {
        VStack(spacing: 0) {
            stepperRow("Sets", value: Binding(get: { exercise.sets }, set: { v in update { $0.sets = v } }), range: 1...12)
            targetRows
            if PlanEditCopy.hasWeight(exercise.load.unit) { weightRows }
            pickerRow("Load", selection: Binding(get: { exercise.load.unit }, set: { v in update { $0.load.unit = v } }),
                      options: PlanEditCopy.units.map { ($0, PlanEditCopy.unitTitle($0)) })
            if day != "warmup" {
                pickerRow("Section", selection: Binding(get: { exercise.section }, set: { v in update { $0.section = v } }),
                          options: [BodySection.main, .superset, .optional, .finisher].map { ($0, WorkoutCopy.sectionTitle($0)) })
            }
            toggleRow("In newborn mode", isOn: Binding(get: { exercise.newborn }, set: { v in update { $0.newborn = v } }))
            toggleRow("Big lift", isOn: Binding(get: { exercise.big }, set: { v in update { $0.big = v } }))
            Button(role: .destructive, action: remove) {
                Text(verbatim: "Remove from \(PlanEditCopy.dayTitle(day))")
                    .font(AppFont.body())
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.hxDanger)
        }
        .padding(.leading, 4)
        .environment(\.hxPaper, paper)
    }

    /// Reps as a low and a high end, or the hold's seconds, or the carry's yards.
    @ViewBuilder
    private var targetRows: some View {
        if let reps = exercise.reps, reps.count == 2 {
            stepperRow("Fewest reps", value: Binding(get: { reps[0] }, set: { v in
                update { $0.reps = [v, max(v, reps[1])] }
            }), range: 1...50)
            stepperRow("Most reps", value: Binding(get: { reps[1] }, set: { v in
                update { $0.reps = [min(reps[0], v), v] }
            }), range: 1...50)
        } else if let hold = exercise.holdS {
            stepperRow("Hold, seconds", value: Binding(get: { hold }, set: { v in update { $0.holdS = v } }),
                       range: 5...300, step: 5)
        } else if let distance = exercise.distanceYd {
            stepperRow("Distance, yards", value: Binding(get: { distance }, set: { v in update { $0.distanceYd = v } }),
                       range: 5...200, step: 5)
        }
    }

    private var weightRows: some View {
        let suffix = exercise.load.unit == "lb_each" ? "lb each" : "lb"
        let percent: String? = {
            guard let build = exercise.load.build, build > 0, let reentry = exercise.load.reentry else { return nil }
            return "\(Int((reentry / build * 100).rounded()))%"
        }()
        return VStack(spacing: 0) {
            numberRow("Build weight", value: Binding(get: { exercise.load.build }, set: { v in update { $0.load.build = v } }),
                      suffix: suffix)
            numberRow("Re-entry weight", value: Binding(get: { exercise.load.reentry }, set: { v in update { $0.load.reentry = v } }),
                      suffix: suffix, detail: percent)
            numberRow("Goes up by", value: Binding(get: { exercise.load.increment }, set: { v in update { $0.load.increment = v } }),
                      suffix: suffix)
        }
    }

    // MARK: Fields

    private func stepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(verbatim: title).font(AppFont.body())
                Spacer(minLength: 8)
                Text(verbatim: String(value.wrappedValue))
                    .font(AppFont.body(weight: .semibold))
                    .monospacedDigit()
            }
        }
        .frame(minHeight: 44)
        .accessibilityValue(Text(verbatim: String(value.wrappedValue)))
    }

    private func numberRow(_ title: String, value: Binding<Double?>, suffix: String, detail: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title).font(AppFont.body())
            Spacer(minLength: 8)
            if let detail {
                Text(verbatim: detail).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
            }
            TextField(value: value, format: .number) { Text(verbatim: title) }
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(AppFont.body(weight: .semibold))
                .monospacedDigit()
                .frame(width: 72)
            Text(verbatim: suffix).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
        }
        .frame(minHeight: 44)
    }

    private func pickerRow<Value: Hashable>(_ title: String, selection: Binding<Value>, options: [(Value, String)]) -> some View {
        HStack {
            Text(verbatim: title).font(AppFont.body())
            Spacer(minLength: 8)
            Picker(selection: selection) {
                ForEach(options, id: \.0) { value, name in Text(verbatim: name).tag(value) }
            } label: { Text(verbatim: title) }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .frame(minHeight: 44)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Text(verbatim: title).font(AppFont.body()) }
            .frame(minHeight: 44)
    }
}
