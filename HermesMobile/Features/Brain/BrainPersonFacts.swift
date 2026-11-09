import SwiftUI

/// The facts Atlas relies on when it writes about a person, as their page holds them
/// (`person.editable`). The contact file is the source of truth; the page edits it.
struct BrainPersonFacts: Codable, Hashable, Sendable {
    /// How they relate to him, in his words: "Friend (met at school)".
    let relationship: String
    /// partner, family, friend, colleague, mentor or network; empty when the page has none.
    let relationshipType: String
    /// "1990-05-02", "05-02" when the year is unknown, or empty.
    let birthday: String
    /// Family lines by label ("Partner", "Children", …), names as plain text.
    let family: [BrainFact]

    private enum CodingKeys: String, CodingKey { case relationship, relationshipType, birthday, family }

    init(relationship: String = "", relationshipType: String = "", birthday: String = "", family: [BrainFact] = []) {
        self.relationship = relationship
        self.relationshipType = relationshipType
        self.birthday = birthday
        self.family = family
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        relationship = (try? c.decodeIfPresent(String.self, forKey: .relationship)) ?? ""
        relationshipType = (try? c.decodeIfPresent(String.self, forKey: .relationshipType)) ?? ""
        birthday = (try? c.decodeIfPresent(String.self, forKey: .birthday)) ?? ""
        // One bad row never costs the others.
        family = ((try? c.decodeIfPresent([LossyFact].self, forKey: .family)) ?? []).compactMap(\.fact)
    }

    private struct LossyFact: Decodable {
        let fact: BrainFact?
        init(from decoder: Decoder) throws { fact = try? BrainFact(from: decoder) }
    }
}

/// Some of a person's facts: the ones an edit changes, or the ones a save replaced. Posting what a
/// save replaced back to the same page undoes it. A nil field is left alone; an empty birthday or
/// family value removes that line from the page.
struct BrainPersonFactsChange: Codable, Equatable, Sendable {
    var relationship: String?
    var relationshipType: String?
    var birthday: String?
    var family: [BrainFact]?

    var isEmpty: Bool {
        relationship == nil && relationshipType == nil && birthday == nil && (family ?? []).isEmpty
    }

    private enum CodingKeys: String, CodingKey { case relationship, relationshipType, birthday, family }

    init(relationship: String? = nil, relationshipType: String? = nil, birthday: String? = nil, family: [BrainFact]? = nil) {
        self.relationship = relationship
        self.relationshipType = relationshipType
        self.birthday = birthday
        self.family = family
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        relationship = try? c.decodeIfPresent(String.self, forKey: .relationship)
        relationshipType = try? c.decodeIfPresent(String.self, forKey: .relationshipType)
        birthday = try? c.decodeIfPresent(String.self, forKey: .birthday)
        family = try? c.decodeIfPresent([BrainFact].self, forKey: .family)
    }
}

/// `POST /api/brain/person/facts`: the page's id and the facts to set, flat in one object.
struct BrainPersonFactsRequest: Encodable, Equatable, Sendable {
    /// The contact's page id, "crm/contacts/<Name>.md".
    let id: String
    let change: BrainPersonFactsChange

    private enum CodingKeys: String, CodingKey { case id }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try change.encode(to: encoder)
    }
}

/// The server's answer: `previous` holds the values the save replaced (empty when nothing changed).
struct BrainPersonFactsResult: Decodable, Equatable, Sendable {
    let previous: BrainPersonFactsChange

    init(previous: BrainPersonFactsChange = BrainPersonFactsChange()) { self.previous = previous }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        previous = (try? c.decodeIfPresent(BrainPersonFactsChange.self, forKey: .previous)) ?? BrainPersonFactsChange()
    }

    private enum CodingKeys: String, CodingKey { case previous }
}

/// The edit sheet's working copy: what he typed, what is wrong with it, and what differs from the page.
struct BrainPersonFactsDraft: Equatable {
    /// The kinds the vault files a person under, in the order the picker lists them.
    static let types = ["partner", "family", "friend", "colleague", "mentor", "network"]
    /// The family lines Atlas reads, in the order the sheet lists them.
    static let familyLabels = ["Partner", "Children", "Parents", "Mother", "Father", "Siblings"]

    var relationship: String
    var relationshipType: String
    var birthday: String
    /// Names by family label; a label with no line on the page is empty.
    var family: [String: String]
    private let original: BrainPersonFacts

    init(_ facts: BrainPersonFacts) {
        original = facts
        relationship = facts.relationship
        relationshipType = facts.relationshipType
        birthday = facts.birthday
        family = Dictionary(facts.family.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// What is wrong with the relationship; nil when it can be saved. The page can't lose a relationship it has.
    var relationshipProblem: String? {
        Self.tidy(relationship).isEmpty && !original.relationship.isEmpty
            ? "Say how they relate to you, like Friend (met at school)." : nil
    }

    /// What is wrong with the birthday; nil when it is empty or a real date.
    var birthdayProblem: String? {
        let text = Self.tidy(birthday)
        return text.isEmpty || Self.isBirthday(text) ? nil : "Use 1990-05-02, or 05-02 when you don't know the year."
    }

    /// The facts that differ from the page, tidied; a cleared birthday or family line is sent empty.
    var change: BrainPersonFactsChange {
        var change = BrainPersonFactsChange()
        let relationship = Self.tidy(relationship)
        if !relationship.isEmpty, relationship != original.relationship { change.relationship = relationship }
        if Self.types.contains(relationshipType), relationshipType != original.relationshipType {
            change.relationshipType = relationshipType
        }
        let birthday = Self.tidy(birthday)
        if birthday != original.birthday { change.birthday = birthday }
        let before = Dictionary(original.family.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        let lines = Self.familyLabels.compactMap { label -> BrainFact? in
            let names = Self.tidy(family[label] ?? "")
            return names == (before[label] ?? "") ? nil : BrainFact(label: label, value: names)
        }
        if !lines.isEmpty { change.family = lines }
        return change
    }

    var canSave: Bool { relationshipProblem == nil && birthdayProblem == nil && !change.isEmpty }

    /// Trimmed, with runs of whitespace as one space, as the vault stores a fact.
    static func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "YYYY-MM-DD" or "MM-DD" naming a real day (Feb 29 allowed when the year is unknown).
    static func isBirthday(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              parts.suffix(2).allSatisfy({ $0.count == 2 }),
              parts.count == 2 || parts[0].count == 4
        else { return false }
        let numbers = parts.compactMap { Int($0) }
        let components = DateComponents(calendar: Calendar(identifier: .gregorian),
                                        year: parts.count == 3 ? numbers[0] : 2000,
                                        month: numbers[numbers.count - 2], day: numbers[numbers.count - 1])
        return components.isValidDate
    }
}

/// "Edit facts": how a person relates to him, their birthday and their family, written to their
/// page through the vault's `crm set`. Atlas reads these whenever it writes about them, so a wrong
/// one is fixed here once. A failed save keeps the sheet open with his edits and the reason.
struct BrainPersonFactsSheet: View {
    let name: String
    let save: (BrainPersonFactsChange) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BrainPersonFactsDraft
    @State private var isSaving = false
    @State private var failure: String?
    /// The page's kind when it isn't one of the six (none yet, or an old spelling): the picker's
    /// "Not set" row. nil when the page has one, so it can't be unset.
    private let unsetType: String?

    init(name: String, facts: BrainPersonFacts, save: @escaping (BrainPersonFactsChange) async throws -> Void) {
        self.name = name
        self.save = save
        _draft = State(initialValue: BrainPersonFactsDraft(facts))
        unsetType = BrainPersonFactsDraft.types.contains(facts.relationshipType) ? nil : facts.relationshipType
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(text: $draft.relationship) { Text(verbatim: "Friend (met at school)") }
                        .accessibilityLabel(Text(verbatim: "Relationship"))
                    Picker(selection: $draft.relationshipType) {
                        if let unsetType { Text(verbatim: "Not set").tag(unsetType) }
                        ForEach(BrainPersonFactsDraft.types, id: \.self) { type in
                            Text(verbatim: type.capitalized).tag(type)
                        }
                    } label: { Text(verbatim: "Kind") }
                } header: {
                    Text(verbatim: "Relationship")
                } footer: {
                    problem(draft.relationshipProblem) ?? Text(verbatim: "Atlas calls \(firstName) only what this says.")
                }
                Section {
                    TextField(text: $draft.birthday) { Text(verbatim: "1990-05-02") }
                        .keyboardType(.numbersAndPunctuation)
                        .accessibilityLabel(Text(verbatim: "Birthday"))
                } header: {
                    Text(verbatim: "Birthday")
                } footer: {
                    problem(draft.birthdayProblem) ?? Text(verbatim: "Year first, or 05-02 when you don't know the year.")
                }
                Section {
                    ForEach(BrainPersonFactsDraft.familyLabels, id: \.self) { label in
                        LabeledContent {
                            TextField(text: familyBinding(label)) { Text(verbatim: "Names") }
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.words)
                        } label: { Text(verbatim: label) }
                    }
                } header: {
                    Text(verbatim: "Family")
                } footer: {
                    Text(verbatim: "Full names, with commas between. Clear a line to remove it.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(Text(verbatim: "Edit facts"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Cancel") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button { Task { await submit() } } label: { Text(verbatim: "Save").bold() }
                            .disabled(!draft.canSave)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let failure {
                    Label { Text(verbatim: failure) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxDanger)
                        .padding(BrainStyle.s)
                }
            }
            .hxKeyboardDoneButton()
        }
        .interactiveDismissDisabled(isSaving || !draft.change.isEmpty)
    }

    private var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }

    private func problem(_ text: String?) -> Text? {
        text.map { Text(verbatim: $0).foregroundStyle(Color.hxDanger) }
    }

    private func familyBinding(_ label: String) -> Binding<String> {
        Binding(get: { draft.family[label] ?? "" }, set: { draft.family[label] = $0 })
    }

    private func submit() async {
        isSaving = true
        failure = nil
        do {
            try await save(draft.change)
            dismiss()
        } catch {
            failure = "Couldn't save: \(error.localizedDescription)"
        }
        isSaving = false
    }
}

/// "Edit facts" under a person's header: a Nous-blue link, since it is a control.
struct BrainPersonEditFactsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label { Text(verbatim: "Edit facts") } icon: { Image(systemName: "pencil") }
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(minHeight: BrainStyle.minTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(verbatim: "Relationship, birthday and family, as Atlas reads them"))
    }
}

/// What follows a facts save, over the foot of the person page: "Facts saved · Undo" until he
/// leaves or dismisses it. Undo puts back exactly what the save replaced; if that fails the offer
/// stays, with the reason, so he can try again.
struct BrainPersonFactsUndoBar: View {
    let isWorking: Bool
    let failure: String?
    let undo: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: BrainStyle.s) {
            Text(verbatim: failure.map { "Couldn't undo: \($0)" } ?? "Facts saved")
                .brainText(.meta)
                .foregroundStyle(failure == nil ? Color.hxTextSecondary : Color.hxDanger)
                .lineLimit(2)
            Spacer(minLength: BrainStyle.s)
            if isWorking {
                ProgressView()
            } else {
                Button(action: undo) {
                    Text(verbatim: failure == nil ? "Undo" : "Try again")
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(minWidth: BrainStyle.minTapTarget, minHeight: BrainStyle.minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(verbatim: "Puts back the facts as they were"))
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(AppFont.footnote(weight: .semibold))
                        .foregroundStyle(Color.hxTextSecondary)
                        .frame(minWidth: BrainStyle.minTapTarget, minHeight: BrainStyle.minTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "Dismiss"))
            }
        }
        .padding(.leading, BrainStyle.cardHorizontalPadding)
        .padding(.trailing, BrainStyle.xs)
        .brainCardSurface()
        .hxShadow(.float)
    }
}
