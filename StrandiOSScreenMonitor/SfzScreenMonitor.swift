import DeviceActivity
import Foundation
import UserNotifications

/// sfz: woken by iOS when a screen-time habit's apps pass their daily limit. Records the day as over
/// the limit (the app reads it to mark the habit missed) and says so in a notification.
final class SfzScreenMonitor: DeviceActivityMonitor {
    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        guard let id = SfzScreenShared.habitId(from: activity) else { return }
        SfzScreenShared.markExceeded(id)
        let label = SfzScreenShared.label(id)
        let content = UNMutableNotificationContent()
        content.title = "\(label.name): over your limit"
        content.body = label.limit > 0
            ? "You've passed \(label.limit) min today, so today's habit is missed."
            : "You've passed today's limit, so today's habit is missed."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "sfz-screen-\(id)-\(SfzScreenShared.dayKey())", content: content, trigger: nil))
    }
}
