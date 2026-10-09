import SwiftUI

enum DailyDeckJournalError: LocalizedError {
    case missing
    var errorDescription: String? { "There's no journal entry for this day." }
}

enum DailyDeckJournal {
    /// A journal entry as the reader should see it: front matter and the agent's
    /// `<!-- … -->` markers dropped.
    static func readable(_ text: String) -> String {
        var body = strippingFrontmatter(text)
        body = body.replacingOccurrences(of: #"<!--.*?-->\n?"#, with: "", options: .regularExpression)
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` without a leading YAML frontmatter block (`---` … `---`); text without
    /// one is returned unchanged.
    static func strippingFrontmatter(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return text }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The days of `month` laid out in weeks: nil pads the first week to the locale's first weekday.
    static func grid(year: Int, month: Int, calendar: Calendar = .current) -> [Int?] {
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: first)
        else { return [] }
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + range.map { Optional($0) }
    }
}

/// A month at a time: days with a journal entry are tappable and open that day's
/// entry; a dot marks days with a brief deck (filled once it was filed).
struct DeckCalendarView: View {
    let viewModel: DailyDeckViewModel
    /// Opens a day's brief cards in the deck behind this sheet.
    let openDeck: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var year: Int
    @State private var month: Int
    @State private var journalDays: Set<String> = []
    @State private var isLoading = false

    init(viewModel: DailyDeckViewModel, openDeck: @escaping (String) -> Void) {
        self.viewModel = viewModel
        self.openDeck = openDeck
        let parts = viewModel.date.split(separator: "-").compactMap { Int($0) }
        _year = State(initialValue: parts.first ?? 2026)
        _month = State(initialValue: parts.count > 1 ? parts[1] : 1)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    monthHeader
                    weekdayHeader
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                        ForEach(Array(DailyDeckJournal.grid(year: year, month: month).enumerated()), id: \.offset) { _, day in
                            if let day { dayCell(day) } else { Color.clear.frame(height: 48) }
                        }
                    }
                    legend
                }
                .padding(16)
            }
            .background(Color.hxCanvas.ignoresSafeArea())
            .navigationTitle(Text(verbatim: "Journal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Done") }
                }
            }
            .navigationDestination(for: String.self) { day in
                DayLogView(day: day, viewModel: viewModel) {
                    dismiss()
                    openDeck(day)
                }
            }
            .task(id: "\(year)-\(month)") {
                isLoading = true
                journalDays = await viewModel.journalDays(year: year, month: month)
                isLoading = false
            }
        }
    }

    private var monthHeader: some View {
        HStack {
            Button { step(-1) } label: { Image(systemName: "chevron.backward").frame(width: 44, height: 44) }
                .accessibilityLabel(Text(verbatim: "Previous month"))
            Spacer()
            Text(verbatim: monthTitle).font(AppFont.headline())
            if isLoading { ProgressView().controlSize(.small) }
            Spacer()
            Button { step(1) } label: { Image(systemName: "chevron.forward").frame(width: 44, height: 44) }
                .disabled(isCurrentMonth)
                .accessibilityLabel(Text(verbatim: "Next month"))
        }
    }

    private var weekdayHeader: some View {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        let first = Calendar.current.firstWeekday - 1
        return HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { i in
                Text(verbatim: symbols[(i + first) % 7])
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private func dayCell(_ day: Int) -> some View {
        let key = String(format: "%04d-%02d-%02d", year, month, day)
        let hasEntry = journalDays.contains(key)
        let hasDeck = viewModel.availableDates.contains(key)
        let isToday = key == viewModel.today
        return NavigationLink(value: key) {
            VStack(spacing: 3) {
                Text(verbatim: "\(day)")
                    .font(AppFont.body(weight: isToday ? .semibold : nil))
                    .foregroundStyle(hasEntry ? Color.primary : Color.secondary.opacity(0.5))
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: hasDeck ? 1.2 : 0)
                    .background(Circle().fill(viewModel.filedDates.contains(key) ? Color.accentColor : .clear))
                    .frame(width: 6, height: 6)
                    .opacity(hasDeck ? 1 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(hasEntry ? Color.hxSurface : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!hasEntry && !hasDeck)
        .accessibilityLabel(Text(verbatim: accessibilityLabel(key, hasEntry: hasEntry, hasDeck: hasDeck)))
    }

    private var legend: some View {
        HStack(spacing: 16) {
            Label { Text(verbatim: "Brief filed") } icon: { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
            Label { Text(verbatim: "Brief not filed") } icon: { Circle().strokeBorder(Color.accentColor, lineWidth: 1.2).frame(width: 6, height: 6) }
        }
        .font(AppFont.caption())
        .foregroundStyle(.secondary)
    }

    private var monthTitle: String {
        guard let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) else { return "" }
        return date.formatted(.dateTime.month(.wide).year())
    }

    private var isCurrentMonth: Bool {
        viewModel.today.hasPrefix(String(format: "%04d-%02d", year, month))
    }

    private func step(_ delta: Int) {
        var m = month + delta, y = year
        if m < 1 { m = 12; y -= 1 }
        if m > 12 { m = 1; y += 1 }
        month = m
        year = y
    }

    private func accessibilityLabel(_ key: String, hasEntry: Bool, hasDeck: Bool) -> String {
        var parts = [DailyDeckPaths.label(key)]
        if hasEntry { parts.append("journal entry") }
        if hasDeck { parts.append(viewModel.filedDates.contains(key) ? "brief filed" : "brief not filed") }
        return parts.joined(separator: ", ")
    }
}

/// One day's journal entry, read-only, with a way into that day's brief cards.
private struct DayLogView: View {
    let day: String
    let viewModel: DailyDeckViewModel
    let openDeck: () -> Void
    @State private var state: BrainLoadState<String> = .loading

    var body: some View {
        content
            .navigationTitle(Text(verbatim: DailyDeckPaths.label(day)))
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.hxCanvas.ignoresSafeArea())
            .toolbar {
                if viewModel.availableDates.contains(day) {
                    ToolbarItem(placement: .bottomBar) {
                        Button(action: openDeck) {
                            Label { Text(verbatim: "Open Brief Cards") } icon: { Image(systemName: "rectangle.stack") }
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
            }
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable, .failed:
            ContentUnavailableView {
                Label { Text(verbatim: "No journal entry") } icon: { Image(systemName: "book.closed") }
            } description: {
                if case .failed(let message) = state { Text(verbatim: message) }
            }
        case .loaded(let body):
            ScrollView {
                MarkdownRenderer(content: body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await viewModel.journalEntry(for: day))
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
