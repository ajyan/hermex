import Foundation

/// What a fenced `atlas-ui` block in an assistant reply renders as. Atlas writes
/// a small HTML tool into such a block; a settled, complete block becomes an
/// interactive card, a streaming one a "Building…" placeholder, and anything
/// cut off, empty, or oversized stays a plain code block.
enum InteractiveAnswerBlock: Equatable {
    case building(title: String?)
    case card(fragment: String, title: String)
    case code

    static let language = "atlas-ui"
    static let maxFragmentBytes = 200 * 1024
    private static let maxTitleLength = 80

    static func matches(_ language: String?) -> Bool {
        language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.language
    }

    static func classify(language: String?, content: String, isStreaming: Bool) -> InteractiveAnswerBlock {
        if isStreaming { return .building(title: title(in: content)) }
        let fragment = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fragment.isEmpty,
              fragment.utf8.count <= maxFragmentBytes,
              isComplete(fragment)
        else { return .code }
        return .card(fragment: fragment, title: title(in: fragment) ?? String(localized: "Tool"))
    }

    /// The fragment's closed `<title>`, entity-decoded, trimmed, and cut to 80 characters.
    static func title(in fragment: String) -> String? {
        guard let open = fragment.range(of: "<title>", options: .caseInsensitive),
              let close = fragment.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<fragment.endIndex)
        else { return nil }
        let decoded = decodeEntities(String(fragment[open.upperBound..<close.lowerBound]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }
        return String(decoded.prefix(maxTitleLength))
    }

    /// A reply cut off mid-block leaves a `<script>` or `<style>` open; such a
    /// fragment would run half a program, so it stays code.
    private static func isComplete(_ fragment: String) -> Bool {
        let lower = fragment.lowercased()
        return count("<script", in: lower) == count("</script>", in: lower)
            && count("<style", in: lower) == count("</style>", in: lower)
    }

    private static func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
