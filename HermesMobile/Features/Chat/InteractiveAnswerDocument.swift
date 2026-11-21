import SwiftUI

/// The app's colors as CSS hex strings, handed to an interactive answer so the
/// tool matches the current appearance.
struct InteractiveAnswerTheme: Equatable {
    let isDark: Bool
    let canvas, surface, text, text2, sep, accent, ok, warn, danger: String
    /// Text on a solid accent fill: light `onAccent` (white) as the vault's diagrams were drawn for, or the
    /// paper's `onGlow` (its ink in dark mode, where glows are pastel).
    let onAccent: String

    /// `paper` is the object the tool belongs to (a Brief card's map, a Brain page's diagram): its controls
    /// then wear that paper's glow instead of Nous blue (DESIGN.md principle 5). Chat passes none.
    static func current(_ colorScheme: ColorScheme, paper: HermexPaper? = nil) -> InteractiveAnswerTheme {
        let isDark = colorScheme == .dark
        let palette = isDark ? HermexPalette.dark : HermexPalette.light
        func hex(_ token: HermexToken) -> String { hexString(palette[token] ?? 0) }
        let white = hexString(HermexPalette.light[.onAccent] ?? 0)
        let accent = paper.map { String(format: "#%06X", isDark ? $0.values.glowDark : $0.values.glowLight) }
        return InteractiveAnswerTheme(
            isDark: isDark,
            canvas: hex(.canvas), surface: hex(.surface),
            text: hex(.textPrimary), text2: hex(.textSecondary), sep: hex(.separator),
            accent: accent ?? hexString(isDark ? HermexPalette.accentDark : lightAccent),
            ok: hex(.success), warn: hex(.warning), danger: hex(.danger),
            onAccent: isDark ? paper.map { String(format: "#%06X", $0.values.ink) } ?? white : white
        )
    }

    /// `AccentColor`'s light value (DESIGN.md: Nous blue).
    private static let lightAccent: UInt32 = 0x0053FDFF

    private static func hexString(_ rgba: UInt32) -> String {
        String(format: "#%06X", rgba >> 8)
    }
}

/// Wraps an `atlas-ui` fragment in the sandboxed page an interactive answer
/// card loads: a CSP that allows inline code and the three script CDNs but no
/// network access, the theme as CSS variables, and the `atlas` bridge, which is
/// the tool's only way to reach the app.
enum InteractiveAnswerDocument {
    static let contentSecurityPolicy = "default-src 'none'; script-src 'unsafe-inline' https://cdnjs.cloudflare.com https://cdn.jsdelivr.net https://unpkg.com; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'"
    static let messageHandlerName = "atlas"

    static func html(fragment: String, theme: InteractiveAnswerTheme) -> String {
        // Concatenated, not interpolated into one template, so nothing in the
        // fragment is ever read as a format or template sequence.
        head(theme: theme) + fragment + "\n</body>\n</html>\n"
    }

    private static func head(theme: InteractiveAnswerTheme) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <style>
        :root {
          --canvas: \(theme.canvas); --surface: \(theme.surface); --text: \(theme.text); --text2: \(theme.text2);
          --sep: \(theme.sep); --accent: \(theme.accent); --on-accent: \(theme.onAccent); --ok: \(theme.ok); --warn: \(theme.warn); --danger: \(theme.danger);
          --font: -apple-system, system-ui, sans-serif;
          color-scheme: \(theme.isDark ? "dark" : "light");
        }
        html, body { margin: 0; background: transparent; }
        body { padding: 12px; color: var(--text); font: 15px/1.45 var(--font); -webkit-text-size-adjust: 100%; overflow-wrap: anywhere; }
        * { box-sizing: border-box; }
        button, input, select, textarea { font: inherit; color: inherit; }
        input, select, textarea { background: var(--canvas); border: 1px solid var(--sep); border-radius: 10px; padding: 8px 10px; }
        button { border: 0; border-radius: 999px; padding: 8px 14px; background: color-mix(in srgb, var(--accent) 12%, transparent); color: var(--accent); font-weight: 600; }
        :focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
        /* Vault diagrams write white text on accent fills inline; a paper's dark glow is pastel, so read --on-accent. */
        [style*="background:var(--accent)"], [style*="background: var(--accent)"] { color: var(--on-accent) !important; }
        </style>
        <script>
        (function () {
          var post = function (message) {
            try { window.webkit.messageHandlers.\(messageHandlerName).postMessage(message); } catch (e) {}
          };
          // Only a tap reaches the app, so a tool cannot fill the composer or
          // open pages on load each time its card comes back to life.
          var tapped = function () { return !navigator.userActivation || navigator.userActivation.isActive; };
          window.atlas = {
            ask: function (text) { if (tapped()) post({ type: 'ask', text: String(text) }); },
            open: function (url) { if (tapped()) post({ type: 'open', url: String(url) }); }
          };
          // Window capture, registered before any tool script, so it runs
          // first and a tool cannot stop it. A link never navigates the card;
          // only a tapped one opens, so `a.click()` on load opens nothing.
          window.addEventListener('click', function (e) {
            var link = e.target.closest && e.target.closest('a[href]');
            if (link && /^https?:/i.test(link.href)) {
              e.preventDefault();
              if (tapped()) post({ type: 'open', url: link.href });
            }
          }, true);
          window.addEventListener('error', function (e) {
            var t = e.target;
            if (t && t.tagName === 'SCRIPT') {
              post({ type: 'loadError' });
            } else if (t && t !== window && t.tagName) {
              // A blocked image or stylesheet: the tool still runs without it.
            } else {
              post({ type: 'scriptError', message: String(e.message || 'Script error') });
            }
          }, true);
          window.addEventListener('unhandledrejection', function (e) {
            post({ type: 'scriptError', message: String((e.reason && e.reason.message) || e.reason || 'Unhandled rejection') });
          });
          var pending = false;
          var report = function () {
            if (pending) return;
            pending = true;
            requestAnimationFrame(function () {
              pending = false;
              // The body, not the root: the root never measures less than the
              // card's current frame, so a tool could never shrink.
              post({ type: 'resize', height: Math.ceil(document.body.getBoundingClientRect().height) });
            });
          };
          document.addEventListener('DOMContentLoaded', function () {
            new ResizeObserver(report).observe(document.body);
            report();
          });
          window.addEventListener('load', report);
        })();
        </script>
        </head>
        <body>

        """
    }
}
