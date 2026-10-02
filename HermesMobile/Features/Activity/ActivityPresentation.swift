import SwiftUI

/// Display rules for the activity timeline, kept out of the views so they can
/// be asserted without rendering.
enum ActivityPresentation {
    static func outcomeStyle(_ outcome: AtlasOutcome) -> Color {
        switch outcome {
        case .blocked, .error: .hxDanger
        case .denied: .hxWarning
        case .approved: Color.accentColor
        case .ok, .unknown: .hxTextSecondary
        }
    }

    static func outcomeLabel(_ outcome: AtlasOutcome) -> String {
        switch outcome {
        case .ok: String(localized: "Done")
        case .error: String(localized: "Error")
        case .blocked: String(localized: "Blocked")
        case .denied: String(localized: "Denied")
        case .approved: String(localized: "Approved")
        case .unknown: String(localized: "Unknown")
        }
    }

    /// The sidecar reports the raw `sessions.source` value.
    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "webui": String(localized: "Chat")
        case "cron": String(localized: "Scheduled")
        case "signal": String(localized: "Signal")
        case "cli": String(localized: "Terminal")
        default: source.capitalized
        }
    }

    static func dayHeader(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "Today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day().locale(calendar.locale ?? .current))
    }

    static func symbol(forTool toolName: String) -> String {
        if toolName.hasPrefix("browser") { return "safari" }
        if toolName.contains("terminal") || toolName.contains("shell") { return "terminal" }
        if toolName.contains("file") { return "doc" }
        if toolName.contains("search") { return "magnifyingglass" }
        if toolName == "cron" { return "clock" }
        return "wrench.and.screwdriver"
    }

    /// "browser_snapshot" -> "Browser snapshot": the sidecar reports raw tool ids.
    static func toolTitle(_ toolName: String) -> String {
        let words = toolName.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func filterTitle(_ filter: AtlasActivityFilter) -> String {
        switch filter {
        case .all: String(localized: "All")
        case .attention: String(localized: "Attention")
        case .cron: String(localized: "Scheduled")
        case .spending: String(localized: "Spending")
        }
    }
}
