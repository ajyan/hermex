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

    // MARK: - Episodes

    /// The episode row title: the rule's plain sentence when the sidecar
    /// supplies one, otherwise a generic label.
    static func episodeTitle(rulePlain: String?) -> String {
        if let rulePlain, !rulePlain.isEmpty {
            return rulePlain
        }
        return String(localized: "Unclassified event")
    }

    /// "6 events · 1:12–1:14 PM" for a run that spanned time, or "1 event ·
    /// at 1:12 PM" for a single event. For spans the AM/PM designator is
    /// shown once (after the end time) rather than per time. Rendered with the
    /// display locale so the times and count match the rest of the timeline.
    static func episodeSubtitle(count: Int, first: Date, last: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let countString = pluralEventCount(count)
        let firstTime = timeString(first, calendar: calendar)
        if count == 1 {
            return "\(countString) · at \(firstTime)"
        }
        let lastTime = timeString(last, calendar: calendar)
        // Strip the designator from each time, then append the first one once.
        let firstTimeNoDesignator = stripDesignator(firstTime)
        let lastTimeNoDesignator = stripDesignator(lastTime)
        let designator = extractDesignator(firstTime)
        let span = designator.isEmpty
            ? "\(firstTimeNoDesignator)–\(lastTimeNoDesignator)"
            : "\(firstTimeNoDesignator)–\(lastTimeNoDesignator) \(designator)"
        return "\(countString) · \(span)"
    }

    /// Strip a trailing " AM" or " PM" designator from a formatted time.
    private static func stripDesignator(_ time: String) -> String {
        if time.hasSuffix(" AM") { return String(time.dropLast(3)) }
        if time.hasSuffix(" PM") { return String(time.dropLast(3)) }
        return time
    }

    /// Extract the trailing " AM" or " PM" designator from a formatted time
    /// (without the leading space).
    private static func extractDesignator(_ time: String) -> String {
        if time.hasSuffix(" AM") { return "AM" }
        if time.hasSuffix(" PM") { return "PM" }
        return ""
    }

    /// The outcome that colors the episode's `action_needed` line: the most
    /// severe of the blocked/denied/error outcomes present (denied > blocked
    /// > error); the first one wins ties.
    static func episodeHighlightOutcome(_ outcomes: [AtlasOutcome]) -> AtlasOutcome? {
        var best: AtlasOutcome?
        var bestRank = Int.max
        for outcome in outcomes {
            let rank: Int?
            switch outcome {
            case .denied: rank = 0
            case .blocked: rank = 1
            case .error: rank = 2
            default: rank = nil
            }
            if let rank, rank < bestRank {
                bestRank = rank
                best = outcome
            }
        }
        return best
    }

    /// Whether an event row should show its rule's plain sentence (from
    /// `display`) instead of the raw rule id: the sentence is non-empty and
    /// the event is blocked/denied or the sidecar asked for an action.
    static func showsRulePlain(_ rulePlain: String?, outcome: AtlasOutcome, actionNeeded: String) -> Bool {
        guard let rulePlain, !rulePlain.isEmpty else { return false }
        return outcome == .blocked || outcome == .denied || !actionNeeded.isEmpty
    }

    private static func pluralEventCount(_ count: Int) -> String {
        if count == 1 { return String(localized: "1 event") }
        return "\(count) \(String(localized: "events"))"
    }

    /// The locale used for the pure display strings above. In production this
    /// is the user's locale (so tests that pin `en_US` see deterministic
    /// output); in unit tests the test harness sets it.
    static var localeForDisplay: Locale = {
        Locale.autoupdatingCurrent
    }()

    /// `DateFormatter` cache keyed by locale identifier. An explicit
    /// `DateFormatter` (rather than `Date.formatted`) takes the locale
    /// directly, which keeps `timeString` deterministic when tests pin
    /// `localeForDisplay`.
    private static var dateFormatterCache: [String: DateFormatter] = [:]

    private static func timeFormatter(for calendar: Calendar) -> DateFormatter {
        let key = (calendar.locale?.identifier ?? "en_US") + "|" + calendar.timeZone.identifier
        if let cached = dateFormatterCache[key] { return cached }
        let formatter = DateFormatter()
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.doesRelativeDateFormatting = false
        // `h` (12-hour, no leading zero) + `:mm` + ` a` (locale's AM/PM).
        // The explicit pattern avoids the U+202F narrow-space that
        // `timeStyle = .short` inserts before the designator.
        formatter.dateFormat = "h:mm a"
        dateFormatterCache[key] = formatter
        return formatter
    }

    /// Format a time in the display locale using an explicit pattern so the
    /// AM/PM designator is a known, fixed-width suffix. Tests pin a `Calendar`
    /// to get deterministic output; production uses the locale-pinned calendar
    /// by default.
    static func timeString(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        timeFormatter(for: calendar).string(from: date)
    }
}
