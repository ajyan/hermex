import Foundation

/// Turns a streaming reply into speakable sentences. Feed it the full text so
/// far; it returns each newly complete sentence once.
///
/// Everything before a `---` line or fenced code is spoken as it streams: on a
/// call, those mark the details Atlas put in the chat instead. Paragraphs count
/// too, since the text Atlas writes around a tool call arrives as its own
/// paragraph.
struct SpeechTextShaper {
    private var emitted: [String] = []
    private var lastText = ""

    /// `final` is true once the run has ended: a trailing fragment is then a
    /// sentence. Text that grows after the run ended (the transcript refresh
    /// delivering the whole message) still yields its new words.
    mutating func append(_ cumulativeText: String, final: Bool = false) -> [String] {
        lastText = cumulativeText
        return emit(Self.sentences(in: cumulativeText, final: final))
    }

    mutating func finish() -> [String] {
        emit(Self.sentences(in: lastText, final: true))
    }

    /// Emits what hasn't been emitted. A sentence emitted as a cut-off fragment
    /// that later grows yields only its new tail.
    private mutating func emit(_ sentences: [String]) -> [String] {
        var fresh: [String] = []
        for (index, sentence) in sentences.enumerated() {
            if index >= emitted.count {
                emitted.append(sentence)
                fresh.append(sentence)
            } else if sentence != emitted[index], sentence.hasPrefix(emitted[index]) {
                let tail = sentence.dropFirst(emitted[index].count).trimmingCharacters(in: .whitespaces)
                emitted[index] = sentence
                if !tail.isEmpty { fresh.append(tail) }
            }
        }
        return fresh
    }

    // MARK: - Parsing

    private struct Block {
        var text: String
        var closed: Bool
    }

    static func sentences(in rawText: String, final: Bool) -> [String] {
        // Atlas sometimes echoes the call's "[voice 2:41 PM]" tag (or the legacy "[voice]"),
        // with its cut-in note, or a bare "voice"; never say it.
        var text = Substring(rawText.drop(while: \.isWhitespace))
        let lowered = text.lowercased()
        if !final, VoiceCallPhrases.isPartialVoiceTag(text) {
            return []
        } else if let tag = VoiceCallPhrases.voiceTagLength(in: text, ignoringCase: true) {
            text = text.dropFirst(tag)
            if text.first == ":" { text = text.dropFirst() }
        } else if lowered.hasPrefix("voice") {
            let rest = text.dropFirst("voice".count)
            if !final, rest.allSatisfy(\.isWhitespace) { return [] }
            if rest.first == ":" {
                text = rest.dropFirst()
            } else if rest.first?.isWhitespace == true, rest.drop(while: \.isWhitespace).first?.isUppercase == true,
                      text.first?.isLowercase == true {
                text = rest
            }
        }
        return sentences(inUntagged: String(text), final: final)
    }

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
                    // Code in the lead paragraph means the rest is details too.
                    if sawDetailsMarker {
                        stopped = true
                        break
                    }
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

        let lastOpen = final || stopped ? paragraphs.count : paragraphs.count - 1
        for paragraph in paragraphs.indices.prefix(lastOpen) {
            for index in paragraphs[paragraph].indices { paragraphs[paragraph][index].closed = true }
        }
        return paragraphs.flatMap { $0.flatMap(split) }
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
