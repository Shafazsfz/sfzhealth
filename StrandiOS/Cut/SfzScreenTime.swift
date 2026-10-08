import SwiftUI
import FamilyControls
import DeviceActivity
import StrandDesign

/// sfz: Screen Time limits for habits like Instagram. You choose the apps in Apple's picker (Apple
/// never tells sfz which app is which, so it can't pre-select Instagram), sfz asks iOS to watch them
/// with a daily limit, and the monitor extension records any day the limit is passed.
@MainActor
enum SfzScreenTime {
    static var isAuthorized: Bool { AuthorizationCenter.shared.authorizationStatus == .approved }

    static func authorize() async -> Bool {
        if isAuthorized { return true }
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            return isAuthorized
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Why the last request failed, shown under the button.
    static var lastError: String?

    private static func watchingKey(_ id: String) -> String { "sfz.screen.watching.\(id)" }

    /// Watches the habit's apps every day with today's limit, counting what was already used today.
    static func startMonitoring(_ h: SfzHabit) {
        let id = h.id.uuidString
        guard let sel = SfzScreenShared.selection(id) else { return }
        let minutes = max(1, Int(h.target(on: SfzHabitStore.today)))
        SfzScreenShared.setLabel(h.name, limitMinutes: minutes, for: id)
        let schedule = DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                                              intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
                                              repeats: true)
        let event: DeviceActivityEvent
        if #available(iOS 17.4, *) {
            event = DeviceActivityEvent(applications: sel.applicationTokens, categories: sel.categoryTokens,
                                        webDomains: sel.webDomainTokens, threshold: DateComponents(minute: minutes),
                                        includesPastActivity: true)
        } else {
            event = DeviceActivityEvent(applications: sel.applicationTokens, categories: sel.categoryTokens,
                                        webDomains: sel.webDomainTokens, threshold: DateComponents(minute: minutes))
        }
        let center = DeviceActivityCenter()
        let name = SfzScreenShared.activityName(id)
        center.stopMonitoring([name])
        do {
            try center.startMonitoring(name, during: schedule, events: [SfzScreenShared.limitEvent: event])
            SfzScreenShared.setSince(SfzScreenShared.dayKey(), for: id)
            UserDefaults.standard.set(minutes, forKey: watchingKey(id))
        } catch {
            UserDefaults.standard.removeObject(forKey: watchingKey(id))
        }
    }

    /// Keeps every screen-time habit watched at today's limit and stops watching removed ones.
    static func sync(_ store: SfzHabitStore) {
        guard isAuthorized else { return }
        let center = DeviceActivityCenter()
        let live = Set(store.habits.filter { $0.kind == .screen }.map { $0.id.uuidString })
        let stale = center.activities.filter { a in
            guard let id = SfzScreenShared.habitId(from: a) else { return false }
            return !live.contains(id)
        }
        if !stale.isEmpty { center.stopMonitoring(stale) }
        for h in store.habits where h.kind == .screen && SfzScreenShared.hasSelection(h.id.uuidString) {
            let id = h.id.uuidString
            let minutes = max(1, Int(h.target(on: SfzHabitStore.today)))
            let watched = center.activities.contains(SfzScreenShared.activityName(id))
            if !watched || UserDefaults.standard.integer(forKey: watchingKey(id)) != minutes { startMonitoring(h) }
        }
    }

    /// Usage of the habit's apps over the last `days` days, one segment a day, for the report extension.
    static func filter(_ id: String, days: Int) -> DeviceActivityFilter? {
        guard let sel = SfzScreenShared.selection(id) else { return nil }
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date())) ?? Date()
        return DeviceActivityFilter(segment: .daily(during: DateInterval(start: start, end: Date())),
                                    users: .all, devices: .init([.iPhone]),
                                    applications: sel.applicationTokens, categories: sel.categoryTokens,
                                    webDomains: sel.webDomainTokens)
    }
}

/// Opens Settings at Screen Time so today's minutes can be read off; falls back to sfz's own settings.
@MainActor
func sfzOpenScreenTimeSettings() {
    guard let url = URL(string: "App-prefs:SCREEN_TIME") else { return }
    UIApplication.shared.open(url) { opened in
        if !opened, let fallback = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(fallback)
        }
    }
}

/// The screen-time card body. Automatic when iOS watches the apps (paid developer team); otherwise
/// you log the minutes from Screen Time with a tap or two.
struct SfzScreenCardBody: View {
    let habit: SfzHabit
    let status: SfzDayStatus
    @ObservedObject private var store = SfzHabitStore.shared

    private var automatic: Bool { SfzScreenTime.isAuthorized && SfzScreenShared.hasSelection(habit.id.uuidString) }

    var body: some View {
        let id = habit.id.uuidString
        let limitValue = habit.target(on: SfzHabitStore.today)
        let limit = habit.kind.format(limitValue)
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if automatic {
                if let f = SfzScreenTime.filter(id, days: 1) {
                    DeviceActivityReport(DeviceActivityReport.Context("sfzToday"), filter: f)
                        .frame(height: 46)
                }
                Spacer(minLength: 0)
                Text(status == .missed ? "Over \(limit): missed" : "Limit \(limit)")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(status == .missed ? StrandPalette.statusCritical : StrandPalette.textSecondary)
            } else {
                let used = store.entries(habit.id).reduce(0, +)
                let over = used > limitValue
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(habit.kind.format(used)).font(StrandFont.title2)
                        .foregroundStyle(over ? StrandPalette.statusCritical : StrandPalette.textPrimary)
                    Text("/ \(limit)").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StrandPalette.hairline)
                        Capsule().fill(over ? StrandPalette.statusCritical : StrandPalette.metricCyan)
                            .frame(width: used > 0 ? max(6, g.size.width * CGFloat(min(used / max(limitValue, 1), 1))) : 0)
                    }
                }
                .frame(height: 6)
                HStack(spacing: 6) {
                    ForEach([5, 15, 30], id: \.self) { m in
                        Button { store.log(habit.id, Double(m)) } label: {
                            Text("+\(m)m").font(StrandFont.caption.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(Capsule().fill(StrandPalette.accent.opacity(0.12)))
                                .foregroundStyle(StrandPalette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(over ? "Over the limit: missed" : "Under the limit")
                    .font(StrandFont.caption)
                    .foregroundStyle(over ? StrandPalette.statusCritical : StrandPalette.textTertiary)
            }
        }
    }
}

/// On the habit page: your average from the days you logged, today's total, and a shortcut to
/// Screen Time to read the number. Automatic tracking (paid developer team) shows Apple's own panel.
struct SfzScreenSetupSection: View {
    let habit: SfzHabit
    @ObservedObject private var store = SfzHabitStore.shared

    var body: some View {
        let id = habit.id.uuidString
        if SfzScreenTime.isAuthorized && SfzScreenShared.hasSelection(id), let f = SfzScreenTime.filter(id, days: 14) {
            Section("Your use") {
                DeviceActivityReport(DeviceActivityReport.Context("sfzAverage"), filter: f)
                    .frame(height: 60)
            }
        } else {
            Section {
                if let avg = store.loggedAverage(habit.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your average: \(habit.kind.format(avg.value)) a day").font(StrandFont.headline)
                        Text("From \(avg.count) logged day\(avg.count == 1 ? "" : "s") in the last two weeks")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                } else {
                    Text("Log a few days to see your average before you settle on a limit.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Stepper(value: Binding(get: { store.entries(habit.id).reduce(0, +) },
                                       set: { store.setTotal(habit.id, $0) }),
                        in: 0...900, step: 5) {
                    HStack {
                        Text("Today so far")
                        Spacer()
                        Text(habit.kind.format(store.entries(habit.id).reduce(0, +)))
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Button("Open Screen Time to check") { sfzOpenScreenTimeSettings() }
            } header: {
                Text("Today's \(habit.name) time")
            } footer: {
                Text("Read the minutes in Settings → Screen Time → See All App & Website Activity → \(habit.name), and enter them here. Going over your limit marks the day missed. Days with nothing logged don't count either way.")
            }
        }
    }
}
