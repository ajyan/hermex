import SwiftUI

/// The family call, on the Mandarin card's paper. Before: pick Mom or Dad for three things from his
/// week to tell them in Mandarin. After: what he wanted to say but couldn't, back in Mandarin and
/// added to tomorrow's recall.
struct MandarinCallSheet: View {
    let practice: MandarinPractice
    let palette: DeckPalette

    enum Half: String, CaseIterable, Identifiable {
        case before = "Before the call"
        case after = "After the call"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var half: Half = .before
    @State private var who = "mom"
    @State private var couldnt = ""
    @State private var speaker = MandarinSpeaker()
    @FocusState private var isWriting: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(selection: $half) {
                        ForEach(Half.allCases) { Text(verbatim: $0.rawValue).tag($0) }
                    } label: { Text(verbatim: "When") }
                        .pickerStyle(.segmented)
                    switch half {
                    case .before: before
                    case .after: after
                    }
                    if let error = practice.callError {
                        Text(verbatim: error).font(AppFont.footnote()).foregroundStyle(Color.hxTextSecondary)
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(palette.paper.ignoresSafeArea())
            .navigationTitle(Text(verbatim: "Family call"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(verbatim: "Done") }
                }
            }
            .toolbarBackground(palette.paper, for: .navigationBar)
        }
        .tint(palette.ink)
        .onDisappear { speaker.stop() }
        .presentationDragIndicator(.visible)
    }

    // MARK: Before

    @ViewBuilder
    private var before: some View {
        HStack(spacing: 8) {
            ForEach([("mom", "Mom"), ("dad", "Dad")], id: \.0) { key, name in
                Button { who = key } label: {
                    Text(verbatim: name)
                        .font(AppFont.subheadline(weight: .semibold))
                        .foregroundStyle(who == key ? palette.onInk : palette.ink)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(who == key ? palette.ink : palette.colors.wash, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(who == key ? .isSelected : [])
            }
        }
        if let items = practice.record.callPrep[who] {
            Text(verbatim: "Three things to tell \(who == "mom" ? "Mom" : "Dad")")
                .font(AppFont.display(style: .title3, weight: .semibold))
            ForEach(items, id: \.self) { item in
                MandarinTakeaway(tag: item.en, text: item.hanzi, pinyin: item.pinyin, note: nil,
                                 palette: palette, speaker: speaker)
            }
        } else {
            Text(verbatim: "Three things from your week, in Mandarin, to have ready.")
                .font(AppFont.body())
                .foregroundStyle(Color.hxTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            primary("Get three things to say", symbol: "sparkles", busy: practice.callLoading == who) {
                Task { await practice.prepareCall(who) }
            }
        }
    }

    // MARK: After

    @ViewBuilder
    private var after: some View {
        Text(verbatim: "What did you want to say but couldn't?")
            .font(AppFont.display(style: .title3, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
        TextEditor(text: $couldnt)
            .font(AppFont.body())
            .scrollContentBackground(.hidden)
            .focused($isWriting)
            .frame(minHeight: 110)
            .padding(10)
            .background(palette.colors.wash, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
            .overlay(alignment: .topLeading) {
                if couldnt.isEmpty {
                    Text(verbatim: "English is fine: the due date moved, I'm nervous about the race…")
                        .font(AppFont.body())
                        .foregroundStyle(Color.hxTextSecondary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
        primary("Say them in Mandarin", symbol: "arrow.right", busy: practice.callLoading == "after") {
            Task {
                isWriting = false
                if await practice.saveAfterCall(couldnt) { couldnt = "" }
            }
        }
        if !practice.record.callPhrases.isEmpty {
            Text(verbatim: "In tomorrow's recall")
                .font(AppFont.footnote(weight: .semibold))
                .foregroundStyle(palette.ink)
                .padding(.top, 4)
            ForEach(practice.record.callPhrases.reversed(), id: \.self) { item in
                MandarinTakeaway(tag: item.en, text: item.hanzi, pinyin: item.pinyin, note: nil,
                                 palette: palette, speaker: speaker)
            }
        }
    }

    private func primary(_ label: String, symbol: String, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(palette.onInk) } else { Image(systemName: symbol) }
                Text(verbatim: label)
            }
            .font(AppFont.body(weight: .semibold))
            .foregroundStyle(palette.onInk)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(palette.ink, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}
