import SwiftUI

/// Mandarin with its pinyin set over each character, so he can read a long line aloud. `ruby` comes
/// from the vault, one syllable per character ("" for punctuation and Latin); without it, or when it
/// doesn't line up, the text shows plain. `emphasis` spans (an upgrade's words) are semibold in the
/// paper's glow. VoiceOver reads the characters once, not the pinyin.
struct MandarinRubyText: View {
    let text: String
    let ruby: [String]?
    var emphasis: [String] = []
    var font: Font = AppFont.body()
    var pinyinFont: Font = AppFont.caption2(weight: .medium)
    let ink: Color

    var body: some View {
        Group {
            if let tokens = Self.tokens(text, ruby: ruby, emphasis: emphasis) {
                MandarinRubyLayout(lineSpacing: 6) {
                    ForEach(tokens) { token in
                        VStack(spacing: 0) {
                            Text(verbatim: token.pinyin.isEmpty ? " " : token.pinyin)
                                .font(pinyinFont)
                                .foregroundStyle(ink)
                            Text(verbatim: token.text)
                                .font(font)
                                .fontWeight(token.emphasized ? .semibold : nil)
                                .foregroundStyle(token.emphasized ? ink : Color.hxTextPrimary)
                        }
                        .fixedSize()
                    }
                }
            } else {
                Text(verbatim: text).font(font).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }

    struct Token: Identifiable, Equatable {
        let id: Int
        let text: String
        let pinyin: String
        let emphasized: Bool
    }

    /// One token per Chinese character with its syllable; a run of anything else (Latin, digits,
    /// punctuation) stays one token so a word never breaks. Nil when `ruby` doesn't line up.
    static func tokens(_ text: String, ruby: [String]?, emphasis: [String]) -> [Token]? {
        let chars = Array(text)
        guard let ruby, ruby.count == chars.count, !chars.isEmpty else { return nil }
        var marked = Array(repeating: false, count: chars.count)
        for span in emphasis where !span.isEmpty {
            if let range = text.range(of: span) {
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                for i in start..<min(start + span.count, chars.count) { marked[i] = true }
            }
        }
        var out: [Token] = []
        var i = 0
        while i < chars.count {
            if !ruby[i].isEmpty {
                out.append(Token(id: i, text: String(chars[i]), pinyin: ruby[i], emphasized: marked[i]))
                i += 1
                continue
            }
            var j = i
            while j < chars.count, ruby[j].isEmpty { j += 1 }
            out.append(Token(id: i, text: String(chars[i..<j]), pinyin: "", emphasized: marked[i]))
            i = j
        }
        return out
    }
}

/// A flow of character columns: tight across, `lineSpacing` between lines.
private struct MandarinRubyLayout: Layout {
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + lineSpacing; row = 0 }
            x += size.width
            widest = max(widest, x)
            row = max(row, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + lineSpacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width
            row = max(row, size.height)
        }
    }
}
