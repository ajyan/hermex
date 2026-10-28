import Foundation
import UserNotifications

/// The evening "time to wind down" notification: off screens and into the nighttime routine an
/// hour before bed. Bed is his usual bedtime (the median of the last 14 nights in
/// `data/sleep/history.json`), pulled earlier by last night's shortfall against Garmin's sleep
/// need, at most 30 minutes.
///
/// One repeating local notification at the stored time, so it keeps firing on days the app
/// isn't opened. The time is recomputed each time the Daily Brief loads. Device-wide, like
/// `DailyBriefReminder`, and on until the More menu turns it off.
enum WindDownReminder {
    /// Bool in UserDefaults; absent means on.
    static let enabledKey = "windDown.notificationsEnabled"
    /// Int in UserDefaults: the wind-down time in minutes after midnight, absent until computed.
    static let minuteKey = "windDown.minuteOfDay"
    /// Marks the notification so it shows as a banner while the app is open.
    static let userInfoKey = "windDown"
    static let requestID = "windDown.daily"
    /// Minutes between the notification and bed.
    static let lead = 60
    /// The most a short night pulls bed earlier, in minutes.
    static let maxPull = 30
    static let nights = 14

    /// Minutes after midnight to send the notification, rounded to 5, or nil without bedtimes.
    static func minuteOfDay(from history: SleepHistory) -> Int? {
        let recent = history.nights.suffix(nights)
        let beds = recent.compactMap { $0.bed.flatMap(bedMinute) }.sorted()
        guard !beds.isEmpty else { return nil }
        let usual = (beds[(beds.count - 1) / 2] + beds[beds.count / 2]) / 2
        var shortfall = 0.0
        if let last = recent.last, let need = last.need, let hours = last.hours { shortfall = need - hours }
        let pull = min(maxPull, max(0, Int((shortfall * 60).rounded())))
        let minute = Int((Double(usual - pull - lead) / 5).rounded()) * 5
        return (minute % 1440 + 1440) % 1440
    }

    /// A "YYYY-MM-DDTHH:MM" bedtime as minutes after the evening's midnight: a bedtime after
    /// midnight (before noon) counts past 24:00 so it sorts after 23:00.
    static func bedMinute(_ stamp: String) -> Int? {
        let clock = stamp.split(separator: "T").last?.split(separator: ":").compactMap { Int($0) } ?? []
        guard clock.count >= 2, (0..<24).contains(clock[0]), (0..<60).contains(clock[1]) else { return nil }
        let minute = clock[0] * 60 + clock[1]
        return clock[0] < 12 ? minute + 1440 : minute
    }

    /// "9:40 PM", in the device's time format.
    static func clock(_ minuteOfDay: Int) -> String {
        let minute = (minuteOfDay % 1440 + 1440) % 1440
        let date = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) async {
        defaults.set(enabled, forKey: enabledKey)
        await refresh(defaults: defaults)
    }

    /// Stores the time `history` gives, when it gives one, and reschedules.
    static func update(from history: SleepHistory?, defaults: UserDefaults = .standard) async {
        if let history, let minute = minuteOfDay(from: history) { defaults.set(minute, forKey: minuteKey) }
        await refresh(defaults: defaults)
    }

    /// Replaces the pending notification with one at the stored time, or removes it when off.
    static func refresh(defaults: UserDefaults = .standard) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        guard isEnabled(defaults), let minute = defaults.object(forKey: minuteKey) as? Int else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time to wind down"
        content.body = "Off screens and into your nighttime routine. Bed around \(clock(minute + lead))."
        content.sound = .default
        content.threadIdentifier = userInfoKey
        content.userInfo = [userInfoKey: true]
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: minute / 60, minute: minute % 60), repeats: true)
        try? await center.add(UNNotificationRequest(identifier: requestID, content: content, trigger: trigger))
    }

    static func isWindDown(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[userInfoKey] as? Bool == true
    }
}
