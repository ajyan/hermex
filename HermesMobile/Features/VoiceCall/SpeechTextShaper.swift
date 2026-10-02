import Foundation

/// Turns a streaming reply into speakable sentences. Feed it the full text so
/// far; it returns each newly complete sentence once.
///
/// The first paragraph is spoken as it streams. Later paragraphs are held until
/// `finish()` and spoken only when the reply has no fenced code and no `---`
/// line: on a call, those mark the details Atlas put in the chat instead.
struct SpeechTextShaper {
    private var emitted = 0
    private var lastText = ""

    mutating func append(_ cumulativeText: String) -> [String] {
        lastText = cumulativeText
        return emit(Self.sentences(in: cumulativeText, final: false))
    }

    mutating func finish() -> [String] {
        emit(Self.sentences(in: lastText, final: true))
    }

    private mutating func emit(_ sentences: [String]) -> [String] {
        guard sentences.count > emitted else { return [] }
        let fresh = Array(sentences[emitted...])
        emitted = sentences.count
        return fresh
    }

    // MARK: - Parsing

    private struct Block {
        var text: String
        var closed: Bool
    }

    static func sentences(in rawText: String, final: Bool) -> [String] {
        // Atlas sometimes echoes the call's "[voice]" tag; never say it.
        var text = Substring(rawText.drop(while: \.isWhitespace))
        if text.hasPrefix(echoedTag) {
            text = text.dropFirst(echoedTag.count)
        } else if !final, echoedTag.hasPrefix(text) {
            return []
        }
        return sentences(inUntagged: String(text), final: final)
    }

    private static let echoedTag = "[voice]"

    private static func sentences(inUntagged text: String, final: Bool) -> [String] {
        var paragraphs: [[Block]] = [[]]
        var inFence = false
        var sawDetailsMarker = false
        var stopped = false
        var lines = text.components(separatedBy: "\n")
        let lastLineTerminated = text.hasSuffix("\n")
        if lastLineTerminated { lines.removeLast() }

        func closeOpenBlock() {
            if let last = paragraphs[paragraphs.count - 1].indices.last {
                paragraphs[paragraphs.count - 1][last].closed = true
            }
        }

        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let isLastLine = index == lines.count - 1
            let lineComplete = final || !isLastLine || lastLineTerminated

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                sawDetailsMarker = true
                closeOpenBlock()
                if paragraphs.count > 1 {
                    stopped = true
                    break
                }
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if isRule(trimmed) {
                sawDetailsMarker = true
                closeOpenBlock()
                stopped = true
                break
            }
            if trimmed.isEmpty {
                if !paragraphs[paragraphs.count - 1].isEmpty {
                    closeOpenBlock()
                    paragraphs.append([])
                }
                continue
            }

            let (content, forced) = stripLine(trimmed)
            if content.isEmpty { continue }
            var current = paragraphs[paragraphs.count - 1]
            if forced {
                if let last = current.indices.last { current[last].closed = true }
                current.append(Block(text: content, closed: lineComplete))
            } else if let last = current.indices.last, !current[last].closed {
                current[last].text += " " + content
            } else {
                current.append(Block(text: content, closed: false))
            }
            // A streamed line ending in a space has finished its last sentence.
            if isLastLine, !lineComplete, rawLine.last?.isWhitespace == true, let last = current.indices.last {
                current[last].text += " "
            }
            paragraphs[paragraphs.count - 1] = current
        }

        if final || paragraphs.count > 1 || stopped {
            for index in paragraphs[0].indices { paragraphs[0][index].closed = true }
        }
        var result = paragraphs[0].flatMap(split)
        if final, !sawDetailsMarker {
            for paragraph in paragraphs.dropFirst() {
                result += paragraph.map { Block(text: $0.text, closed: true) }.flatMap(split)
            }
        }
        return result
    }

    private static func isRule(_ line: String) -> Bool {
        guard line.count >= 3, let first = line.first, "-*_".contains(first) else { return false }
        return line.allSatisfy { $0 == first }
    }

    /// Strips markdown from one line. `forced` marks headings and list items,
    /// which are spoken as their own sentence.
    private static func stripLine(_ line: String) -> (String, Bool) {
        var text = line
        var forced = false
        for prefix in [headingPrefix, listPrefix] where text.firstMatch(of: prefix) != nil {
            text = text.replacing(prefix, maxReplacements: 1) { _ in "" }
            forced = true
        }
        text = text.replacing(quotePrefix, maxReplacements: 1) { _ in "" }
        text = text.replacing(image) { String($0.output.1) }
        text = text.replacing(link) { String($0.output.1) }
        text = text.replacing(bareURL) { _ in "link" }
        text = text.replacing(emphasis) { _ in "" }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (collapsed, forced)
    }

    nonisolated(unsafe) private static let headingPrefix = #/^#{1,6}\s+/#
    nonisolated(unsafe) private static let listPrefix = #/^(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/#
    nonisolated(unsafe) private static let quotePrefix = #/^>\s?/#
    nonisolated(unsafe) private static let image = #/!\[([^\]]*)\]\([^)]*\)/#
    nonisolated(unsafe) private static let link = #/\[([^\]]+)\]\([^)]*\)/#
    nonisolated(unsafe) private static let bareURL = #/https?:\/\/[^\s)\]]*[^\s.,;:!?)\]]/#
    nonisolated(unsafe) private static let emphasis = #/\*\*|__|~~|\*|`/#

    private static let abbreviations: Set<String> = ["e.g.", "i.e.", "mr.", "mrs.", "ms.", "dr.", "vs.", "st."]
    private static let closers: Set<Character> = ["\"", "'", ")", "”", "’"]

    /// Splits a block into sentences. An open block keeps its trailing fragment back.
    private static func split(_ block: Block) -> [String] {
        let chars = Array(block.text)
        var sentences: [String] = []
        var start = 0
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "." || char == "?" || char == "!" || char == "…" {
                var end = index + 1
                while end < chars.count, closers.contains(chars[end]) { end += 1 }
                let atBoundary = end < chars.count && chars[end].isWhitespace
                if atBoundary, !(char == "." && isAbbreviation(chars, endingAt: index)) {
                    appendSentence(chars[start..<end], to: &sentences)
                    start = end
                }
                index = end
                continue
            }
            index += 1
        }
        if block.closed {
            appendSentence(chars[start..<chars.count], to: &sentences)
        }
        return sentences
    }

    private static func isAbbreviation(_ chars: [Character], endingAt dot: Int) -> Bool {
        var wordStart = dot
        while wordStart > 0, !chars[wordStart - 1].isWhitespace { wordStart -= 1 }
        return abbreviations.contains(String(chars[wordStart...dot]).lowercased())
    }

    private static func appendSentence(_ slice: ArraySlice<Character>, to sentences: inout [String]) {
        let sentence = String(slice).trimmingCharacters(in: .whitespaces)
        if !sentence.isEmpty { sentences.append(sentence) }
    }
}
