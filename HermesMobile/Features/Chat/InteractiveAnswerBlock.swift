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

    /// `isEnabled` is false on surfaces with no composer for "Ask Atlas" (Skills,
    /// file previews, Brain), which show the block as code. `isFenceClosed` is
    /// false when the reply ended inside this block (`unclosedFenceBody`).
    static func classify(
        language: String?,
        content: String,
        isStreaming: Bool,
        isEnabled: Bool = true,
        isFenceClosed: Bool = true
    ) -> InteractiveAnswerBlock {
        guard isEnabled else { return .code }
        if isStreaming { return .building(title: title(in: content)) }
        let fragment = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFenceClosed,
              !fragment.isEmpty,
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

    /// The body of a fenced block the markdown opens but never closes, trimmed,
    /// or nil. A reply cancelled mid-block ends this way; CommonMark closes the
    /// fence at the end, so the block alone cannot tell.
    static func unclosedFenceBody(in markdown: String) -> String? {
        var open: (marker: Character, length: Int, bodyStart: Int)?
        var lines: [Substring] = []
        markdown.split(separator: "\n", omittingEmptySubsequences: false).forEach { lines.append($0) }
        for (index, line) in lines.enumerated() {
            let trimmed = line.drop { $0 == " " }
            guard let first = trimmed.first, first == "`" || first == "~" else { continue }
            let run = trimmed.prefix { $0 == first }.count
            guard run >= 3 else { continue }
            if let current = open {
                if first == current.marker, run >= current.length,
                   trimmed.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    open = nil
                }
            } else {
                open = (first, run, index + 1)
            }
        }
        guard let open else { return nil }
        return lines[open.bodyStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
