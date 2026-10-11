import SwiftUI
import UIKit

/// An `atlas-ui` block in an assistant reply: a small tool Atlas wrote, run in
/// a sandboxed web view. Streaming blocks show a "Building…" placeholder;
/// settled ones are live only while on or near screen
/// (`InteractiveAnswerLiveBudget`) and otherwise rest at their last height.
struct InteractiveAnswerCard: View {
    let block: InteractiveAnswerBlock
    /// The block's raw text, for Copy code and View code.
    let source: String

    var body: some View {
        switch block {
        case .building(let title):
            InteractiveAnswerBuildingCard(title: title)
        case .card(let fragment, let title):
            InteractiveAnswerLiveCard(fragment: fragment, title: title, source: source)
        case .code:
            EmptyView()
        }
    }
}

private struct InteractiveAnswerBuildingCard: View {
    let title: String?

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(title.map { String(localized: "Building \($0)…") } ?? String(localized: "Building tool…"))
                .font(.subheadline)
                .foregroundStyle(.hxTextSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        .interactiveAnswerSurface()
        .accessibilityElement(children: .combine)
    }
}

private struct InteractiveAnswerLiveCard: View {
    let fragment: String
    let title: String
    let source: String

    private enum Failure: Equatable {
        case script
        case load
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.interactiveAnswerAsk) private var ask
    @State private var budget = InteractiveAnswerLiveBudget.shared
    @State private var reportedHeight: CGFloat?
    @State private var failure: Failure?
    @State private var reloadToken = 0
    @State private var showsFullScreen = false
    @State private var showsCode = false

    private static let restingHeight: CGFloat = 240
    private var cardID: String { InteractiveAnswerCardID.make(fragment: fragment) }
    private var maxHeight: CGFloat { UIScreen.main.bounds.height * 0.7 }
    private var height: CGFloat {
        min(reportedHeight ?? budget.height(for: cardID) ?? Self.restingHeight, maxHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.hxSeparator)
            content
                .frame(height: height)
                .clipped()
        }
        .interactiveAnswerSurface()
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            if visible { budget.becameVisible(cardID) } else { budget.becameHidden(cardID) }
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = source
            } label: {
                Label(String(localized: "Copy Code"), systemImage: "doc.on.doc")
            }
            Button {
                showsCode = true
            } label: {
                Label(String(localized: "View Code"), systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
        .sheet(isPresented: $showsFullScreen) {
            InteractiveAnswerFullScreen(title: title, html: html, onMessage: handleFullScreen)
        }
        .sheet(isPresented: $showsCode) {
            InteractiveAnswerCodeSheet(title: title, source: source)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.hxTextPrimary)
                    .lineLimit(1)
                Text(String(localized: "Interactive"))
                    .font(.caption)
                    .foregroundStyle(.hxTextSecondary)
            }
            Spacer(minLength: 0)
            Button {
                showsFullScreen = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel(String(localized: "Open full screen"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            failureView(failure)
        } else if budget.isLive(cardID) {
            InteractiveAnswerWebView(html: html, onMessage: handle, onNavigationFailure: { failure = .load })
                .id(reloadToken)
        } else {
            Color.clear
                .overlay {
                    Image(systemName: "hand.tap")
                        .font(.title3)
                        .foregroundStyle(.hxTextSecondary)
                }
                .accessibilityHidden(true)
        }
    }

    private func failureView(_ failure: Failure) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.hxDanger)
            Text(failure == .script
                 ? String(localized: "This tool hit an error")
                 : String(localized: "Couldn't load. Check your connection"))
                .font(.subheadline)
                .foregroundStyle(.hxTextPrimary)
                .multilineTextAlignment(.center)
            if failure == .script {
                Button(String(localized: "View Code")) { showsCode = true }
            } else {
                Button(String(localized: "Retry")) {
                    self.failure = nil
                    reloadToken &+= 1
                }
            }
        }
        .buttonStyle(.bordered)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var html: String {
        InteractiveAnswerDocument.html(fragment: fragment, theme: .current(colorScheme))
    }

    private func handle(_ message: InteractiveAnswerBridgeMessage) {
        switch message {
        case .resize(let reported):
            guard reported != reportedHeight else { return }
            reportedHeight = reported
            budget.rememberHeight(reported, for: cardID)
        case .scriptError:
            failure = .script
        case .loadError:
            failure = .load
        case .ask, .open:
            handleFullScreen(message)
        }
    }

    /// Full screen sizes itself, so only the actions matter there.
    private func handleFullScreen(_ message: InteractiveAnswerBridgeMessage) {
        switch message {
        case .ask(let text):
            showsFullScreen = false
            ask(text)
        case .open(let url):
            openURL(url)
        case .resize, .scriptError, .loadError:
            break
        }
    }
}

private struct InteractiveAnswerFullScreen: View {
    let title: String
    let html: String
    let onMessage: (InteractiveAnswerBridgeMessage) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            InteractiveAnswerWebView(html: html, onMessage: onMessage, onNavigationFailure: {})
                .background(Color.hxSurface)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) { dismiss() }
                    }
                }
        }
    }
}

private struct InteractiveAnswerCodeSheet: View {
    let title: String
    let source: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                ChatCodeBlock(language: "html", content: source, isStreaming: false)
                    .padding()
            }
            .background(Color.hxCanvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
    }
}

private extension View {
    func interactiveAnswerSurface() -> some View {
        background(Color.hxSurface, in: RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous)
                    .strokeBorder(Color.hxSeparator, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: HXRadius.md, style: .continuous))
            .padding(.vertical, 4)
    }
}
