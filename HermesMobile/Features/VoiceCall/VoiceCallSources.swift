import Foundation

/// The kind of memory a call drew on. It picks the memory's paper (the Brain's paper for that
/// kind of page) and its chip symbol. Raw values are the `context_sources` event's `kind`.
enum VoiceCallSourceKind: String, Equatable, CaseIterable {
    case journal, wiki, person, note, article, book

    var paper: HermexPaper {
        switch self {
        case .journal: BrainModuleID.journal.paper
        case .wiki: BrainModuleID.wiki.paper
        case .person: BrainModuleID.people.paper
        case .article: BrainModuleID.articles.paper
        case .book: BrainModuleID.highlights.paper
        case .note: .file
        }
    }

    var symbol: String {
        switch self {
        case .journal: BrainModuleID.journal.symbolName
        case .wiki: BrainModuleID.wiki.symbolName
        case .person: "person"
        case .article: BrainModuleID.articles.symbolName
        case .book: BrainModuleID.highlights.symbolName
        case .note: "doc.text"
        }
    }
}

/// One memory Atlas used for the current turn: a note it read or a person it looked up.
/// `id` dedupes it (the vault-relative path, or `person:<name>`).
struct VoiceCallSource: Identifiable, Equatable {
    let id: String
    let label: String
    let kind: VoiceCallSourceKind
    var path: String?
}

/// Builds a turn's memories from the server's `context_sources` event and from the results of
/// Atlas's tool calls (a `brain ask --json` answer's citations, a `crm show`, a file read or
/// search). Tolerant by design: anything it can't read yields no memory, never an error.
enum VoiceCallSources {
    /// The most memories one turn shows; the first ones found win.
    static let cap = 6

    /// The server's own list, labels used as written.
    static func from(context: [ContextSourcesStreamEvent.Source]) -> [VoiceCallSource] {
        context.compactMap { item in
            let label = item.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let path = item.path.flatMap { $0.isEmpty ? nil : $0 }
            let kind = item.kind.flatMap { VoiceCallSourceKind(rawValue: $0.lowercased()) } ?? .note
            if let path {
                let parsed = source(path: path)
                return VoiceCallSource(
                    id: parsed?.id ?? path,
                    label: label.isEmpty ? (parsed?.label ?? path) : label,
                    kind: kind,
                    path: path
                )
            }
            guard !label.isEmpty else { return nil }
            return kind == .person ? person(named: label) : VoiceCallSource(id: "label:\(label)", label: label, kind: kind)
        }
    }

    /// Memories from finished, successful tool calls, in call order.
    static func from(toolCalls: [ToolCall]) -> [VoiceCallSource] {
        toolCalls.filter { $0.isCompleted && $0.isError != true }.flatMap(from(toolCall:))
    }

    static func from(toolCall call: ToolCall) -> [VoiceCallSource] {
        let kind = ToolCallSummaryFormatter.kind(forToolNamed: call.name)
        switch kind {
        case .shell:
            guard let command = VoiceCallToolActivity.shellCommand(in: call.args) else { return [] }
            if let name = VoiceCallToolActivity.personLookedUp(in: command) {
                return [person(named: name)]
            }
            guard command.contains(/(^|[\s;&|(\/])brain\s/) else { return [] }
            return paths(inResult: call.preview ?? "").compactMap(source(path:))
        case .read:
            for key in ["path", "file_path", "file"] {
                if case .string(let path)? = call.args?[key], let source = source(path: path) { return [source] }
            }
            return []
        case .search:
            return paths(inResult: call.preview ?? "").compactMap(source(path:))
        default:
            return []
        }
    }

    /// `first` then `rest`, each memory once (by id or label), at most `cap`.
    static func merged(_ first: [VoiceCallSource], _ rest: [VoiceCallSource]) -> [VoiceCallSource] {
        var ids = Set<String>(), labels = Set<String>(), out: [VoiceCallSource] = []
        for source in first + rest where out.count < cap {
            guard ids.insert(source.id).inserted, labels.insert(source.label).inserted else { continue }
            out.append(source)
        }
        return out
    }

    // MARK: - Paths and labels

    /// Vault folders a path is labeled by. A path is keyed from its first one, so an absolute
    /// and a vault-relative path to the same note dedupe.
    private static let roots = ["journal/", "wiki/", "crm/contacts/", "email_ingest/", "book_highlights/"]

    /// A memory for a note's path, or nil for something that isn't a note (code, folders).
    static func source(path rawPath: String) -> VoiceCallSource? {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = path.lowercased()
        guard [".md", ".markdown", ".txt"].contains(where: lower.hasSuffix) else { return nil }
        let key = roots.lazy.compactMap { root in
            path.range(of: "(^|/)\(root)", options: .regularExpression).map { range in
                String(path[range.lowerBound...]).trimmingPrefix("/")
            }
        }.first.map(String.init) ?? path
        let name = fileTitle(path)

        if key.hasPrefix("journal/") {
            return VoiceCallSource(id: key, label: journalLabel(name), kind: .journal, path: path)
        }
        if key.hasPrefix("wiki/") {
            return VoiceCallSource(id: key, label: "Wiki · \(sentenceCase(name))", kind: .wiki, path: path)
        }
        if key.hasPrefix("crm/contacts/") {
            var source = person(named: personName(name))
            source.path = path
            return source
        }
        if key.hasPrefix("email_ingest/") {
            let title = name.replacing(/^\d{4}-\d{2}-\d{2}[-_ ]*/, with: "")
            return VoiceCallSource(id: key, label: "Article · \(sentenceCase(title))", kind: .article, path: path)
        }
        if key.hasPrefix("book_highlights/") {
            return VoiceCallSource(id: key, label: "Book highlights", kind: .book, path: path)
        }
        return VoiceCallSource(id: key, label: "Notes · \(name)", kind: .note, path: path)
    }

    static func person(named name: String) -> VoiceCallSource {
        VoiceCallSource(id: "person:\(name.lowercased())", label: name, kind: .person)
    }

    /// Note paths in a tool's result: `path`/`file` fields and `files` lists in JSON (a terminal
    /// result's `output` is read as JSON too), else the same fields found by pattern when the
    /// result was cut short, plus `brain ask`'s plain citation lines (`journal/….md#Section`).
    static func paths(inResult text: String) -> [String] {
        var found: [String] = []
        if let value = decodeJSON(text) {
            collect(value, into: &found)
        } else {
            let unescaped = text.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\/", with: "/")
            for match in unescaped.matches(of: /"(?:path|file|file_path)"\s*:\s*"([^"]+)"/) {
                found.append(String(match.output.1))
            }
            for match in unescaped.replacingOccurrences(of: "\\n", with: "\n").matches(of: /(?m)^\s*([^\s"#]+\.md)#/) {
                found.append(String(match.output.1))
            }
        }
        return found
    }

    private static func decodeJSON(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func collect(_ value: JSONValue, into found: inout [String]) {
        switch value {
        case .object(let object):
            for key in object.keys.sorted(by: fieldOrder) {
                guard let field = object[key] else { continue }
                switch (key, field) {
                case ("path", .string(let path)), ("file", .string(let path)), ("file_path", .string(let path)):
                    found.append(path)
                case ("files", .array(let files)):
                    for case .string(let path) in files { found.append(path) }
                case ("output", .string(let output)):
                    if let inner = decodeJSON(output) {
                        collect(inner, into: &found)
                    } else {
                        found.append(contentsOf: paths(inResult: output))
                    }
                default:
                    collect(field, into: &found)
                }
            }
        case .array(let items):
            for item in items { collect(item, into: &found) }
        case .string, .number, .bool, .null:
            break
        }
    }

    /// Object keys in a stable order, the fields that name paths first, so results keep the
    /// tool's own order whatever the dictionary's.
    private static func fieldOrder(_ lhs: String, _ rhs: String) -> Bool {
        let first = ["path", "file", "file_path", "files", "output", "data", "citations", "matches"]
        let l = first.firstIndex(of: lhs) ?? first.count, r = first.firstIndex(of: rhs) ?? first.count
        return l == r ? lhs < rhs : l < r
    }

    /// The file's name without its folder or extension.
    private static func fileTitle(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return name }
        return String(name[..<dot])
    }

    private static let journalDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let journalDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    /// "Journal · 22 Oct" for `2026-10-22`, else "Journal".
    private static func journalLabel(_ name: String) -> String {
        guard let match = name.firstMatch(of: /\d{4}-\d{2}-\d{2}/),
              let date = journalDate.date(from: String(match.output)) else { return "Journal" }
        return "Journal · \(journalDay.string(from: date))"
    }

    /// "Taper plan" from `taper-plan`: separators become spaces and only the first letter is
    /// raised, so acronyms in a typed title keep their case.
    private static func sentenceCase(_ name: String) -> String {
        let words = name.split { $0 == "-" || $0 == "_" || $0 == " " }.joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A contact file's name as a person's name: a slug reads as words in title case.
    private static func personName(_ name: String) -> String {
        guard name == name.lowercased() else { return name.replacingOccurrences(of: "_", with: " ") }
        return name.split { $0 == "-" || $0 == "_" || $0 == " " }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
