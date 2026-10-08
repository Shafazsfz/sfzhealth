import Foundation
import FamilyControls
import DeviceActivity

/// sfz: what the app and its two Screen Time extensions share through the App Group.
///
/// Apple keeps Screen Time minutes inside its own processes: the app chooses apps with Apple's picker
/// (opaque tokens, never names or bundle ids), the monitor extension is woken when a daily limit is
/// passed and records that day here, and the report extension draws usage that the app can show but
/// never read. So "over the limit" is a fact the app can use; the minutes themselves only appear on screen.
public enum SfzScreenShared {
    public static let suiteName: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        if let alt = (info["ALTAppGroups"] as? [String])?.first(where: { $0.hasPrefix("group.") }) { return alt }
        return (info["AppGroupIdentifier"] as? String) ?? "group.noop.staging"
    }()

    public static var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    /// One monitored activity per screen-time habit.
    public static func activityName(_ habitId: String) -> DeviceActivityName { DeviceActivityName("sfz.screen.\(habitId)") }
    public static let limitEvent = DeviceActivityEvent.Name("limit")

    public static func habitId(from activity: DeviceActivityName) -> String? {
        let raw = activity.rawValue
        guard raw.hasPrefix("sfz.screen.") else { return nil }
        return String(raw.dropFirst("sfz.screen.".count))
    }

    public static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: Selection

    public static func selection(_ habitId: String) -> FamilyActivitySelection? {
        guard let data = defaults?.data(forKey: "sfz.screen.sel.\(habitId)") else { return nil }
        return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    public static func setSelection(_ sel: FamilyActivitySelection, for habitId: String) {
        if let data = try? JSONEncoder().encode(sel) { defaults?.set(data, forKey: "sfz.screen.sel.\(habitId)") }
    }

    public static func hasSelection(_ habitId: String) -> Bool {
        guard let s = selection(habitId) else { return false }
        return !s.applicationTokens.isEmpty || !s.categoryTokens.isEmpty || !s.webDomainTokens.isEmpty
    }

    // MARK: Days

    /// The first day the limit was watched; earlier days don't count.
    public static func since(_ habitId: String) -> String? { defaults?.string(forKey: "sfz.screen.since.\(habitId)") }

    public static func setSince(_ day: String, for habitId: String) {
        if since(habitId) == nil { defaults?.set(day, forKey: "sfz.screen.since.\(habitId)") }
    }

    public static func exceededDays(_ habitId: String) -> Set<String> {
        Set(defaults?.stringArray(forKey: "sfz.screen.over.\(habitId)") ?? [])
    }

    public static func markExceeded(_ habitId: String, day: String = dayKey()) {
        var days = exceededDays(habitId)
        days.insert(day)
        defaults?.set(Array(days).sorted(), forKey: "sfz.screen.over.\(habitId)")
    }

    /// The habit's name and limit, for the monitor's notification.
    public static func setLabel(_ name: String, limitMinutes: Int, for habitId: String) {
        defaults?.set(name, forKey: "sfz.screen.name.\(habitId)")
        defaults?.set(limitMinutes, forKey: "sfz.screen.limit.\(habitId)")
    }

    public static func label(_ habitId: String) -> (name: String, limit: Int) {
        (defaults?.string(forKey: "sfz.screen.name.\(habitId)") ?? "Screen time",
         defaults?.integer(forKey: "sfz.screen.limit.\(habitId)") ?? 0)
    }
}
