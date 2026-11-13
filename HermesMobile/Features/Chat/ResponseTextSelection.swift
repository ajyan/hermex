import SwiftUI
import UIKit

/// One native selection document around the existing response layout. Text leaves
/// supply their actual glyph geometry; images, equations and controls never register.
///
/// The content renders in its own hosted SwiftUI graph, rebuilt only when `identity`,
/// `inputs` or the values `ResponseSelectionEnvironment` compares change: a long chat
/// updates its replies far more often than they change (every stream tick can reach
/// them), and every rebuild re-lays the whole reply out.
struct ResponseTextSelection<Content: View>: UIViewControllerRepresentable {
    let identity: String
    /// Everything `content` renders from besides `identity` and the environment.
    /// Callbacks don't belong here: route them through a stable reference so a kept
    /// content tree still calls the latest one.
    var inputs: AnyHashable?
    // Metadata stays registered when glyph rendering is deferred offscreen.
    var collectsGlyphs = true
    /// Ask Atlas on a selection. Read on every update, so a kept content tree still
    /// quotes into the latest composer.
    var onAskHermex: ((String) -> Void)?
    @ViewBuilder let content: () -> Content
    /// Forwarded whole, so the fork's own keys (interactive answers, Brain routes,
    /// shell openers) reach the hosted reply. Only `ResponseSelectionEnvironment`'s
    /// values trigger a rebuild; a value outside it reaches a settled reply on its
    /// next rebuild, so a renderer that reads a value that can change while the
    /// reply stays must add it there.
    @Environment(\.self) private var environment
    /// The hosted content's height. The content can grow after its first layout
    /// (MarkdownUI block margins, async code highlighting); reading this in
    /// `updateUIViewController` turns that growth into an update, so SwiftUI asks
    /// `sizeThatFits` again instead of keeping a stale height that lets the reply
    /// spill under the rows above and below it.
    @State private var contentHeight: CGFloat = 0

    func makeUIViewController(context: Context) -> ResponseSelectionController {
        ResponseSelectionController()
    }

    func updateUIViewController(_ controller: ResponseSelectionController, context: Context) {
        RenderProbe.hit(.responseSelectionUpdate)
        controller.scope.collectsGlyphs = collectsGlyphs
        controller.input.onAskHermex = onAskHermex
        controller.openURL = environment.openURL
        if controller.identity != identity {
            controller.input.selectedTextRange = nil
            controller.identity = identity
        }
        _ = contentHeight
        let rendering = ResponseSelectionRendering(
            identity: identity,
            inputs: inputs,
            environment: ResponseSelectionEnvironment(environment)
        )
        guard controller.rendering != rendering else { return }
        controller.rendering = rendering
        RenderProbe.hit(.responseSelectionRebuild)
        let contentHeight = $contentHeight
        // The forwarded environment goes outermost so the selection scope and the
        // stable link forwarder installed inside win.
        controller.host.rootView = AnyView(content()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight.wrappedValue = $0 }
            .responseSelectionDocument(controller.scope)
            .textSelection(.disabled)
            .environment(\.openURL, controller.forwardedOpenURL)
            .environment(\.self, environment))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: ResponseSelectionController, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiViewController.host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

/// The environment values a hosted reply renders from that can change while the reply
/// stays, compared to skip rebuilds. Appearance and accessibility values plus the chat's
/// own keys; the shared actions compare by identity, since their owners keep one
/// instance and refresh its handler in place.
struct ResponseSelectionEnvironment: Equatable {
    let colorScheme: ColorScheme
    let colorSchemeContrast: ColorSchemeContrast
    let layoutDirection: LayoutDirection
    let dynamicTypeSize: DynamicTypeSize
    let legibilityWeight: LegibilityWeight?
    let displayScale: CGFloat
    let locale: Locale
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let tableEdgeFadeColor: Color?
    let workspaceRoot: String?
    let serverOrigin: URL?
    let interactiveAnswersEnabled: Bool
    let chatDisclosureToggled: ChatDisclosureToggleAction
    let interactiveAnswerAsk: InteractiveAnswerAskAction

    init(_ environment: EnvironmentValues) {
        colorScheme = environment.colorScheme
        colorSchemeContrast = environment.colorSchemeContrast
        layoutDirection = environment.layoutDirection
        dynamicTypeSize = environment.dynamicTypeSize
        legibilityWeight = environment.legibilityWeight
        displayScale = environment.displayScale
        locale = environment.locale
        reduceMotion = environment.accessibilityReduceMotion
        reduceTransparency = environment.accessibilityReduceTransparency
        tableEdgeFadeColor = environment.markdownTableEdgeFadeColor
        workspaceRoot = environment.chatWorkspaceRoot
        serverOrigin = environment.transcriptServerOrigin
        interactiveAnswersEnabled = environment.interactiveAnswersEnabled
        chatDisclosureToggled = environment.chatDisclosureToggled
        interactiveAnswerAsk = environment.interactiveAnswerAsk
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.colorScheme == rhs.colorScheme &&
            lhs.colorSchemeContrast == rhs.colorSchemeContrast &&
            lhs.layoutDirection == rhs.layoutDirection &&
            lhs.dynamicTypeSize == rhs.dynamicTypeSize &&
            lhs.legibilityWeight == rhs.legibilityWeight &&
            lhs.displayScale == rhs.displayScale &&
            lhs.locale == rhs.locale &&
            lhs.reduceMotion == rhs.reduceMotion &&
            lhs.reduceTransparency == rhs.reduceTransparency &&
            lhs.tableEdgeFadeColor == rhs.tableEdgeFadeColor &&
            lhs.workspaceRoot == rhs.workspaceRoot &&
            lhs.serverOrigin == rhs.serverOrigin &&
            lhs.interactiveAnswersEnabled == rhs.interactiveAnswersEnabled &&
            lhs.chatDisclosureToggled === rhs.chatDisclosureToggled &&
            lhs.interactiveAnswerAsk === rhs.interactiveAnswerAsk
    }
}

/// What the hosted root was last built from.
struct ResponseSelectionRendering: Equatable {
    let identity: String
    let inputs: AnyHashable?
    let environment: ResponseSelectionEnvironment
}

final class ResponseSelectionController: UIViewController {
    let input = ResponseSelectionInput()
    lazy var scope = ResponseSelectionScope(input: input)
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    var identity = ""
    var rendering: ResponseSelectionRendering?
    /// The latest `openURL` around the reply. The hosted root holds
    /// `forwardedOpenURL` instead, so a kept root still reaches this one.
    var openURL = OpenURLAction { _ in .systemAction }
    private(set) lazy var forwardedOpenURL = OpenURLAction { [weak self] url in
        guard let self else { return .systemAction }
        openURL(url)
        return .handled
    }

    override func loadView() {
        view = input
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        input.addSubview(host.view)
        host.view.addInteraction(input.selectionInteraction)
        input.accessibilityElements = [host.view!]
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: input.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: input.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: input.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

/// The hosted SwiftUI tree must not retain its containing UIKit view.
@Observable
final class ResponseSelectionScope {
    var collectsGlyphs = true
    weak var input: ResponseSelectionInput?
    init(input: ResponseSelectionInput) { self.input = input }
}

private struct ResponseSelectionScopeKey: EnvironmentKey {
    static let defaultValue: ResponseSelectionScope? = nil
}

private struct ResponseSelectionOrderKey: PreferenceKey {
    static let defaultValue: [UUID] = []
    static func reduce(value: inout [UUID], nextValue: () -> [UUID]) {
        value += nextValue()
    }
}

extension EnvironmentValues {
    var responseSelectionScope: ResponseSelectionScope? {
        get { self[ResponseSelectionScopeKey.self] }
        set { self[ResponseSelectionScopeKey.self] = newValue }
    }
}

extension View {
    func responseSelectionDocument(_ scope: ResponseSelectionScope) -> some View {
        environment(\.responseSelectionScope, scope)
            .onPreferenceChange(ResponseSelectionOrderKey.self) { [weak input = scope.input] order in
                input?.leafOrder = order
            }
    }
}

extension View {
    /// Attach only to a leaf containing one resolved Text, not its block container.
    func responseSelectableText(_ text: String, separator: String = "\n", tableColumn: Int? = nil) -> some View {
        modifier(ResponseSelectionLeaf(text: text, separator: separator, tableColumn: tableColumn))
    }
}

private struct ResponseSelectionLeaf: ViewModifier {
    let text: String
    let separator: String
    let tableColumn: Int?
    @Environment(\.responseSelectionScope) private var scope

    @ViewBuilder
    func body(content: Content) -> some View {
        if let scope {
            content.modifier(RegisteredResponseSelectionLeaf(text: text, separator: separator, tableColumn: tableColumn, scope: scope))
        } else {
            content
        }
    }
}

/// Allocate glyph storage only for completed responses, never the streaming path.
private struct RegisteredResponseSelectionLeaf: ViewModifier {
    let text: String
    let separator: String
    let tableColumn: Int?
    let scope: ResponseSelectionScope
    @State private var geometry = ResponseGlyphGeometry()
    @State private var id = UUID()

    func body(content: Content) -> some View {
        Group {
            if scope.collectsGlyphs {
                content.textRenderer(ResponseSelectionRenderer(geometry: geometry))
            } else {
                content
            }
        }
        .background(ResponseSelectionMarker(scope: scope, id: id, text: text, separator: separator, tableColumn: tableColumn, geometry: geometry))
        .preference(key: ResponseSelectionOrderKey.self, value: [id])
    }
}

struct ResponseSelectionGlyph {
    let range: NSRange
    let rect: CGRect
    let rightToLeft: Bool
}

/// TextRenderer can draw off the main actor. Geometry is published without
/// invalidating SwiftUI state or scheduling a second rendering pass.
final class ResponseGlyphGeometry: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ResponseSelectionGlyph] = []

    var glyphs: [ResponseSelectionGlyph] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func replace(_ glyphs: [ResponseSelectionGlyph]) {
        lock.lock()
        storage = glyphs
        lock.unlock()
    }
}

/// Attachments occupy a Text character index but no selectable source character.
struct ResponseSelectionImageAttribute: TextAttribute {}

private struct ResponseSelectionRenderer: TextRenderer {
    let geometry: ResponseGlyphGeometry

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let indices = layout.flatMap { $0.flatMap { $0.characterIndices } }
        guard let start = indices.min() else { return }
        let imageOffsets = layout.flatMap { line in
            line.filter { $0[ResponseSelectionImageAttribute.self] != nil }
                .flatMap { $0.characterIndices }
        }.map { start.distance(to: $0) }.sorted()
        func selectableOffset(_ raw: Int) -> Int {
            var lower = 0
            var upper = imageOffsets.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if imageOffsets[middle] < raw { lower = middle + 1 } else { upper = middle }
            }
            return raw - lower
        }
        var glyphs: [ResponseSelectionGlyph] = []
        for line in layout {
            context.draw(line)
            for run in line where run[ResponseSelectionImageAttribute.self] == nil {
                for slice in run {
                    guard let lower = slice.characterIndices.min(), let upper = slice.characterIndices.max() else { continue }
                    let location = selectableOffset(start.distance(to: lower))
                    let end = selectableOffset(start.distance(to: upper) + 1)
                    glyphs.append(ResponseSelectionGlyph(
                        range: NSRange(location: location, length: end - location),
                        rect: slice.typographicBounds.rect,
                        rightToLeft: run.layoutDirection == .rightToLeft
                    ))
                }
            }
        }
        geometry.replace(glyphs)
    }
}

private struct ResponseSelectionMarker: UIViewRepresentable {
    let scope: ResponseSelectionScope
    let id: UUID
    let text: String
    let separator: String
    let tableColumn: Int?
    let geometry: ResponseGlyphGeometry
    @Environment(\.layoutDirection) private var layoutDirection

    func makeUIView(context: Context) -> ResponseSelectionLeafView {
        let view = ResponseSelectionLeafView()
        view.isUserInteractionEnabled = false
        scope.input?.leaves.add(view)
        return view
    }

    func updateUIView(_ view: ResponseSelectionLeafView, context: Context) {
        view.id = id
        view.text = text
        view.separator = separator
        view.tableColumn = tableColumn
        view.geometry = geometry
        view.rightToLeft = layoutDirection == .rightToLeft
    }
}

final class ResponseSelectionLeafView: UIView {
    var id = UUID()
    var text = ""
    var separator = "\n"
    var tableColumn: Int?
    var geometry: ResponseGlyphGeometry?
    var rightToLeft = false
}

final class ResponseTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

final class ResponseTextRange: UITextRange {
    let range: NSRange
    init(_ range: NSRange) { self.range = range }
    override var start: UITextPosition { ResponseTextPosition(range.location) }
    override var end: UITextPosition { ResponseTextPosition(NSMaxRange(range)) }
    override var isEmpty: Bool { range.length == 0 }
}

final class ResponseSelectionRect: UITextSelectionRect {
    let glyph: ResponseSelectionGlyph
    let starts: Bool
    let ends: Bool
    init(_ glyph: ResponseSelectionGlyph, starts: Bool, ends: Bool) {
        self.glyph = glyph
        self.starts = starts
        self.ends = ends
    }
    override var rect: CGRect { glyph.rect }
    override var writingDirection: NSWritingDirection { glyph.rightToLeft ? .rightToLeft : .leftToRight }
    override var containsStart: Bool { starts }
    override var containsEnd: Bool { ends }
    override var isVertical: Bool { false }
}

private struct ResponseTextSelectionPolicy: ViewModifier {
    @Environment(\.responseSelectionScope) private var scope
    @ViewBuilder func body(content: Content) -> some View {
        if scope == nil { content.textSelection(.enabled) }
        else { content.textSelection(.disabled) }
    }
}

extension View {
    func responseTextSelectionPolicy() -> some View { modifier(ResponseTextSelectionPolicy()) }
}
