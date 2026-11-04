import SwiftUI

/// Subtitles for a call, between the status and the call buttons: the user's words while they
/// talk, then the part of Atlas's reply it is saying, each word lit as it's heard. A long
/// sentence shows in pieces of at most `pieceWords` words, so the line never scrolls; the area
/// holds three lines and shrinks large text to fit rather than reach the controls.
struct VoiceCallCaptions: View {
    let sent: String?
    let live: String
    /// Atlas's reply to `sent`, as spoken.
    let reply: String?
    /// The reply as heard so far (`SpeechSpeaking.heardText`).
    let heard: String
    /// True while Atlas's voice is playing the reply.
    let isSpeaking: Bool
    /// True while Atlas is still working on or saying `reply`.
    let isReplying: Bool

    /// Three lines of the caption font.
    @ScaledMetric(relativeTo: .title3) private var height: CGFloat = 78

    static let pieceWords = 12

    struct Line: Equatable {
        var words: [String]
        /// How many of `words`, from the start, have been said.
        var lit: Int
        /// Dimmed once the words are no longer being said.
        var isActive: Bool
    }

    /// What the subtitles show. The user's sent words wait, dimmed, until Atlas's voice starts;
    /// Atlas's last piece stays, dimmed, until the user's next words are recognized.
    static func line(
        sent: String?, live: String, reply: String?, heard: String, isSpeaking: Bool, isReplying: Bool
    ) -> Line? {
        if !live.isEmpty {
            let words = pieces(of: words(in: live)).last ?? []
            return Line(words: words, lit: words.count, isActive: true)
        }
        guard let sent else { return nil }
        let replyPieces = pieces(of: words(in: reply ?? ""))
        if replyPieces.isEmpty || (isReplying && !isSpeaking) {
            let words = pieces(of: words(in: sent)).last ?? []
            return words.isEmpty ? nil : Line(words: words, lit: words.count, isActive: false)
        }
        let total = replyPieces.reduce(0) { $0 + $1.count }
        let heardCount = min(words(in: heard).count, total)
        // The piece holding the next word to be said, or the last once all of it was heard.
        var start = 0
        for (index, piece) in replyPieces.enumerated() {
            if heardCount < start + piece.count || index == replyPieces.count - 1 {
                // The word being said lights with the ones before it.
                let said = isSpeaking ? min(heardCount + 1, total) : heardCount
                return Line(words: piece, lit: min(max(said - start, 0), piece.count), isActive: isSpeaking)
            }
            start += piece.count
        }
        return nil
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// `words` split into even pieces of at most `pieceWords`, never across a sentence end.
    private static func pieces(of words: [String]) -> [[String]] {
        var sentences: [[String]] = [[]]
        for word in words {
            sentences[sentences.count - 1].append(word)
            if let last = word.last, ".!?".contains(last) { sentences.append([]) }
        }
        return sentences.filter { !$0.isEmpty }.flatMap { sentence -> [[String]] in
            let count = (sentence.count + pieceWords - 1) / pieceWords
            let size = (sentence.count + count - 1) / count
            return stride(from: 0, to: sentence.count, by: size).map { Array(sentence[$0..<min($0 + size, sentence.count)]) }
        }
    }

    var body: some View {
        let line = Self.line(sent: sent, live: live, reply: reply, heard: heard, isSpeaking: isSpeaking, isReplying: isReplying)
        Text(line.map(styled) ?? AttributedString(" "))
            .font(AppFont.title3(weight: .semibold))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.7)
            // Pieces swap at once, as subtitles do; a crossfade overlaps two lines.
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
    }

    private func styled(_ line: Line) -> AttributedString {
        var text = AttributedString()
        for (index, word) in line.words.enumerated() {
            var part = AttributedString(index == 0 ? word : " " + word)
            part.foregroundColor = line.isActive && index < line.lit ? Color.hxTextPrimary : Color.hxTextSecondary
            text.append(part)
        }
        return text
    }
}
