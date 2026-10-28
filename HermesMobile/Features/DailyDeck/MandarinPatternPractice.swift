import SwiftUI

/// Practicing the day's pattern: three prompts from his week, one at a time. He says each in Mandarin
/// (zh-CN dictation or typing); right gets "That works" and another natural way, close shows where the
/// pattern goes and asks for one more try, off shows the natural way. Answered prompts stay above the
/// current one; once all three are done the last result stays on screen until Done.
struct MandarinPatternPractice: View {
    let practice: MandarinPractice
    let palette: DeckPalette

    @State private var isSpeaking = false
    @State private var speaker = MandarinSpeaker()
    @Environment(\.dismiss) private var dismiss

    private var pattern: MandarinPattern? { practice.record.review?.pattern }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let pattern {
                        Text(verbatim: "Practice · " + pattern.name)
                            .font(AppFont.caption(weight: .semibold))
                            .foregroundStyle(palette.ink)
                        Text(verbatim: pattern.form)
                            .font(AppFont.footnote(weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(pattern.prompts.enumerated()), id: \.offset) { index, prompt in
                            if index <= (practice.practicePrompt?.index ?? pattern.prompts.count) {
                                promptRow(index, prompt, of: pattern.prompts.count)
                            }
                        }
                    }
                    if case let .failed(message) = practice.checking {
                        Text(verbatim: message).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
                    }
                    if practice.practicePrompt != nil {
                        Button { speaker.stop(); isSpeaking = true } label: {
                            Label { Text(verbatim: practice.checking == .waiting ? "Checking…" : "Say it") } icon: {
                                Image(systemName: "mic.fill")
                            }
                            .font(AppFont.body(weight: .semibold))
                            .foregroundStyle(palette.onInk)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(palette.ink, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(practice.checking == .waiting)
                    } else if practice.isPracticeDone {
                        Button { dismiss() } label: {
                            Label { Text(verbatim: "Done") } icon: { Image(systemName: "checkmark") }
                                .font(AppFont.body(weight: .semibold))
                                .foregroundStyle(palette.onInk)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(palette.ink, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Text(verbatim: MandarinCardCopy.nextCall(practice.card.speaker))
                        .font(AppFont.footnote())
                        .foregroundStyle(Color.hxTextSecondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(palette.paper.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Done") }
                }
            }
            .sheet(isPresented: $isSpeaking) {
                MandarinSpeakSheet(prompt: practice.practicePrompt?.prompt.en ?? "", detail: pattern?.form,
                                   initial: "", palette: palette) { text in
                    Task { await practice.check(text) }
                }
            }
        }
        .tint(palette.ink)
        .onDisappear { speaker.stop() }
    }

    @ViewBuilder
    private func promptRow(_ index: Int, _ prompt: MandarinPattern.Prompt, of count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "\(index + 1) of \(count)").font(AppFont.caption()).foregroundStyle(Color.hxTextSecondary)
            Text(emphasized(prompt.en, slot: prompt.slot))
                .font(AppFont.body())
                .fixedSize(horizontal: false, vertical: true)
            if let check = practice.record.practice[index] { result(check, retried: practice.record.practiceRetried.contains(index)) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
    }

    @ViewBuilder
    private func result(_ check: MandarinPatternCheck, retried: Bool) -> some View {
        switch check.verdict {
        case .right:
            MandarinTakeaway(tag: "That works · also natural", text: check.natural, pinyin: check.naturalPinyin,
                             note: nil, palette: palette, speaker: speaker)
        case .close:
            MandarinTakeaway(tag: retried ? "Close · the natural way" : "Close · try once more", text: check.natural,
                             pinyin: check.naturalPinyin, note: check.note, palette: palette, speaker: speaker)
        case .off:
            MandarinTakeaway(tag: "The natural way", text: check.natural, pinyin: check.naturalPinyin,
                             note: check.note, palette: palette, speaker: speaker)
        }
    }

    /// The prompt with its slot words in bold, so he knows what goes in the pattern.
    private func emphasized(_ text: String, slot: String?) -> AttributedString {
        var out = AttributedString(text)
        if let slot, !slot.isEmpty, let range = out.range(of: slot) {
            out[range].font = AppFont.body(weight: .semibold)
            out[range].foregroundColor = palette.ink
        }
        return out
    }
}
