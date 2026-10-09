import Foundation
import UserNotifications

/// The 08:00 "your Daily Brief is ready" notification and a 09:00 reminder on days the
/// brief hasn't been opened by then. Local notifications only: nothing leaves the device.
///
/// The 08:00 notification repeats daily. Reminders can't be cancelled by a condition the
/// system checks, so one is scheduled per day for the next week and opening today's
/// brief removes today's. The week is rescheduled each time the app comes forward, so
/// reminders only lapse after a week away; the 08:00 notification never does.
/// Device-wide, not per server: the brief is opened on whichever server is active.
enum DailyBriefReminder {
    /// Bool in UserDefaults; absent until the user first opens the Daily Brief.
    static let enabledKey = "dailyBrief.notificationsEnabled"
    /// `yyyy-MM-dd` of the last day the brief was opened.
    static let openedOnKey = "dailyBrief.openedOn"
    /// Marks the notification so a tap opens the Daily Brief.
    static let userInfoKey = "dailyBrief"

    static let readyID = "dailyBrief.ready"
    static let reminderPrefix = "dailyBrief.reminder."
    /// Sundays and the 1st: "Your weekly (monthly) review is ready", opening that review.
    static let reviewPrefix = "dailyBrief.review."
    static let readyTime = (hour: 8, minute: 0)
    static let reminderTime = (hour: 9, minute: 0)
    static let reminderDays = 7

    /// One scheduled notification, as plain values so the schedule is testable.
    struct Planned: Equatable {
        let id: String
        let components: DateComponents
        let repeats: Bool
        let isReminder: Bool
        /// The review this notification opens (deck date, kind), for review notifications.
        var review: DeckRef?
    }

    struct DeckRef: Equatable {
        let date: String
        let kind: String
    }

    /// What should be pending at `now`: the daily 08:00, plus a 09:00 reminder for each of
    /// the next `reminderDays` days still ahead, skipping today once the brief was opened.
    static func plan(now: Date, openedOn: String?, calendar: Calendar = .current) -> [Planned] {
        var planned = [Planned(id: readyID,
                               components: DateComponents(hour: readyTime.hour, minute: readyTime.minute),
                               repeats: true, isReminder: false)]
        let today = calendar.startOfDay(for: now)
        for offset in 0..<reminderDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fireDate = calendar.date(bySettingHour: reminderTime.hour, minute: reminderTime.minute, second: 0, of: day),
                  fireDate > now
            else { continue }
            let key = DailyDeckPaths.day(day, calendar: calendar)
            if offset == 0 && openedOn == key { continue }
            planned.append(Planned(
                id: reminderPrefix + key,
                components: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                repeats: false, isReminder: true))
        }
        for offset in 0..<reminderDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fireDate = calendar.date(bySettingHour: readyTime.hour, minute: readyTime.minute + 1, second: 0, of: day),
                  fireDate > now
            else { continue }
            for review in reviews(on: day, calendar: calendar) {
                planned.append(Planned(
                    id: reviewPrefix + "\(review.date).\(review.kind)",
                    components: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                    repeats: false, isReminder: false, review: review))
            }
        }
        return planned
    }

    /// The reviews that open on `day`: the week's on Sunday (dated that Sunday), the month
    /// before's on the 1st (dated its last day). Matches tools/review_deck.py.
    static func reviews(on day: Date, calendar: Calendar = .current) -> [DeckRef] {
        var out: [DeckRef] = []
        if calendar.component(.weekday, from: day) == 1 {
            out.append(DeckRef(date: DailyDeckPaths.day(day, calendar: calendar), kind: "weekly"))
        }
        if calendar.component(.day, from: day) == 1, let last = calendar.date(byAdding: .day, value: -1, to: day) {
            out.append(DeckRef(date: DailyDeckPaths.day(last, calendar: calendar), kind: "monthly"))
        }
        return out
    }

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// Asks for permission the first time the Daily Brief opens, and turns the notifications
    /// on if granted. Later calls only refresh. The More menu can turn them off.
    static func enableOnFirstOpen(defaults: UserDefaults = .standard) async {
        if defaults.object(forKey: enabledKey) == nil {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            defaults.set(granted, forKey: enabledKey)
        }
        await refresh(defaults: defaults)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) async {
        if enabled {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            defaults.set(granted, forKey: enabledKey)
        } else {
            defaults.set(false, forKey: enabledKey)
        }
        await refresh(defaults: defaults)
    }

    /// Records that today's brief was opened: no reminder today, and today's notifications
    /// leave Notification Center.
    static func noteOpened(now: Date = Date(), defaults: UserDefaults = .standard) async {
        let today = DailyDeckPaths.day(now)
        defaults.set(today, forKey: openedOnKey)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [readyID, reminderPrefix + today])
        await refresh(now: now, defaults: defaults)
    }

    /// Replaces every pending Daily Brief notification with `plan`, or removes them all
    /// when the notifications are off.
    static func refresh(now: Date = Date(), defaults: UserDefaults = .standard) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier)
            .filter { $0 == readyID || $0.hasPrefix(reminderPrefix) || $0.hasPrefix(reviewPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard isEnabled(defaults) else { return }
        for item in plan(now: now, openedOn: defaults.string(forKey: openedOnKey)) {
            let content = UNMutableNotificationContent()
            if let review = item.review {
                content.title = review.kind == "weekly" ? "Your weekly review is ready" : "Your monthly review is ready"
                content.body = review.kind == "weekly"
                    ? "Look back on the week and set up the next one."
                    : "Look back on the month and pick next month's priorities."
                content.userInfo = [userInfoKey: true, "date": review.date, "kind": review.kind]
            } else {
                content.title = item.isReminder ? "Your Daily Brief is still waiting" : "Your Daily Brief is ready"
                content.body = item.isReminder ? "A few cards, a few minutes." : "Today's cards are in. Swipe through when you have a minute."
                content.userInfo = [userInfoKey: true]
            }
            content.sound = .default
            content.threadIdentifier = "dailyBrief"
            let trigger = UNCalendarNotificationTrigger(dateMatching: item.components, repeats: item.repeats)
            try? await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: trigger))
        }
    }

    static func isDailyBrief(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[userInfoKey] as? Bool == true
    }

    /// The deep link a tap opens: the review it announced, or today's brief.
    static func url(for userInfo: [AnyHashable: Any]) -> URL? {
        HermesDeepLink.dailyBriefURL(date: userInfo["date"] as? String, kind: userInfo["kind"] as? String)
    }
}
