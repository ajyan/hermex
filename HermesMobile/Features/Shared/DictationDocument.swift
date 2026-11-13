import Foundation

/// A text box while the mic listens: where the live words are being written, and where each finished
/// passage of speech sits, kept right through keyboard edits. Offsets count characters.
///
/// Speech lands at the cursor the mic started on. A keyboard edit inside the dictated stretch (fixing
/// a misheard word) leaves speech going on at the stretch's end; an edit or cursor move outside it
/// moves speech to the cursor.
struct DictationDocument: Equatable {
    /// One finished passage of speech and where it sits now.
    struct Piece: Equatable, Identifiable {
        let id: Int
        var range: Range<Int>
    }

    /// One change dictation made to the text, for carrying the cursor across it.
    struct Edit: Equatable {
        let at: Int
        let removed: Int
        let inserted: Int

        /// The one stretch that differs between two texts.
        static func between(_ old: String, _ new: String) -> Edit {
            let old = Array(old), new = Array(new)
            var prefix = 0
            while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < min(old.count, new.count) - prefix,
                  old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
            return Edit(at: prefix, removed: old.count - prefix - suffix, inserted: new.count - prefix - suffix)
        }

        /// Where a cursor at `cursor` sits after this edit: one at or past the changed words moves with them.
        func moved(_ cursor: Int) -> Int {
            if cursor < at { return cursor }
            if cursor >= at + removed { return cursor + inserted - removed }
            return at + inserted
        }
    }

    private(set) var text: String
    private(set) var pieces: [Piece] = []
    /// The live words as written, joining spaces included.
    private(set) var open: Range<Int>
    /// Where this stretch of speech began; it runs to the end of `open`.
    private(set) var stretchStart: Int
    /// The live words without their joining spaces, and how many of their characters are settled.
    private var words: Range<Int>
    private var settledLength = 0
    private var nextID = 0

    /// `cursor` is where speech goes; nil or out of range is the end of the text.
    init(text: String, cursor: Int? = nil) {
        self.text = text
        let at = cursor.map { min(max($0, 0), text.count) } ?? text.count
        open = at..<at
        words = at..<at
        stretchStart = at
    }

    /// Whether the live words hold anything yet.
    var hasLiveWords: Bool { !words.isEmpty }

    /// Where typing goes on from: the end of the live words, before any space that parts them from
    /// the text after.
    var caret: Int { words.upperBound }

    /// The live words as they stand in the text.
    var liveWords: String { slice(words) }

    /// Writes the live words: `settled` are final, `volatile` may still change.
    @discardableResult
    mutating func hear(settled: String, volatile: String) -> Edit? {
        let settled = settled.trimmingCharacters(in: .whitespacesAndNewlines)
        let volatile = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = settled.isEmpty || volatile.isEmpty ? settled + volatile : settled + " " + volatile
        let lead = !heard.isEmpty && needsSpace(before: open.lowerBound) ? " " : ""
        // With no live words, a space still parts the passage before from the text after.
        let joins = !heard.isEmpty || open.lowerBound > stretchStart
        let trail = joins && needsSpace(after: open.upperBound) ? " " : ""
        let written = lead + heard + trail
        guard written != slice(open) || settled.count != settledLength else { return nil }
        let edit = Edit(at: open.lowerBound, removed: open.count, inserted: written.count)
        let delta = written.count - open.count
        let end = open.upperBound
        replace(open, with: written)
        pieces = pieces.map {
            $0.range.lowerBound >= end
                ? Piece(id: $0.id, range: ($0.range.lowerBound + delta)..<($0.range.upperBound + delta)) : $0
        }
        open = edit.at..<(edit.at + written.count)
        words = (edit.at + lead.count)..<(edit.at + lead.count + heard.count)
        settledLength = settled.count
        return edit
    }

    /// Closes the settled words as a finished passage; the words still changing stay live after it.
    mutating func cut() -> Piece? {
        guard settledLength > 0 else { return nil }
        let piece = Piece(id: nextID, range: words.lowerBound..<(words.lowerBound + settledLength))
        nextID += 1
        pieces.append(piece)
        open = piece.range.upperBound..<open.upperBound
        // The space after the settled words now belongs to the live words' lead.
        let rest = slice(open)
        let lead = rest.prefix(while: \.isWhitespace).count
        let trail = rest.count > lead ? rest.reversed().prefix(while: \.isWhitespace).count : 0
        words = (open.lowerBound + lead)..<(open.upperBound - trail)
        settledLength = 0
        return piece
    }

    /// Closes every live word as a finished passage, settled or not.
    mutating func seal() -> Piece? {
        settledLength = words.count
        let piece = cut()
        open = open.upperBound..<open.upperBound
        words = open
        return piece
    }

    /// What a keyboard edit did to the live words.
    enum Adoption: Equatable {
        case unchanged
        /// The edit changed the live words: they were closed as this passage, and speech goes on after it.
        case sealed(Piece)
    }

    /// Takes a keyboard edit: `newText` is the box now. Returns where the edit ended (the cursor, when
    /// the field can't say) and what happened to the live words.
    @discardableResult
    mutating func adopt(_ newText: String) -> (editEnd: Int, live: Adoption) {
        let edit = Edit.between(text, newText)
        let changed = edit.at..<(edit.at + edit.removed)
        let delta = edit.inserted - edit.removed
        let editEnd = edit.at + edit.inserted
        text = newText

        func shifted(_ range: Range<Int>) -> Range<Int> {
            if range.upperBound <= changed.lowerBound, !(range.isEmpty && changed.isEmpty) { return range }
            if range.lowerBound >= changed.upperBound {
                return (range.lowerBound + delta)..<(range.upperBound + delta)
            }
            return min(range.lowerBound, changed.lowerBound)..<(max(range.upperBound, changed.upperBound) + delta)
        }
        func touches(_ range: Range<Int>) -> Bool {
            range.lowerBound < changed.upperBound && range.upperBound > changed.lowerBound
                || (changed.isEmpty && range.lowerBound < changed.lowerBound && changed.lowerBound < range.upperBound)
        }

        // Typing right after the live words: the space that parted them from the rest is his text now.
        if !words.isEmpty, changed.lowerBound >= words.upperBound, changed.lowerBound <= open.upperBound {
            open = open.lowerBound..<words.upperBound
        }
        pieces = pieces.map { Piece(id: $0.id, range: shifted($0.range)) }
        if stretchStart > changed.lowerBound || (stretchStart == changed.lowerBound && changed.isEmpty && open.isEmpty) {
            stretchStart = max(changed.lowerBound, stretchStart + delta)
        }
        guard !words.isEmpty, touches(words) else {
            open = shifted(open)
            words = shifted(words)
            return (editEnd, .unchanged)
        }
        // The keyboard changed the live words: they are his now. Close them, and go on after them.
        let piece = Piece(id: nextID, range: shifted(words))
        nextID += 1
        pieces.append(piece)
        open = piece.range.upperBound..<piece.range.upperBound
        words = open
        settledLength = 0
        return (editEnd, .sealed(piece))
    }

    /// Whether `cursor` is in the stretch being dictated, where speech stays put.
    func isInStretch(_ cursor: Int) -> Bool {
        cursor >= stretchStart && cursor <= open.upperBound
    }

    /// Moves speech to `cursor`, closing the live words as a finished passage (returned) first.
    @discardableResult
    mutating func move(to cursor: Int) -> Piece? {
        let piece = seal()
        let at = min(max(cursor, 0), text.count)
        open = at..<at
        words = open
        stretchStart = at
        return piece
    }

    /// The words of one passage as they stand now.
    func text(of id: Int) -> String? {
        pieces.first { $0.id == id }.map { slice($0.range) }
    }

    /// Up to `limit` characters of the text before a passage, for the rewriter's context.
    func context(before id: Int, limit: Int = 600) -> String {
        guard let piece = pieces.first(where: { $0.id == id }) else { return "" }
        return slice(max(0, piece.range.lowerBound - limit)..<piece.range.lowerBound)
    }

    /// Swaps a passage for its rewrite, if it still reads `expected`.
    @discardableResult
    mutating func rewrite(_ id: Int, expecting expected: String, with rewrite: String) -> Bool {
        guard let index = pieces.firstIndex(where: { $0.id == id }), slice(pieces[index].range) == expected else {
            return false
        }
        let range = pieces[index].range
        let delta = rewrite.count - range.count
        replace(range, with: rewrite)
        pieces[index].range = range.lowerBound..<(range.upperBound + delta)
        func after(_ other: Range<Int>) -> Range<Int> {
            other.lowerBound >= range.upperBound ? (other.lowerBound + delta)..<(other.upperBound + delta) : other
        }
        for other in pieces.indices where other != index { pieces[other].range = after(pieces[other].range) }
        open = after(open)
        words = after(words)
        if stretchStart >= range.upperBound { stretchStart += delta }
        return true
    }

    /// Every finished passage as it stands now, in reading order: what was dictated, after any fixes.
    var dictated: String {
        pieces.sorted { $0.range.lowerBound < $1.range.lowerBound }
            .map { slice($0.range) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func slice(_ range: Range<Int>) -> String {
        let lower = text.index(text.startIndex, offsetBy: min(range.lowerBound, text.count))
        let upper = text.index(text.startIndex, offsetBy: min(range.upperBound, text.count))
        return String(text[lower..<upper])
    }

    private mutating func replace(_ range: Range<Int>, with replacement: String) {
        let lower = text.index(text.startIndex, offsetBy: range.lowerBound)
        let upper = text.index(text.startIndex, offsetBy: range.upperBound)
        text.replaceSubrange(lower..<upper, with: replacement)
    }

    private func needsSpace(before offset: Int) -> Bool {
        guard offset > 0, let character = character(at: offset - 1) else { return false }
        return !character.isWhitespace && !"([{“\"'‘".contains(character)
    }

    private func needsSpace(after offset: Int) -> Bool {
        guard let character = character(at: offset) else { return false }
        return !character.isWhitespace && !character.isPunctuation
    }

    private func character(at offset: Int) -> Character? {
        guard offset >= 0, offset < text.count else { return nil }
        return text[text.index(text.startIndex, offsetBy: offset)]
    }
}
