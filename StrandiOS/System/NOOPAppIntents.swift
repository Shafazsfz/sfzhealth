#if os(iOS)
import Foundation
import AppIntents
import WhoopStore

/// Queue of actions requested by an App Intent while the app may be suspended. Intents can't reach
/// into the running `AppModel` directly (BLE only lives in the foreground app), so they enqueue here
/// and the app drains the queue when it next becomes active.
enum PendingIntents {
    enum Action: String { case markMoment, buzz, askCoach }

    private static let key = "noop.pendingIntents"
    /// K9: the question text for a pending `.askCoach` action. Stored separately because the
    /// action queue encodes as `[String]` and a question can contain colons.
    private static let coachQuestionKey = "noop.pendingCoachQuestion"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: WidgetSnapshot.suiteName) }

    /// Optional `at` is the invocation time, captured now and consumed on drain. Encoded into the
    /// stored string as "rawValue:epochSeconds" so the array stays a plain [String] (no schema
    /// migration; a legacy bare "markMoment" still decodes with a nil date).
    static func append(_ action: Action, at date: Date? = nil) {
        guard let d = defaults else { return }
        var list = d.stringArray(forKey: key) ?? []
        if let date { list.append("\(action.rawValue):\(date.timeIntervalSince1970)") }
        else { list.append(action.rawValue) }
        d.set(list, forKey: key)
    }

    /// K9: queue an "Ask Coach" action with the associated question text. The question is stored
    /// in a dedicated key (one pending question at a time — the user rarely queues multiple Siri
    /// questions before the app opens).
    static func appendAskCoach(question: String, at date: Date? = nil) {
        guard let d = defaults else { return }
        d.set(question, forKey: coachQuestionKey)
        append(.askCoach, at: date)
    }

    /// K9: read and clear the pending coach question. Returns nil when no question is queued.
    static func consumeCoachQuestion() -> String? {
        guard let d = defaults else { return nil }
        let q = d.string(forKey: coachQuestionKey)
        d.removeObject(forKey: coachQuestionKey)
        return q
    }

    static func drain() -> [(action: Action, date: Date?)] {
        guard let d = defaults else { return [] }
        let raw = d.stringArray(forKey: key) ?? []
        d.removeObject(forKey: key)
        return raw.compactMap { entry in
            // Guard `parts.first` rather than subscripting `parts[0]`: split(omittingEmptySubsequences:
            // true by default) returns an EMPTY array for an empty or ":"-leading entry, and indexing
            // [0] there is a fatal trap. This value comes from shared App Group defaults read untrusted,
            // so a corrupt/foreign entry must be skipped, not crash the app on foreground.
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard let first = parts.first, let action = Action(rawValue: String(first)) else { return nil }
            let date = parts.count == 2 ? Double(parts[1]).map { Date(timeIntervalSince1970: $0) } : nil
            return (action, date)
        }
    }
}

/// Record a timestamped "moment" — the iOS analogue of the strap double-tap "mark a moment" action.
struct MarkMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "Mark a Moment"
    static var description = IntentDescription("Record a timestamped moment in Sfz Health.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingIntents.append(.markMoment, at: Date())
        return .result(dialog: "Moment marked.")
    }
}

/// Send a confirming haptic buzz to the strap. Opens the app so the live BLE link can deliver it.
struct BuzzStrapIntent: AppIntent {
    static var title: LocalizedStringResource = "Buzz Strap"
    static var description = IntentDescription("Send a haptic buzz to your WHOOP strap.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingIntents.append(.buzz)
        return .result()
    }
}

/// Pull the strap's stored history now: the Shortcuts twin of the "Sync now" button, run WITHOUT opening NOOP.
/// iOS runs an in-app intent inside NOOP's own process (launching or resuming it in the background), where the
/// strap link lives under the bluetooth-central background mode, so the offload carries on after this returns.
/// The spoken/shown reply reports only what this path observed about the sync starting.
///
/// `LiveActivityIntent`, not plain `AppIntent`: that is what lets it START the strap-sync Live Activity
/// (the Dynamic Island "Connecting… / Syncing… N chunks" readout) from the background. A plain intent
/// running in a background-launched app is refused by ActivityKit.
struct SyncStrapIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Sync Strap"
    static var description = IntentDescription("Pull your WHOOP strap's stored history into Sfz Health now.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await AppModel.startStrapSyncFromShortcut() {
        case .started:               return .result(dialog: "Syncing your strap.")
        case .alreadyRunning:        return .result(dialog: "Your strap is already syncing.")
        case .willSyncWhenConnected: return .result(dialog: "Sfz Health is connecting to your strap and will sync as soon as it's ready.")
        case .strapNotReady:         return .result(dialog: "Your strap isn't connected to Sfz Health yet, so the sync didn't start.")
        case .notStarted:            return .result(dialog: "Sfz Health couldn't start the sync. Open Sfz Health to see the strap log.")
        }
    }
}

/// K9: Ask the Coach a question via Siri. Queues the question and opens the app, which sends it
/// to the configured provider and surfaces the response. The question is spoken or typed in Siri;
/// the app handles the actual network call using the user's saved key.
struct AskCoachIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Coach"
    static var description = IntentDescription("Ask your Sfz Health Coach a question about your recovery, sleep, or training.")
    static var openAppWhenRun = true

    /// The question to ask, populated by Siri from the user's spoken phrase.
    @Parameter(title: "Question")
    var question: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        PendingIntents.appendAskCoach(question: question, at: Date())
        return .result(dialog: "Opening Coach with your question: \(question)")
    }
}

/// Surfaces NOOP's intents to Siri, Spotlight, and the Shortcuts gallery without any user setup.
struct NOOPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncStrapIntent(),
                    phrases: [
                        "Sync my \(.applicationName) strap",
                        "Sync \(.applicationName)",
                    ],
                    shortTitle: "Sync Strap",
                    systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: MarkMomentIntent(),
                    phrases: ["Mark a moment in \(.applicationName)"],
                    shortTitle: "Mark a Moment",
                    systemImageName: "mappin.and.ellipse")
        AppShortcut(intent: BuzzStrapIntent(),
                    phrases: ["Buzz my \(.applicationName) strap"],
                    shortTitle: "Buzz Strap",
                    systemImageName: "waveform.path")
        // K9: "Ask Coach" via Siri — opens Coach with the question and sends it. The question
        // parameter is provided via the Shortcuts app or Siri prompts for it when the phrase fires.
        AppShortcut(intent: AskCoachIntent(),
                    phrases: [
                        "Ask \(.applicationName) about my recovery",
                        "Ask \(.applicationName) how I'm doing",
                        "Ask \(.applicationName) Coach",
                    ],
                    shortTitle: "Ask Coach",
                    systemImageName: "sparkles")
    }
}

// MARK: - sfz: values for a "Log Health Sample" Shortcut

/// A sideloaded (SideStore) install has no HealthKit entitlement, so sfz can't write to Apple Health
/// itself. These intents hand sfz's numbers to the Shortcuts app instead, whose own "Log Health
/// Sample" action writes them into Health. One daily automation does the whole job.
enum SfzHealthMetric: String, AppEnum {
    case restingHeartRate, heartRateVariability, bloodOxygen, respiratoryRate, sleepHours,
         steps, activeCalories, water, weight, dietaryCalories, protein

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Health value"
    static var caseDisplayRepresentations: [SfzHealthMetric: DisplayRepresentation] = [
        .restingHeartRate: "Resting heart rate (bpm)",
        .heartRateVariability: "Heart rate variability (ms)",
        .bloodOxygen: "Blood oxygen (%)",
        .respiratoryRate: "Respiratory rate (breaths/min)",
        .sleepHours: "Sleep (hours)",
        .steps: "Steps",
        .activeCalories: "Active calories (kcal)",
        .water: "Water (ml)",
        .weight: "Weight (kg)",
        .dietaryCalories: "Food calories (kcal)",
        .protein: "Protein (g)"
    ]

    /// Night readings come from the latest scored night; day totals from the last complete day.
    var isNightly: Bool {
        switch self {
        case .restingHeartRate, .heartRateVariability, .bloodOxygen, .respiratoryRate, .sleepHours, .weight: return true
        default: return false
        }
    }
}

enum SfzHealthDay: String, AppEnum {
    case automatic, today, yesterday
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Day"
    static var caseDisplayRepresentations: [SfzHealthDay: DisplayRepresentation] = [
        .automatic: "Automatic (last night / yesterday)",
        .today: "Today",
        .yesterday: "Yesterday"
    ]
}

struct SfzIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

struct GetSfzHealthValueIntent: AppIntent {
    static var title: LocalizedStringResource = "Get sfz Health Value"
    static var description = IntentDescription("Get a number from sfz, such as resting heart rate or steps, to log into Apple Health with Log Health Sample.")
    static var openAppWhenRun = false

    @Parameter(title: "Value", default: .restingHeartRate)
    var metric: SfzHealthMetric

    @Parameter(title: "Day", default: .automatic)
    var day: SfzHealthDay

    static var parameterSummary: some ParameterSummary {
        Summary("Get sfz \(\.$metric) for \(\.$day)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        guard let model = AppModel.shared else { throw SfzIntentError(message: "Open sfz once, then run this again.") }
        let repo = model.repo
        if repo.days.isEmpty { await repo.refresh() }
        let cal = Calendar.current
        let todayKey = Repository.localDayKey(Date())
        let yesterdayKey = Repository.localDayKey(cal.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        let dayKey: String
        switch day {
        case .today: dayKey = todayKey
        case .yesterday: dayKey = yesterdayKey
        case .automatic: dayKey = metric.isNightly ? todayKey : yesterdayKey
        }
        // Night readings: the requested night, or (automatic) the latest of the last two.
        func night<T>(_ pick: (DailyMetric) -> T?) -> T? {
            if day == .automatic {
                for k in [todayKey, yesterdayKey] {
                    if let d = repo.days.last(where: { $0.day == k }), let v = pick(d) { return v }
                }
                return nil
            }
            return repo.days.last(where: { $0.day == dayKey }).flatMap(pick)
        }
        let row = repo.days.last(where: { $0.day == dayKey })
        let plan = CutPlanStore.shared
        var value: Double?
        switch metric {
        case .restingHeartRate: value = night { $0.restingHr.map(Double.init) }
        case .heartRateVariability: value = night { $0.avgHrv }
        case .bloodOxygen: value = night { $0.spo2Pct }
        case .respiratoryRate: value = night { $0.respRateBpm }
        case .sleepHours: value = night { $0.totalSleepMin.map { $0 / 60 } }
        case .steps: value = row?.steps.map(Double.init)
        case .activeCalories: value = row?.activeKcalEst
        case .water:
            let ml = await repo.hydrationTotal(day: dayKey)
            value = ml > 0 ? ml : nil
        case .weight: value = plan.weighIns.max(by: { $0.at < $1.at })?.kg
        case .dietaryCalories:
            let kcal = plan.logged(day: dayKey)
            value = kcal > 0 ? Double(kcal) : nil
        case .protein:
            let g = plan.entries(day: dayKey).compactMap(\.protein).reduce(0, +)
            value = g > 0 ? g : nil
        }
        guard let v = value else {
            let name = SfzHealthMetric.caseDisplayRepresentations[metric]?.title ?? "That value"
            throw SfzIntentError(message: "sfz has no \(name) for that day yet.")
        }
        let rounded = (v * 10).rounded() / 10
        return .result(value: rounded, dialog: "\(rounded)")
    }
}

enum SfzSleepEdge: String, AppEnum {
    case start, end
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sleep time"
    static var caseDisplayRepresentations: [SfzSleepEdge: DisplayRepresentation] = [
        .start: "Fell asleep", .end: "Woke up"
    ]
}

struct GetSfzSleepTimeIntent: AppIntent {
    static var title: LocalizedStringResource = "Get sfz Sleep Time"
    static var description = IntentDescription("When you fell asleep or woke up last night, for logging Sleep in Apple Health.")
    static var openAppWhenRun = false

    @Parameter(title: "Time", default: .start)
    var edge: SfzSleepEdge

    static var parameterSummary: some ParameterSummary {
        Summary("Get sfz \(\.$edge) time")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Date> {
        guard let model = AppModel.shared else { throw SfzIntentError(message: "Open sfz once, then run this again.") }
        let repo = model.repo
        if repo.sleeps.isEmpty { await repo.refresh() }
        let since = Int(Date().addingTimeInterval(-30 * 3600).timeIntervalSince1970)
        // The main sleep: the longest session that ended in the last ~30 hours.
        guard let s = repo.sleeps.filter({ $0.endTs >= since })
                .max(by: { ($0.endTs - $0.startTs) < ($1.endTs - $1.startTs) }) else {
            throw SfzIntentError(message: "sfz has no sleep from last night yet.")
        }
        let ts = edge == .start ? s.startTs : s.endTs
        return .result(value: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
#endif
