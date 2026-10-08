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

/// The screen-time card body: today's use (drawn by the report extension) and whether the limit held.
struct SfzScreenCardBody: View {
    let habit: SfzHabit
    let status: SfzDayStatus

    var body: some View {
        let id = habit.id.uuidString
        let limit = habit.kind.format(habit.target(on: SfzHabitStore.today))
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if !SfzScreenShared.hasSelection(id) || !SfzScreenTime.isAuthorized {
                Spacer(minLength: 0)
                Text("Choose apps").font(StrandFont.title2).foregroundStyle(StrandPalette.accent)
                Text("Tap to pick \(habit.name) and set a daily limit.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            } else {
                if let f = SfzScreenTime.filter(id, days: 1) {
                    DeviceActivityReport(DeviceActivityReport.Context("sfzToday"), filter: f)
                        .frame(height: 46)
                }
                Spacer(minLength: 0)
                Text(status == .missed ? "Over \(limit): missed" : "Limit \(limit)")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(status == .missed ? StrandPalette.statusCritical : StrandPalette.textSecondary)
            }
        }
    }
}

/// On the habit page: choose the apps, see the recent average before setting a limit.
struct SfzScreenSetupSection: View {
    let habit: SfzHabit
    @State private var picking = false
    @State private var selection = FamilyActivitySelection()
    @State private var denied = false
    @State private var refresh = 0
    @State private var authorized = SfzScreenTime.isAuthorized

    var body: some View {
        let id = habit.id.uuidString
        let chosen = SfzScreenShared.selection(id)
        let count = (chosen?.applicationTokens.count ?? 0) + (chosen?.categoryTokens.count ?? 0) + (chosen?.webDomainTokens.count ?? 0)
        Section {
            if count > 0, SfzScreenTime.isAuthorized, let f = SfzScreenTime.filter(id, days: 14) {
                DeviceActivityReport(DeviceActivityReport.Context("sfzAverage"), filter: f)
                    .frame(height: 60)
                    .id(refresh)
            }
            if !authorized {
                // Step 1: iOS shows its own "Allow sfz to access Screen Time?" sheet right here,
                // confirmed with Face ID or the passcode. No trip to Settings.
                Button {
                    Task {
                        denied = false
                        authorized = await SfzScreenTime.authorize()
                        denied = !authorized
                        if authorized {
                            selection = SfzScreenShared.selection(id) ?? FamilyActivitySelection()
                            picking = true
                        }
                    }
                } label: {
                    Label("Allow Screen Time access", systemImage: "hourglass.badge.plus")
                }
            } else {
                // Step 2: Apple's app list. Search Instagram and tick it.
                Button(count > 0 ? "Change apps (\(count) chosen)" : "Choose apps") {
                    selection = SfzScreenShared.selection(id) ?? FamilyActivitySelection()
                    picking = true
                }
            }
            if denied {
                Text("iOS didn't allow it\(SfzScreenTime.lastError.map { ": \($0)" } ?? "."). Tap Allow again and confirm with Face ID or your passcode.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
            }
        } header: {
            Text("Apps")
        } footer: {
            Text(authorized
                 ? "Apple doesn't let apps choose Instagram for you. In Apple's list, search \"\(habit.name)\" and tick it. Your average shows above before you set the limit; going over the limit marks the day missed."
                 : "First allow Screen Time access. iOS asks right here; nothing to change in Settings.")
        }
        .familyActivityPicker(isPresented: $picking, selection: $selection)
        .onChange(of: selection) { _, sel in
            SfzScreenShared.setSelection(sel, for: id)
            SfzScreenTime.startMonitoring(habit)
            refresh += 1
        }
    }
}
