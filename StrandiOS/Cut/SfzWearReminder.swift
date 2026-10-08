import SwiftUI
import Combine
import UserNotifications
import StrandDesign

/// sfz: reminders to put the WHOOP back on. When the band comes off the wrist, or isn't seen at all
/// (left at home, out of range), sfz schedules a reminder every few minutes. Each one can be snoozed
/// from the notification (in 15 min, 1 hour, not today); tapping it opens a fuller choice in the app.
/// The reminders are scheduled ahead as ordinary notifications, so they arrive even with sfz closed,
/// and they stop the moment the band is back on.
@MainActor
final class SfzWearReminder: ObservableObject {
    static let shared = SfzWearReminder()
    static let category = "SFZ_WEAR"
    static let prefix = "sfz-wear-"
    static let actionAgain = "SFZ_WEAR_AGAIN", actionHour = "SFZ_WEAR_HOUR", actionToday = "SFZ_WEAR_TODAY"

    /// What opening sfz does while the band is missing.
    enum OpenBehaviour: String, CaseIterable, Identifiable {
        case keep, hour, untilBack
        var id: String { rawValue }
        var label: String {
            switch self {
            case .keep: return "Keep reminding"
            case .hour: return "Pause for 1 hour"
            case .untilBack: return "Pause until the band is back"
            }
        }
    }

    private let d = UserDefaults.standard
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "sfz.wear.enabled"); reschedule() } }
    /// Minutes between reminders.
    @Published var interval: Int { didSet { d.set(interval, forKey: "sfz.wear.interval"); reschedule() } }
    @Published var quietOn: Bool { didSet { d.set(quietOn, forKey: "sfz.wear.quietOn"); reschedule() } }
    @Published var quietStart: Int { didSet { d.set(quietStart, forKey: "sfz.wear.quietStart"); reschedule() } }
    @Published var quietEnd: Int { didSet { d.set(quietEnd, forKey: "sfz.wear.quietEnd"); reschedule() } }
    @Published var onOpen: OpenBehaviour { didSet { d.set(onOpen.rawValue, forKey: "sfz.wear.onOpen") } }
    @Published private(set) var snoozedUntil: Date? { didSet { d.set(snoozedUntil, forKey: "sfz.wear.snoozedUntil") } }
    @Published private(set) var pausedUntilBack: Bool { didSet { d.set(pausedUntilBack, forKey: "sfz.wear.pausedUntilBack") } }
    @Published private(set) var missingSince: Date? { didSet { d.set(missingSince, forKey: "sfz.wear.missingSince") } }
    /// True when the band was connected but off the wrist; false when it wasn't seen at all.
    @Published private(set) var offWrist = false
    /// Set when a reminder is tapped, to show the choices.
    @Published var showPrompt = false

    private init() {
        enabled = d.object(forKey: "sfz.wear.enabled") as? Bool ?? true
        interval = d.object(forKey: "sfz.wear.interval") as? Int ?? 15
        quietOn = d.object(forKey: "sfz.wear.quietOn") as? Bool ?? true
        quietStart = d.object(forKey: "sfz.wear.quietStart") as? Int ?? 23 * 60
        quietEnd = d.object(forKey: "sfz.wear.quietEnd") as? Int ?? 7 * 60
        onOpen = OpenBehaviour(rawValue: d.string(forKey: "sfz.wear.onOpen") ?? "") ?? .keep
        snoozedUntil = d.object(forKey: "sfz.wear.snoozedUntil") as? Date
        pausedUntilBack = d.bool(forKey: "sfz.wear.pausedUntilBack")
        missingSince = d.object(forKey: "sfz.wear.missingSince") as? Date
        registerCategory()
    }

    private func registerCategory() {
        let again = UNNotificationAction(identifier: Self.actionAgain, title: "Remind me again later", options: [])
        let hour = UNNotificationAction(identifier: Self.actionHour, title: "Snooze 1 hour", options: [])
        let today = UNNotificationAction(identifier: Self.actionToday, title: "Not today", options: [])
        let cat = UNNotificationCategory(identifier: Self.category, actions: [again, hour, today], intentIdentifiers: [])
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            var all = existing.filter { $0.identifier != Self.category }
            all.insert(cat)
            center.setNotificationCategories(all)
        }
    }

    // MARK: Band state

    /// Called whenever wear, connection or charging changes.
    func update(worn: Bool, connected: Bool, charging: Bool) {
        if worn && connected {
            // Back on: stop everything and forget any "until it's back" pause.
            missingSince = nil
            pausedUntilBack = false
            cancel()
            return
        }
        if connected && charging {
            // On the charger: no reminders, and the clock restarts once it comes off.
            missingSince = nil
            cancel()
            return
        }
        if missingSince == nil {
            missingSince = Date()
            offWrist = connected
        }
        reschedule()
    }

    /// Called when sfz comes to the front.
    func appOpened() {
        guard missingSince != nil else { return }
        switch onOpen {
        case .keep: break
        case .hour: snooze(until: Date().addingTimeInterval(3600))
        case .untilBack: pauseUntilBack()
        }
    }

    // MARK: Snoozing

    func snooze(until date: Date) {
        snoozedUntil = date
        reschedule()
    }

    func snoozeAgain() { snooze(until: Date().addingTimeInterval(Double(interval) * 60)) }

    func notToday() {
        let cal = Calendar.current
        snooze(until: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date().addingTimeInterval(8 * 3600))
    }

    func pauseUntilBack() {
        pausedUntilBack = true
        cancel()
    }

    func resume() {
        snoozedUntil = nil
        pausedUntilBack = false
        reschedule()
    }

    func handle(action: String) {
        switch action {
        case Self.actionAgain: snoozeAgain()
        case Self.actionHour: snooze(until: Date().addingTimeInterval(3600))
        case Self.actionToday: notToday()
        default: showPrompt = true
        }
    }

    // MARK: Scheduling

    private func inQuiet(_ date: Date) -> Bool {
        guard quietOn else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return quietStart <= quietEnd ? (m >= quietStart && m < quietEnd) : (m >= quietStart || m < quietEnd)
    }

    /// The next moment outside quiet hours, at or after `date`.
    private func outsideQuiet(_ date: Date) -> Date {
        guard inQuiet(date) else { return date }
        let cal = Calendar.current
        var end = cal.date(bySettingHour: quietEnd / 60, minute: quietEnd % 60, second: 0, of: date) ?? date
        if end <= date { end = cal.date(byAdding: .day, value: 1, to: end) ?? end }
        return end
    }

    func cancel() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let ids = pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        center.getDeliveredNotifications { delivered in
            let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix(Self.prefix) }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func reschedule() {
        cancel()
        guard enabled, !pausedUntilBack, let since = missingSince else { return }
        let step = Double(max(interval, 1)) * 60
        let now = Date()
        var t = max(since.addingTimeInterval(step), now.addingTimeInterval(60))
        if let s = snoozedUntil, s > t { t = s }
        var times: [Date] = []
        while times.count < 20 {
            t = outsideQuiet(t)
            times.append(t)
            t = t.addingTimeInterval(step)
        }
        let center = UNUserNotificationCenter.current()
        let off = offWrist
        for (i, fire) in times.enumerated() {
            let mins = Int(fire.timeIntervalSince(since) / 60)
            let gone = mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins) min"
            let content = UNMutableNotificationContent()
            content.title = "Put your WHOOP on"
            content.body = off
                ? "It's been off your wrist for \(gone). Sleep, strain and recovery need it on."
                : "sfz hasn't seen your WHOOP for \(gone). Wear it so nothing is missed."
            content.sound = .default
            content.categoryIdentifier = Self.category
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fire.timeIntervalSince(now)), repeats: false)
            center.add(UNNotificationRequest(identifier: "\(Self.prefix)\(i)", content: content, trigger: trigger))
        }
    }
}

/// Shown when a wear reminder is tapped: when to be reminded next.
struct SfzWearPromptSheet: View {
    @ObservedObject private var wear = SfzWearReminder.shared
    @Environment(\.dismiss) private var dismiss
    @State private var custom = Date().addingTimeInterval(2 * 3600)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Remind me again in \(wear.interval) min") { wear.snoozeAgain(); dismiss() }
                    Button("Snooze 1 hour") { wear.snooze(until: Date().addingTimeInterval(3600)); dismiss() }
                    Button("Snooze 2 hours") { wear.snooze(until: Date().addingTimeInterval(7200)); dismiss() }
                    Button("Pause until the band is back on") { wear.pauseUntilBack(); dismiss() }
                    Button("Not today") { wear.notToday(); dismiss() }
                } header: {
                    Text("Your WHOOP isn't on")
                } footer: {
                    Text("Reminders stop by themselves as soon as the band is back on your wrist.")
                }
                Section("Until a time") {
                    DatePicker("Remind me at", selection: $custom, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    Button("Set") { wear.snooze(until: custom); dismiss() }
                }
                Section {
                    Button("Turn wear reminders off", role: .destructive) { wear.enabled = false; dismiss() }
                } footer: {
                    Text("You can change the timing and quiet hours in Settings → Wear reminder.")
                }
            }
            .navigationTitle("Wear reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Settings → Wear reminder.
struct SfzWearReminderSettingsCard: View {
    @ObservedObject private var wear = SfzWearReminder.shared

    private func time(_ m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }

    private func minutes(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    var body: some View {
        StrandCard(padding: NoopMetrics.space5) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings").strandOverline()
                    HStack(spacing: NoopMetrics.space2 + 2) {
                        Image(systemName: "applewatch.radiowaves.left.and.right").foregroundStyle(StrandPalette.accent)
                        Text("Wear reminder").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text("A reminder when your WHOOP is off your wrist or not seen, until it's back on.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Remind me to wear it", isOn: $wear.enabled).tint(StrandPalette.accent)
                if wear.enabled {
                    Picker("Every", selection: $wear.interval) {
                        ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    Toggle("Quiet hours", isOn: $wear.quietOn).tint(StrandPalette.accent)
                    if wear.quietOn {
                        DatePicker("From", selection: Binding(get: { time(wear.quietStart) }, set: { wear.quietStart = minutes($0) }),
                                   displayedComponents: .hourAndMinute)
                        DatePicker("Until", selection: Binding(get: { time(wear.quietEnd) }, set: { wear.quietEnd = minutes($0) }),
                                   displayedComponents: .hourAndMinute)
                    }
                    Picker("When I open sfz", selection: $wear.onOpen) {
                        ForEach(SfzWearReminder.OpenBehaviour.allCases) { Text($0.label).tag($0) }
                    }
                    if wear.pausedUntilBack {
                        HStack {
                            Text("Paused until the band is back").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            Spacer()
                            Button("Resume") { wear.resume() }.font(StrandFont.caption)
                        }
                    } else if let s = wear.snoozedUntil, s > Date() {
                        HStack {
                            Text("Snoozed until \(s.formatted(date: .abbreviated, time: .shortened))")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            Spacer()
                            Button("Resume") { wear.resume() }.font(StrandFont.caption)
                        }
                    }
                    Text("Each reminder has Remind me again, Snooze 1 hour and Not today. Tap one for more choices.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
