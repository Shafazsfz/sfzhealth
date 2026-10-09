import Foundation
import Combine
#if os(iOS)
import HealthKit
import UserNotifications
import WidgetKit
#endif

/// Personal weight-loss plan: goal, daily deficit, a per-day food log and weigh-ins.
/// Everything lives in UserDefaults on this device, like `ProfileStore`.
@MainActor
final class CutPlanStore: ObservableObject {
    static let shared = CutPlanStore()

    struct FoodEntry: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var kcal: Int
        var at: Date
        /// Grams of protein; nil when not entered (entries from before protein tracking decode as nil).
        var protein: Double?
        /// sfz: grams of carbohydrate and fat; optional, and nil for entries logged before they existed.
        var carbs: Double? = nil
        var fat: Double? = nil

        /// "450 kcal · 30 g P · 40 g C · 15 g F", leaving out anything not entered.
        var summary: String {
            var parts = ["\(kcal) kcal"]
            if let p = protein { parts.append("\(Int(p.rounded())) g P") }
            if let c = carbs { parts.append("\(Int(c.rounded())) g C") }
            if let f = fat { parts.append("\(Int(f.rounded())) g F") }
            return parts.joined(separator: " · ")
        }
    }

    struct WeighIn: Codable, Identifiable, Equatable {
        var id = UUID()
        var kg: Double
        var at: Date
    }

    @Published var configured: Bool { didSet { d.set(configured, forKey: K.configured) } }
    @Published var startKg: Double { didSet { d.set(startKg, forKey: K.startKg) } }
    /// Local day key the plan (and `startKg`) started on; expected weight counts from here.
    @Published var startDay: String { didSet { d.set(startDay, forKey: K.startDay) } }
    @Published var goalKg: Double { didSet { d.set(goalKg, forKey: K.goalKg) } }
    /// The date the goal weight should be reached. The daily deficit is derived from it (and the current
    /// weight), so the allowance re-plans itself every day.
    @Published var targetDate: Date { didSet { d.set(targetDate, forKey: K.targetDate) } }
    /// Share of the daily deficit planned as workout burn; the rest comes off the food allowance.
    @Published var workoutShare: Double { didSet { d.set(workoutShare, forKey: K.workoutShare) } }
    /// Share of workout calories BEYOND the day's workout target added back to the allowance.
    /// Heart-rate estimates run high, so only half is eaten back by default.
    @Published var workoutEatBack: Double { didSet { d.set(workoutEatBack, forKey: K.eatBack) } }
    /// Under-logging allowance: every logged kcal counts this much extra (0.10 = +10%) in the budget,
    /// the fat math and expected weight. Logged entries themselves are stored as typed.
    @Published var logBuffer: Double { didSet { d.set(logBuffer, forKey: K.logBuffer) } }
    /// Daily protein target in grams per kg of GOAL weight (2.0 = 150 g at 75 kg).
    @Published var proteinPerKg: Double { didSet { d.set(proteinPerKg, forKey: K.proteinPerKg) } }
    /// sfz: weekly targets for the "This week" card: workout minutes and days with a workout.
    @Published var weeklyCardioTarget: Int { didSet { d.set(weeklyCardioTarget, forKey: K.weeklyCardio) } }
    @Published var exerciseDaysTarget: Int { didSet { d.set(exerciseDaysTarget, forKey: K.exerciseDays) } }
    /// Food log keyed by local day key (`yyyy-MM-dd`).
    @Published private(set) var food: [String: [FoodEntry]] { didSet { save(food, K.food) } }
    @Published private(set) var weighIns: [WeighIn] { didSet { save(weighIns, K.weighIns) } }
    /// Strap-measured workout (active) kcal per local day. Past days are computed once from the
    /// full day's heart rate; today is refreshed as the day goes on.
    @Published private(set) var activeByDay: [String: Double] { didSet { save(activeByDay, K.active) } }

    private let d = UserDefaults.standard
    private enum K {
        static let configured = "cut.configured", startKg = "cut.startKg", goalKg = "cut.goalKg"
        static let startDay = "cut.startDay", logBuffer = "cut.logBuffer", proteinPerKg = "cut.proteinPerKg"
        static let deficit = "cut.dailyDeficit", targetDate = "cut.targetDate", workoutShare = "cut.workoutShare", eatBack = "cut.workoutEatBack"
        static let food = "cut.food", weighIns = "cut.weighIns", active = "cut.activeByDay"
        static let weeklyCardio = "cut.weeklyCardioMin", exerciseDays = "cut.exerciseDaysTarget"
    }

    private init() {
        configured = d.bool(forKey: K.configured)
        startKg = d.object(forKey: K.startKg) as? Double ?? 83.3
        goalKg = d.object(forKey: K.goalKg) as? Double ?? 75
        // A saved date wins; otherwise the date the stored pace (default 500 kcal/day) reaches the goal.
        let pace = Double(d.object(forKey: K.deficit) as? Int ?? 500)
        let seedDays = max((d.object(forKey: K.startKg) as? Double ?? 83.3) - (d.object(forKey: K.goalKg) as? Double ?? 75), 0)
            * Self.kcalPerKgFat / max(pace, 1)
        targetDate = d.object(forKey: K.targetDate) as? Date
            ?? Calendar.current.date(byAdding: .day, value: Int(seedDays.rounded(.up)), to: Date()) ?? Date()
        workoutShare = d.object(forKey: K.workoutShare) as? Double ?? 0.3
        workoutEatBack = d.object(forKey: K.eatBack) as? Double ?? 0.5
        logBuffer = d.object(forKey: K.logBuffer) as? Double ?? 0.10
        proteinPerKg = d.object(forKey: K.proteinPerKg) as? Double ?? 2.0
        weeklyCardioTarget = d.object(forKey: K.weeklyCardio) as? Int ?? 150
        exerciseDaysTarget = d.object(forKey: K.exerciseDays) as? Int ?? 5
        let loadedFood: [String: [FoodEntry]] = Self.load(d, K.food) ?? [:]
        food = loadedFood
        weighIns = Self.load(d, K.weighIns) ?? []
        activeByDay = Self.load(d, K.active) ?? [:]
        // Installs from before start days: the first day with food logged, else today.
        let today = Repository.localDayKey(Date())
        startDay = d.string(forKey: K.startDay)
            ?? loadedFood.filter { !$0.value.isEmpty }.keys.min() ?? today
        if d.string(forKey: K.startDay) == nil { d.set(startDay, forKey: K.startDay) }
        // didSet does not fire in init; pin a derived date so it doesn't slide forward each launch.
        if d.object(forKey: K.targetDate) == nil { d.set(targetDate, forKey: K.targetDate) }
        // sfz: food logged before Apple Health writing existed goes in once, so Health has the full log.
        let backfillKey = "sfz.health.foodBackfilled"
        if !d.bool(forKey: backfillKey) {
            let all = loadedFood.values.flatMap { $0 }
            if !all.isEmpty {
                Task { if await SfzHealthWriter.saveFoods(all) { UserDefaults.standard.set(true, forKey: backfillKey) } }
            } else {
                d.set(true, forKey: backfillKey)
            }
        }
    }

    func setActive(_ kcal: Double, day: String) {
        if activeByDay[day] != kcal { activeByDay[day] = kcal }
    }

    /// Days that have at least one food entry, i.e. days a deficit can honestly be computed for.
    var loggedDays: [String] { food.keys.filter { !(food[$0]?.isEmpty ?? true) }.sorted() }

    // MARK: Food

    func entries(day: String) -> [FoodEntry] { (food[day] ?? []).sorted { $0.at < $1.at } }
    /// Calories as typed.
    func logged(day: String) -> Int { (food[day] ?? []).reduce(0) { $0 + $1.kcal } }
    /// Calories as counted everywhere: logged plus the under-logging buffer.
    func eaten(day: String) -> Double { Double(logged(day: day)) * (1 + logBuffer) }

    func addFood(name: String, kcal: Int, protein: Double? = nil, carbs: Double? = nil, fat: Double? = nil,
                 day: String) {
        guard kcal > 0 else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = FoodEntry(name: trimmed.isEmpty ? "Food" : trimmed, kcal: kcal, at: Date(),
                              protein: protein.flatMap { $0 > 0 ? $0 : nil },
                              carbs: carbs.flatMap { $0 > 0 ? $0 : nil },
                              fat: fat.flatMap { $0 > 0 ? $0 : nil })
        food[day, default: []].append(entry)
        SfzHealthWriter.saveFood(entry)   // sfz: also into Apple Health (Google Health reads it from there)
    }

    /// Protein logged for the day, grams (as typed; the calorie buffer does not apply).
    func protein(day: String) -> Double { (food[day] ?? []).reduce(0) { $0 + ($1.protein ?? 0) } }

    /// Daily protein target, grams.
    var proteinTarget: Double { goalKg * proteinPerKg }

    func removeFood(_ id: UUID, day: String) {
        SfzHealthWriter.deleteFood(id: id)   // sfz: remove the matching Apple Health samples too
        food[day]?.removeAll { $0.id == id }
        if food[day]?.isEmpty == true { food[day] = nil }
    }

    /// Distinct recent foods (newest first) for one-tap re-adding.
    func recentFoods(limit: Int = 6) -> [FoodEntry] {
        var seen = Set<String>()
        return food.values.flatMap { $0 }.sorted { $0.at > $1.at }.filter {
            seen.insert("\($0.name.lowercased())|\($0.kcal)|\($0.protein ?? 0)|\($0.carbs ?? 0)|\($0.fat ?? 0)").inserted
        }.prefix(limit).map { $0 }
    }

    // MARK: Weight

    func logWeight(_ kg: Double) {
        guard kg > 0 else { return }
        let w = WeighIn(kg: kg, at: Date())
        weighIns.append(w)
        SfzHealthWriter.saveWeight(kg: kg, at: w.at, id: w.id)   // sfz: also into Apple Health
    }

    // MARK: Math (Mifflin–St Jeor)

    struct Budget: Equatable {
        let bmr: Double
        let maintenance: Double      // sedentary maintenance, before workouts
        let requiredDeficit: Double  // kcal/day needed to reach the goal weight by the target date
        let floorHit: Bool           // food would go below the safe floor; the rest moved to workouts
        let foodCut: Double          // part of the deficit taken off food
        let workoutTarget: Double    // part of the deficit to burn in workouts
        let workoutDone: Double      // strap-measured active kcal so far today
        let workoutBonus: Double     // eaten back from workouts beyond the target
        let allowance: Double
        let eaten: Double
        var remaining: Double { allowance - eaten }
        var kgPerWeek: Double { requiredDeficit * 7 / CutPlanStore.kcalPerKgFat }
    }

    static func bmr(weightKg: Double, heightCm: Double, age: Int, male: Bool) -> Double {
        10 * weightKg + 6.25 * heightCm - 5 * Double(age) + (male ? 5 : -161)
    }

    func budget(weightKg: Double, heightCm: Double, age: Int, male: Bool,
                activeKcal: Double, eaten: Double, goalKg goalOverride: Double? = nil,
                targetDate dateOverride: Date? = nil, workoutShare shareOverride: Double? = nil) -> Budget {
        let bmr = Self.bmr(weightKg: weightKg, heightCm: heightCm, age: age, male: male)
        let maintenance = bmr * 1.2
        let deficit = Self.requiredDeficit(weightKg: weightKg, goalKg: goalOverride ?? goalKg,
                                           by: dateOverride ?? targetDate)
        let share = min(max(shareOverride ?? workoutShare, 0), 1)
        // Never plan food below a safe floor; whatever the floor blocks moves onto the workout target.
        let floor: Double = male ? 1500 : 1200
        let wantedCut = deficit * (1 - share)
        let foodCut = max(0, min(wantedCut, maintenance - floor))
        let workoutTarget = deficit - foodCut
        let active = max(0, activeKcal)
        let bonus = max(0, active - workoutTarget) * workoutEatBack
        return Budget(bmr: bmr, maintenance: maintenance, requiredDeficit: deficit, floorHit: wantedCut > foodCut + 0.5, foodCut: foodCut,
                      workoutTarget: workoutTarget, workoutDone: active, workoutBonus: bonus,
                      allowance: maintenance - foodCut + bonus, eaten: eaten)
    }

    /// Estimated weight at the START of `today`, for someone without a scale. Anchored on the latest
    /// weigh-in if there is one (from that day on), else `startKg` from `startDay`. Walks each logged day
    /// in order, recomputing maintenance at the weight reached so far, so the burn falls as weight does.
    /// Days with no food logged are skipped (no deficit assumed). Returns the kg and the days counted.
    func estimatedKg(beforeDay today: String, heightCm: Double, age: Int, male: Bool) -> (kg: Double, days: Int) {
        var kg = startKg, from = startDay
        if let last = weighIns.max(by: { $0.at < $1.at }) {
            let day = Repository.localDayKey(last.at)
            if day >= startDay { kg = last.kg; from = day }
        }
        var n = 0
        for k in loggedDays where k >= from && k < today {
            let maintenance = Self.bmr(weightKg: kg, heightCm: heightCm, age: age, male: male) * 1.2
            kg -= (dayBurn(maintenance: maintenance, activeKcal: activeByDay[k] ?? 0) - eaten(day: k)) / Self.kcalPerKgFat
            n += 1
        }
        return (kg, n)
    }

    /// Daily deficit to go from `weightKg` to `goalKg` by `date` (0 once the goal is reached).
    static func requiredDeficit(weightKg: Double, goalKg: Double, by date: Date, now: Date = Date()) -> Double {
        let cal = Calendar.current
        let days = max(1, cal.dateComponents([.day], from: cal.startOfDay(for: now),
                                             to: cal.startOfDay(for: date)).day ?? 1)
        return max(0, weightKg - goalKg) * kcalPerKgFat / Double(days)
    }

    /// Predicted date the goal is reached if the average daily deficit continues. nil when not losing.
    func projectedGoalDate(currentKg: Double, avgDailyDeficit: Double, from now: Date = Date()) -> Date? {
        let toLose = currentKg - goalKg
        guard toLose > 0, avgDailyDeficit > 0 else { return nil }
        let days = toLose * Self.kcalPerKgFat / avgDailyDeficit
        return Calendar.current.date(byAdding: .day, value: Int(days.rounded(.up)), to: now)
    }

    /// Energy in one kilogram of body fat (the common ~7,700 kcal rule of thumb).
    static let kcalPerKgFat: Double = 7700

    /// Full-day burn estimate: sedentary maintenance plus ALL strap-measured workout energy.
    func dayBurn(maintenance: Double, activeKcal: Double) -> Double { maintenance + max(0, activeKcal) }

    // MARK: Persistence

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ d: UserDefaults, _ key: String) -> T? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}


// MARK: - sfz: Apple Health writes for food and mindful minutes

#if os(iOS)
/// Writes sfz's own logs into Apple Health so other apps (Google Health, Fitness) see them:
/// food from the Goal page (calories, protein, carbs, fat) and Breathe sessions (mindful minutes).
/// Every food sample carries `HKMetadataKeyExternalUUID = "sfz:food:<entry id>"`, which is how a
/// removed entry's samples are found and deleted. Failures are silent: the in-app log is the source
/// of truth and nothing here blocks it.
enum SfzHealthWriter {
    private static let store = HKHealthStore()

    private static let energy = HKQuantityType(.dietaryEnergyConsumed)
    private static let protein = HKQuantityType(.dietaryProtein)
    private static let carbs = HKQuantityType(.dietaryCarbohydrates)
    private static let fat = HKQuantityType(.dietaryFatTotal)
    private static let mindful = HKCategoryType(.mindfulSession)
    private static var foodTypes: Set<HKSampleType> { [energy, protein, carbs, fat] }

    /// Asks once for the share types it needs (iOS only prompts for ones never asked about) and
    /// reports whether calories, the one always written, may be saved.
    private static func authorized(_ types: Set<HKSampleType>, key: HKSampleType) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do { try await store.requestAuthorization(toShare: types, read: []) } catch { return false }
        return store.authorizationStatus(for: key) == .sharingAuthorized
    }

    private static func externalKey(_ id: UUID) -> String { "sfz:food:\(id.uuidString)" }

    private static func samples(for e: CutPlanStore.FoodEntry) -> [HKQuantitySample] {
        let meta: [String: Any] = [HKMetadataKeyExternalUUID: externalKey(e.id), HKMetadataKeyFoodType: e.name]
        func sample(_ t: HKQuantityType, _ unit: HKUnit, _ v: Double) -> HKQuantitySample? {
            guard store.authorizationStatus(for: t) == .sharingAuthorized, v > 0 else { return nil }
            return HKQuantitySample(type: t, quantity: HKQuantity(unit: unit, doubleValue: v),
                                    start: e.at, end: e.at, metadata: meta)
        }
        return [sample(energy, .kilocalorie(), Double(e.kcal)),
                e.protein.flatMap { sample(protein, .gram(), $0) },
                e.carbs.flatMap { sample(carbs, .gram(), $0) },
                e.fat.flatMap { sample(fat, .gram(), $0) }].compactMap { $0 }
    }

    static func saveFood(_ e: CutPlanStore.FoodEntry) {
        Task { _ = await saveFoods([e]) }
    }

    /// Returns true when the samples were saved (or there was nothing to save).
    @discardableResult
    static func saveFoods(_ entries: [CutPlanStore.FoodEntry]) async -> Bool {
        guard await authorized(foodTypes, key: energy) else { return false }
        let all = entries.flatMap { samples(for: $0) }
        guard !all.isEmpty else { return true }
        do { try await store.save(all); return true } catch { return false }
    }

    static func deleteFood(id: UUID) {
        Task {
            let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID,
                                                        allowedValues: [externalKey(id)])
            for t in [energy, protein, carbs, fat] where store.authorizationStatus(for: t) == .sharingAuthorized {
                _ = try? await store.deleteObjects(of: t, predicate: predicate)
            }
        }
    }

    // MARK: sfz: water and weight

    private static let water = HKQuantityType(.dietaryWater)
    private static let bodyMass = HKQuantityType(.bodyMass)

    /// A weigh-in from the Goal page as body weight.
    static func saveWeight(kg: Double, at: Date, id: UUID) {
        Task {
            guard await authorized([bodyMass], key: bodyMass) else { return }
            let sample = HKQuantitySample(type: bodyMass,
                                          quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg),
                                          start: at, end: at,
                                          metadata: [HKMetadataKeyExternalUUID: "sfz:weight:\(id.uuidString)"])
            try? await store.save(sample)
        }
    }

    /// Mirrors one day's logged drinks into Health: this app's water samples for the day are replaced
    /// with one sample per drink, so an edit or delete in sfz is reflected too. Water from other apps is
    /// never touched (the delete is scoped to this app's own samples).
    static func syncWater(day: String, entries: [HydrationEntry]) {
        Task {
            guard await authorized([water], key: water) else { return }
            let tag = "sfz:water:\(day)"
            // This app's own water samples within ±2 days of the day, then keep only this day's tag.
            let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"
            let dayDate = f.date(from: day) ?? Date()
            let from = dayDate.addingTimeInterval(-2 * 86400), to = dayDate.addingTimeInterval(3 * 86400)
            let mine = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForObjects(from: HKSource.default()),
                HKQuery.predicateForSamples(withStart: from, end: to, options: [])
            ])
            let old: [HKSample] = await withCheckedContinuation { cont in
                let q = HKSampleQuery(sampleType: water, predicate: mine, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, samples, _ in cont.resume(returning: samples ?? []) }
                store.execute(q)
            }
            let tagged = old.filter { (($0.metadata?[HKMetadataKeyExternalUUID] as? String) ?? "").hasPrefix(tag) }
            if !tagged.isEmpty { try? await store.delete(tagged) }
            let samples = entries.filter { $0.amountMl > 0 }.map { e in
                HKQuantitySample(type: water,
                                 quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: Double(e.amountMl)),
                                 start: e.loggedAt, end: e.loggedAt,
                                 metadata: [HKMetadataKeyExternalUUID: "\(tag):\(e.id.uuidString)"])
            }
            guard !samples.isEmpty else { return }
            try? await store.save(samples)
        }
    }

    /// A Breathe session as mindful minutes. Sessions under a minute are not saved.
    static func saveMindful(start: Date, end: Date) {
        guard end.timeIntervalSince(start) >= 60 else { return }
        Task {
            guard await authorized([mindful], key: mindful) else { return }
            let sample = HKCategorySample(type: mindful, value: HKCategoryValue.notApplicable.rawValue,
                                          start: start, end: end)
            try? await store.save(sample)
        }
    }
}
#endif


// MARK: - sfz: Habits and challenges

/// What a habit measures and how it is logged.
enum SfzHabitKind: String, Codable, CaseIterable, Identifiable {
    case counter, timer, check, gym, steps, water, sleep, zone, protein, screen, calories, burn
    var id: String { rawValue }
    /// Filled from the WHOOP, the iPhone or other logs; never tapped.
    var isAuto: Bool { [.steps, .water, .sleep, .zone, .protein, .screen, .calories, .burn].contains(self) }
    var label: String {
        switch self {
        case .counter: return "Counter"
        case .timer: return "Timer"
        case .check: return "Yes / No"
        case .gym: return "Gym (done / skipped / rest)"
        case .steps: return "Steps (automatic)"
        case .water: return "Water (from your water log)"
        case .sleep: return "Sleep (from your WHOOP)"
        case .zone: return "Active Zone Minutes (from your WHOOP)"
        case .protein: return "Protein (from your food log)"
        case .screen: return "Screen time limit"
        case .calories: return "Calories within your daily target (from Goal)"
        case .burn: return "Workout calories burned (from your WHOOP and Goal)"
        }
    }
    /// Counter: reps. Timer: seconds. Check and gym: 1. Water: ml. Sleep: minutes. Zone: minutes. Protein: g.
    var defaultTarget: Double {
        switch self {
        case .counter: return 50
        case .timer: return 60
        case .check, .gym: return 1
        case .steps: return 10_000
        case .water: return 3_000
        case .sleep: return 480
        case .zone: return 30
        case .protein: return 120
        case .screen: return 30
        case .calories, .burn: return 1
        }
    }
    var defaultIcon: String {
        switch self {
        case .counter: return "number"
        case .timer: return "timer"
        case .check: return "checkmark.circle"
        case .gym: return "dumbbell"
        case .steps: return "figure.walk"
        case .water: return "drop"
        case .sleep: return "bed.double"
        case .zone: return "heart"
        case .protein: return "fork.knife"
        case .screen: return "hourglass"
        case .calories: return "fork.knife.circle"
        case .burn: return "flame"
        }
    }
    /// Target stepper: range and step, in stored units.
    var targetRange: ClosedRange<Double> {
        switch self {
        case .counter: return 1...1000
        case .timer: return 10...7200
        case .check, .gym: return 1...1
        case .steps: return 1000...50_000
        case .water: return 250...6000
        case .sleep: return 240...720
        case .zone: return 5...300
        case .protein: return 20...400
        case .screen: return 5...600
        case .calories, .burn: return 1...1
        }
    }
    var targetStep: Double {
        switch self {
        case .counter: return 5
        case .timer: return 15
        case .check, .gym: return 1
        case .steps: return 500
        case .water: return 250
        case .sleep: return 15
        case .zone: return 5
        case .protein: return 5
        case .screen: return 5
        case .calories, .burn: return 1
        }
    }
    /// Calories take their target from the Goal plan (today's food allowance), not from the habit.
    var hasTarget: Bool { self != .check && self != .gym && self != .calories && self != .burn }

    /// A value in this kind's stored units, as people read it: "50", "1:30", "3.0 L", "7h 30m".
    func format(_ v: Double) -> String {
        switch self {
        case .timer:
            let s = Int(v.rounded())
            return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                             : String(format: "%d:%02d", s / 60, s % 60)
        case .water:
            return v >= 1000 ? String(format: "%.1f L", v / 1000) : "\(Int(v.rounded())) ml"
        case .sleep:
            let m = Int(v.rounded())
            return "\(m / 60)h \(m % 60)m"
        case .steps:
            return Int(v.rounded()).formatted()
        case .zone: return "\(Int(v.rounded())) min"
        case .protein: return "\(Int(v.rounded())) g"
        case .calories, .burn: return "\(Int(v.rounded()).formatted()) kcal"
        case .screen:
            let m = Int(v.rounded())
            return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m) min"
        case .counter: return "\(Int(v.rounded()))"
        case .check, .gym: return v >= 1 ? "Done" : "Not yet"
        }
    }
}

/// A target and the day it applies from. A habit keeps every change, so a past day is always judged
/// against the target it had that day.
struct SfzTargetChange: Codable, Equatable {
    var from: String
    var value: Double
}

struct SfzHabit: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var icon: String
    var kind: SfzHabitKind
    var targets: [SfzTargetChange]
    /// Calendar weekdays it is due (1 = Sunday … 7 = Saturday); empty means every day.
    var weekdays: [Int] = []
    /// Reminder times, minutes after midnight.
    var reminders: [Int] = []
    /// Gym: planned rest days a week (Monday to Sunday) that don't count as a miss.
    var restPerWeek: Int = 2
    /// First day this habit counts.
    var createdDay: String

    func target(on day: String) -> Double {
        let applying = targets.filter { $0.from <= day }.max { $0.from < $1.from }
        return applying?.value ?? targets.min { $0.from < $1.from }?.value ?? kind.defaultTarget
    }

    func isDue(on date: Date) -> Bool {
        weekdays.isEmpty || weekdays.contains(Calendar.current.component(.weekday, from: date))
    }
}

enum SfzGymState: String, Codable { case done, skipped, rest }

/// How one habit did on one day.
enum SfzDayStatus: Equatable {
    case met, partial, missed, rest, open, notDue, future, before, noData
    /// Counts toward consistency (due and decided).
    var counts: Bool { self == .met || self == .partial || self == .missed }
}

struct SfzChallenge: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var length: Int
    var startDay: String
    var strict: Bool
    var habitIds: [UUID]
    /// The day each habit joined, for habits added after the start.
    var habitSince: [String: String] = [:]
    /// Strict mode: the days the challenge started over from Day 1.
    var restartDays: [String] = []
    /// Flexible mode: sick or travel days that don't count.
    var pausedDays: [String] = []
    /// Strict mode: a target was lowered or a habit removed after the start.
    var modified = false
    var notes: [String] = []
    var endedDay: String?
    /// Strict mode: a missed day waiting for you to choose Restart or Switch to Flexible.
    var pendingMissDay: String?

    var effectiveStart: String { restartDays.last ?? startDay }
}

/// A ready-made challenge and the habits it needs.
struct SfzChallengeTemplate: Identifiable {
    struct HabitSpec { let name: String; let icon: String; let kind: SfzHabitKind; let target: Double; var rest = 0 }
    let id: String
    let name: String
    let blurb: String
    let length: Int
    let strict: Bool
    let habits: [HabitSpec]

    static let all: [SfzChallengeTemplate] = [
        SfzChallengeTemplate(id: "75hard", name: "75 Hard", blurb: "75 days. Two 45-minute workouts (one outdoors), follow a diet, no alcohol, 3.8 L water, read 10 pages, progress photo. Miss anything and you start again.",
                             length: 75, strict: true, habits: [
            HabitSpec(name: "Workout 45 min", icon: "figure.strengthtraining.traditional", kind: .check, target: 1),
            HabitSpec(name: "Outdoor workout 45 min", icon: "figure.run", kind: .check, target: 1),
            HabitSpec(name: "Calories under target", icon: "fork.knife.circle", kind: .calories, target: 1),
            HabitSpec(name: "No alcohol", icon: "wineglass", kind: .check, target: 1),
            HabitSpec(name: "Water", icon: "drop", kind: .water, target: 3800),
            HabitSpec(name: "Read 10 pages", icon: "book", kind: .check, target: 1),
            HabitSpec(name: "Progress photo", icon: "camera", kind: .check, target: 1)]),
        SfzChallengeTemplate(id: "75soft", name: "75 Soft", blurb: "75 days. A 45-minute workout with one rest day a week, eat well, 3 L water, read 10 pages.",
                             length: 75, strict: false, habits: [
            HabitSpec(name: "Gym", icon: "dumbbell", kind: .gym, target: 1, rest: 1),
            HabitSpec(name: "Eat well", icon: "fork.knife", kind: .check, target: 1),
            HabitSpec(name: "Water", icon: "drop", kind: .water, target: 3000),
            HabitSpec(name: "Read 10 pages", icon: "book", kind: .check, target: 1)]),
        SfzChallengeTemplate(id: "pushups30", name: "30-day push-ups", blurb: "30 days of push-ups. Start at 50 a day and raise it as you go.",
                             length: 30, strict: false, habits: [
            HabitSpec(name: "Push-ups", icon: "figure.strengthtraining.functional", kind: .counter, target: 50)]),
        SfzChallengeTemplate(id: "90day", name: "90-day habits", blurb: "90 days of the habits already on your Goal page.",
                             length: 90, strict: false, habits: []),
    ]
}

/// Habits and the active challenge. Everything lives in UserDefaults on this device, like the food log.
@MainActor
final class SfzHabitStore: ObservableObject {
    static let shared = SfzHabitStore()

    @Published private(set) var habits: [SfzHabit] { didSet { save(habits, K.habits); changed() } }
    /// habit id → day → each amount logged (reps, seconds, or 1 for done).
    @Published private(set) var logs: [String: [String: [Double]]] { didSet { save(logs, K.logs); changed() } }
    @Published private(set) var gym: [String: [String: SfzGymState]] { didSet { save(gym, K.gym); changed() } }
    /// What each gym session trained: habit id → day → body parts or split ("Push", "Legs", …).
    @Published private(set) var gymTags: [String: [String: [String]]] { didSet { save(gymTags, K.gymTags) } }
    /// Automatic values: kind → day → value, refreshed by the Goal page.
    @Published private(set) var auto: [String: [String: Double]] { didSet { save(auto, K.auto) } }
    /// Timers that are running: habit id → when they started.
    @Published private(set) var running: [String: Date] { didSet { save(running, K.running) } }
    @Published var challenge: SfzChallenge? { didSet { save(challenge, K.challenge); SfzGoalWidget.schedulePublish() } }
    @Published private(set) var finished: [SfzChallenge] { didSet { save(finished, K.finished) } }
    /// The first day the consistency grid and perfect-day streak count. Set when targets change from
    /// today and you choose to start fresh; nil counts all history.
    @Published var gridStart: String? { didSet { d.set(gridStart, forKey: "sfz.gridStart"); SfzGoalWidget.schedulePublish() } }
    @Published var roundUpEnabled: Bool { didSet { d.set(roundUpEnabled, forKey: K.roundUp); changed() } }
    @Published var roundUpMinutes: Int { didSet { d.set(roundUpMinutes, forKey: K.roundUpAt); changed() } }

    private let d = UserDefaults.standard
    private enum K {
        static let habits = "sfz.habits", logs = "sfz.habitLogs", gym = "sfz.habitGym", auto = "sfz.habitAuto"
        static let running = "sfz.habitTimers", challenge = "sfz.challenge", finished = "sfz.challengesDone"
        static let roundUp = "sfz.habitRoundUp", roundUpAt = "sfz.habitRoundUpAt", seeded = "sfz.habitsSeeded"
        static let gymTags = "sfz.habitGymTags", screenRemoved = "sfz.habitScreenRemoved"
    }

    /// The choices offered after a gym session, in the order shown.
    static let gymParts = ["Push", "Pull", "Legs", "Upper", "Lower", "Full body",
                           "Chest", "Back", "Shoulders", "Biceps", "Triceps", "Forearms",
                           "Core", "Glutes", "Calves", "Cardio", "Mobility"]

    nonisolated static var today: String { Repository.localDayKey(Date()) }

    private init() {
        habits = Self.load(d, K.habits) ?? []
        logs = Self.load(d, K.logs) ?? [:]
        gym = Self.load(d, K.gym) ?? [:]
        gymTags = Self.load(d, K.gymTags) ?? [:]
        auto = Self.load(d, K.auto) ?? [:]
        running = Self.load(d, K.running) ?? [:]
        let savedChallenge: SfzChallenge? = Self.load(d, K.challenge)
        challenge = savedChallenge
        finished = Self.load(d, K.finished) ?? []
        gridStart = d.string(forKey: "sfz.gridStart")
        roundUpEnabled = d.object(forKey: K.roundUp) as? Bool ?? false
        roundUpMinutes = d.object(forKey: K.roundUpAt) as? Int ?? (20 * 60 + 30)
        if !d.bool(forKey: K.seeded) {
            d.set(true, forKey: K.seeded)
            if habits.isEmpty {
                habits = Self.starters.map { Self.make($0) }
                save(habits, K.habits)
            }
        }
        // Screen-time habits need automatic tracking, which needs a paid developer team; without it
        // they're removed rather than logged by hand.
        // Added after the first habits: the calorie-target habit and skin care, once, for existing pages.
        if !d.bool(forKey: "sfz.habitsAddedCalSkin") {
            d.set(true, forKey: "sfz.habitsAddedCalSkin")
            var changedList = false
            for spec in Self.starters where spec.kind == .calories || spec.name == "Skin care" {
                if !habits.contains(where: { $0.name.lowercased() == spec.name.lowercased() }) {
                    habits.append(Self.make(spec)); changedList = true
                }
            }
            if changedList { save(habits, K.habits) }
        }
        if !d.bool(forKey: "sfz.habitsAddedBurn") {
            d.set(true, forKey: "sfz.habitsAddedBurn")
            if let spec = Self.starters.first(where: { $0.kind == .burn }), !habits.contains(where: { $0.kind == .burn }) {
                habits.append(Self.make(spec))
                save(habits, K.habits)
            }
        }
        if !d.bool(forKey: K.screenRemoved) {
            d.set(true, forKey: K.screenRemoved)
            if habits.contains(where: { $0.kind == .screen }) {
                habits.removeAll { $0.kind == .screen }
                save(habits, K.habits)
            }
        }
    }

    /// The habits on the page the first time it opens.
    static let starters: [SfzChallengeTemplate.HabitSpec] = [
        .init(name: "Push-ups", icon: "figure.strengthtraining.functional", kind: .counter, target: 50),
        .init(name: "Pull-ups", icon: "figure.play", kind: .counter, target: 20),
        .init(name: "Crunches", icon: "figure.core.training", kind: .counter, target: 50),
        .init(name: "Plank", icon: "figure.cooldown", kind: .timer, target: 120),
        .init(name: "Gym", icon: "dumbbell", kind: .gym, target: 1, rest: 2),
        .init(name: "Steps", icon: "figure.walk", kind: .steps, target: 10_000),
        .init(name: "Water", icon: "drop", kind: .water, target: 3000),
        .init(name: "No sugar", icon: "nosign", kind: .check, target: 1),
        .init(name: "Reading", icon: "book", kind: .check, target: 1),
        .init(name: "Calories under target", icon: "fork.knife.circle", kind: .calories, target: 1),
        .init(name: "Burn target", icon: "flame", kind: .burn, target: 1),
        .init(name: "Skin care", icon: "face.smiling", kind: .check, target: 1),
    ]

    /// Presets offered under Add habit.
    static let presets: [SfzChallengeTemplate.HabitSpec] = starters + [
        .init(name: "Squats", icon: "figure.cross.training", kind: .counter, target: 50),
        .init(name: "Stretching", icon: "figure.flexibility", kind: .timer, target: 600),
        .init(name: "Cold shower", icon: "snowflake", kind: .timer, target: 120),
        .init(name: "Meditation", icon: "brain.head.profile", kind: .timer, target: 600),
        .init(name: "Sleep", icon: "bed.double", kind: .sleep, target: 480),
        .init(name: "Active Zone Minutes", icon: "heart", kind: .zone, target: 30),
        .init(name: "Protein", icon: "fork.knife", kind: .protein, target: 120),
        .init(name: "No alcohol", icon: "wineglass", kind: .check, target: 1),
        .init(name: "Morning sunlight", icon: "sun.max", kind: .check, target: 1),
        .init(name: "Walk after meals", icon: "figure.walk.motion", kind: .check, target: 1),
        .init(name: "In bed on time", icon: "moon.zzz", kind: .check, target: 1),
        .init(name: "No phone in bed", icon: "iphone.slash", kind: .check, target: 1),
        .init(name: "No caffeine after 2 pm", icon: "cup.and.saucer", kind: .check, target: 1),
        .init(name: "Journal", icon: "square.and.pencil", kind: .check, target: 1),
        .init(name: "Vitamins", icon: "pills", kind: .check, target: 1),
        .init(name: "Weigh-in", icon: "scalemass", kind: .check, target: 1),
        .init(name: "Floss", icon: "mouth", kind: .check, target: 1),
        .init(name: "No smoking", icon: "nosign", kind: .check, target: 1),
        .init(name: "Progress photo", icon: "camera", kind: .check, target: 1),
        .init(name: "Calories under target", icon: "fork.knife.circle", kind: .calories, target: 1),
        .init(name: "Burn target", icon: "flame", kind: .burn, target: 1),
        .init(name: "Skin care (morning)", icon: "sun.horizon", kind: .check, target: 1),
        .init(name: "Skin care (night)", icon: "moon.stars", kind: .check, target: 1),
        .init(name: "Sunscreen", icon: "sun.max.trianglebadge.exclamationmark", kind: .check, target: 1),
    ]

    static func make(_ spec: SfzChallengeTemplate.HabitSpec, from day: String = SfzHabitStore.today) -> SfzHabit {
        SfzHabit(name: spec.name, icon: spec.icon, kind: spec.kind,
                 targets: [SfzTargetChange(from: day, value: spec.target)],
                 restPerWeek: spec.rest, createdDay: day)
    }

    func habit(_ id: UUID) -> SfzHabit? { habits.first { $0.id == id } }

    // MARK: Editing

    func add(_ h: SfzHabit) { habits.append(h) }

    func update(_ h: SfzHabit) {
        guard let i = habits.firstIndex(where: { $0.id == h.id }) else { return }
        habits[i] = h
    }

    func move(_ id: UUID, by offset: Int) {
        guard let i = habits.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(habits.count - 1, i + offset))
        guard i != j else { return }
        let h = habits.remove(at: i)
        habits.insert(h, at: j)
    }

    /// Removes a habit. Its logs stay, so a challenge's past days keep their record.
    func remove(_ id: UUID) {
        if var c = challenge, c.habitIds.contains(id) {
            let name = habit(id)?.name ?? "A habit"
            c.habitIds.removeAll { $0 == id }
            if c.strict { c.modified = true }
            c.notes.append("Day \(dayNumber(c)): \(name) removed")
            challenge = c
        }
        habits.removeAll { $0.id == id }
    }

    /// Changes a target from today or from tomorrow (the default), never before. In a strict challenge,
    /// lowering a challenge habit's target marks the challenge Modified; every change is noted.
    func setTarget(_ id: UUID, to value: Double, fromToday: Bool) {
        guard var h = habit(id) else { return }
        let day = fromToday ? Self.today : Self.dayKey(offset: 1, from: Self.today)
        let old = h.target(on: day)
        guard old != value else { return }
        h.targets.removeAll { $0.from >= day }
        h.targets.append(SfzTargetChange(from: day, value: value))
        update(h)
        if var c = challenge, c.endedDay == nil, c.habitIds.contains(id) {
            if c.strict && value < old { c.modified = true }
            c.notes.append("Day \(dayNumber(c)): \(h.name) \(h.kind.format(old)) → \(h.kind.format(value)), from \(fromToday ? "today" : "tomorrow")")
            challenge = c
        }
    }

    // MARK: Logging

    func log(_ id: UUID, _ amount: Double, day: String = SfzHabitStore.today) {
        var byDay = logs[id.uuidString] ?? [:]
        byDay[day, default: []].append(amount)
        logs[id.uuidString] = byDay
    }

    func undo(_ id: UUID, day: String = SfzHabitStore.today) {
        guard var byDay = logs[id.uuidString], var list = byDay[day], !list.isEmpty else { return }
        list.removeLast()
        byDay[day] = list.isEmpty ? nil : list
        logs[id.uuidString] = byDay
    }

    func entries(_ id: UUID, day: String = SfzHabitStore.today) -> [Double] { logs[id.uuidString]?[day] ?? [] }

    /// Replaces a day's log with one total (screen time entered from Settings → Screen Time).
    func setTotal(_ id: UUID, _ value: Double, day: String = SfzHabitStore.today) {
        var byDay = logs[id.uuidString] ?? [:]
        byDay[day] = value > 0 ? [value] : nil
        logs[id.uuidString] = byDay
    }

    /// Average a day over the days something was logged in the last `days` days, and how many there were.
    func loggedAverage(_ id: UUID, days: Int = 14) -> (value: Double, count: Int)? {
        var total = 0.0, n = 0
        for offset in 1...days {
            let day = Self.dayKey(offset: -offset, from: Self.today)
            let e = entries(id, day: day)
            if !e.isEmpty { total += e.reduce(0, +); n += 1 }
        }
        return n == 0 ? nil : (total / Double(n), n)
    }

    func toggleCheck(_ id: UUID, day: String = SfzHabitStore.today) {
        if entries(id, day: day).isEmpty { log(id, 1, day: day) } else {
            var byDay = logs[id.uuidString] ?? [:]
            byDay[day] = nil
            logs[id.uuidString] = byDay
        }
    }

    func gymState(_ id: UUID, day: String = SfzHabitStore.today) -> SfzGymState? { gym[id.uuidString]?[day] }

    func gymParts(_ id: UUID, day: String = SfzHabitStore.today) -> [String] { gymTags[id.uuidString]?[day] ?? [] }

    func toggleGymPart(_ id: UUID, _ part: String, day: String = SfzHabitStore.today) {
        var byDay = gymTags[id.uuidString] ?? [:]
        var list = byDay[day] ?? []
        if let i = list.firstIndex(of: part) { list.remove(at: i) } else { list.append(part) }
        byDay[day] = list.isEmpty ? nil : list
        gymTags[id.uuidString] = byDay
        if !list.isEmpty, gymState(id, day: day) != .done { setGym(id, .done, day: day) }
    }

    /// How often each part was trained in the last `days` days, most first.
    func gymPartCounts(_ id: UUID, days: Int = 30) -> [(part: String, count: Int)] {
        var counts: [String: Int] = [:]
        for offset in 0..<days {
            for p in gymParts(id, day: Self.dayKey(offset: -offset, from: Self.today)) { counts[p, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 || ($0.1 == $1.1 && $0.0 < $1.0) }
    }

    func setGym(_ id: UUID, _ state: SfzGymState?, day: String = SfzHabitStore.today) {
        var byDay = gym[id.uuidString] ?? [:]
        byDay[day] = state
        gym[id.uuidString] = byDay
    }

    func setRaw(_ key: String, _ values: [String: Double]) {
        guard (auto[key] ?? [:]) != values else { return }
        var merged = auto[key] ?? [:]
        for (k, v) in values { merged[k] = v }
        auto[key] = merged
    }

    /// Takes a habit out of the running challenge, keeping it on the Goal page.
    /// In a strict challenge that marks it Modified.
    func removeFromChallenge(_ id: UUID) {
        guard var c = challenge, c.habitIds.contains(id) else { return }
        c.habitIds.removeAll { $0 == id }
        if c.strict { c.modified = true }
        c.notes.append("Day \(dayNumber(c)): \(habit(id)?.name ?? "habit") taken out of the challenge")
        challenge = c
    }

    /// The day's food allowance from the Goal plan, kept beside the calories eaten.
    func setCalorieTargets(_ values: [String: Double]) {
        guard (auto["caloriesTarget"] ?? [:]) != values else { return }
        var merged = auto["caloriesTarget"] ?? [:]
        for (k, v) in values { merged[k] = v }
        auto["caloriesTarget"] = merged
    }

    func setAuto(_ kind: SfzHabitKind, _ values: [String: Double]) {
        guard (auto[kind.rawValue] ?? [:]) != values else { return }
        var merged = auto[kind.rawValue] ?? [:]
        for (k, v) in values { merged[k] = v }
        auto[kind.rawValue] = merged
    }

    // MARK: Timers

    func isRunning(_ id: UUID) -> Bool { running[id.uuidString] != nil }

    func startTimer(_ id: UUID) { running[id.uuidString] = Date() }

    /// Stops a running timer and logs its seconds to the day it started.
    func stopTimer(_ id: UUID) {
        guard let start = running[id.uuidString] else { return }
        running[id.uuidString] = nil
        let secs = Date().timeIntervalSince(start)
        if secs >= 1 { log(id, secs.rounded(), day: Repository.localDayKey(start)) }
    }

    /// Seconds today including a running timer.
    func timerSeconds(_ id: UUID, now: Date = Date()) -> Double {
        let logged = entries(id).reduce(0, +)
        guard let start = running[id.uuidString], Repository.localDayKey(start) == Self.today else { return logged }
        return logged + now.timeIntervalSince(start)
    }

    // MARK: Status

    /// The day's value in stored units, or nil when nothing is known.
    func value(_ h: SfzHabit, day: String) -> Double? {
        if h.kind.isAuto { return auto[h.kind.rawValue]?[day] }
        if h.kind == .gym {
            switch gymState(h.id, day: day) {
            case .done?: return 1
            case .skipped?, .rest?: return 0
            case nil: return nil
            }
        }
        let e = entries(h.id, day: day)
        return e.isEmpty ? nil : e.reduce(0, +)
    }

    func status(_ h: SfzHabit, on date: Date) -> SfzDayStatus {
        let day = Repository.localDayKey(date)
        let today = Self.today
        if day > today { return .future }
        if day < h.createdDay { return .before }
        if !h.isDue(on: date) { return .notDue }
        if h.kind == .calories {
            // Food logged that day against that day's allowance. Today stays open until the day ends;
            // a past day with nothing logged doesn't count either way.
            guard let eaten = auto[SfzHabitKind.calories.rawValue]?[day] else { return day == today ? .open : .noData }
            let allowance = auto["caloriesTarget"]?[day] ?? .infinity
            if day == today { return eaten > allowance ? .partial : .open }
            return eaten <= allowance ? .met : .missed
        }
        if h.kind == .burn {
            // Workout calories against the plan's workout burn target for that day.
            let burned = auto[SfzHabitKind.burn.rawValue]?[day]
            let target = auto["burnTarget"]?[day] ?? 0
            if let b = burned, b >= target { return .met }
            guard let b = burned else { return day == today ? .open : .noData }
            if day == today { return b > 0 ? .partial : .open }
            return b > 0 ? .partial : .missed
        }
        if h.kind == .screen {
            // Under the limit is the goal; over it is a miss straight away.
            let id = h.id.uuidString
            if SfzScreenShared.hasSelection(id), let since = SfzScreenShared.since(id), day >= since {
                // Automatic (paid developer team): iOS reports when the limit is passed.
                if SfzScreenShared.exceededDays(id).contains(day) { return .missed }
                return day == today ? .open : .met
            }
            // Logged by hand: the minutes you entered against the limit. A day with nothing logged
            // doesn't count either way.
            let logged = entries(h.id, day: day)
            if logged.isEmpty { return day == today ? .open : .noData }
            if logged.reduce(0, +) > h.target(on: day) { return .missed }
            return day == today ? .open : .met
        }
        if h.kind == .gym, gymState(h.id, day: day) == .rest {
            return restsBefore(h, upTo: date) <= h.restPerWeek ? .rest : .missed
        }
        let t = h.target(on: day)
        guard let v = value(h, day: day) else {
            if day == today { return .open }
            return h.kind.isAuto ? .noData : .missed
        }
        if v >= t { return .met }
        if day == today { return v > 0 ? .partial : .open }
        return v > 0 ? .partial : .missed
    }

    /// Rest days used this week (Monday first) up to and including `date`.
    private func restsBefore(_ h: SfzHabit, upTo date: Date) -> Int {
        var cal = Calendar.current
        cal.firstWeekday = 2
        guard let monday = cal.dateInterval(of: .weekOfYear, for: date)?.start else { return 0 }
        var n = 0
        var day = monday
        while day <= date {
            if gymState(h.id, day: Repository.localDayKey(day)) == .rest { n += 1 }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return n
    }

    /// Current streak: due days met in a row, ending today (if met) or yesterday. Rest and days it
    /// isn't due don't break it.
    func streak(_ h: SfzHabit) -> Int {
        var n = 0
        for offset in 0..<730 {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { break }
            switch status(h, on: date) {
            case .met: n += 1
            case .open, .notDue, .rest, .noData: continue
            default: return n
            }
        }
        return n
    }

    func bestStreak(_ h: SfzHabit, days: Int = 365) -> Int {
        var best = 0, run = 0
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            switch status(h, on: date) {
            case .met: run += 1; best = max(best, run)
            case .partial, .missed: run = 0
            default: break
            }
        }
        return best
    }

    /// Days met ÷ days due over the last `days` days (today only once it is met). Nil before any due day.
    func consistency(_ h: SfzHabit, days: Int = 30) -> Double? {
        var met = 0, due = 0
        for offset in 0..<days {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let st = status(h, on: date)
            if st.counts { due += 1; if st == .met { met += 1 } }
        }
        return due == 0 ? nil : Double(met) / Double(due)
    }

    /// Habits met and habits due on a day.
    func dayScore(_ date: Date, ids: [UUID]? = nil) -> (met: Int, due: Int) {
        var met = 0, due = 0
        for h in habits where ids == nil || ids!.contains(h.id) {
            let st = status(h, on: date)
            if st == .met { met += 1; due += 1 } else if st.counts || st == .open { due += 1 }
        }
        return (met, due)
    }

    // MARK: Challenges

    static func dayKey(offset: Int, from day: String) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        let base = f.date(from: day) ?? Date()
        return Repository.localDayKey(Calendar.current.date(byAdding: .day, value: offset, to: base) ?? base)
    }

    static func date(_ day: String) -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day).map { Calendar.current.date(byAdding: .hour, value: 12, to: $0) ?? $0 } ?? Date()
    }

    static func daysBetween(_ a: String, _ b: String) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: date(a)), to: cal.startOfDay(for: date(b))).day ?? 0
    }

    /// Which day of the challenge today is (1-based); paused days don't count.
    func dayNumber(_ c: SfzChallenge) -> Int {
        let today = Self.today
        let elapsed = Self.daysBetween(c.effectiveStart, min(today, c.endedDay ?? today)) + 1
        let paused = c.pausedDays.filter { $0 >= c.effectiveStart && $0 <= today }.count
        return max(1, elapsed - paused)
    }

    func challengeHabits(_ c: SfzChallenge) -> [SfzHabit] { c.habitIds.compactMap { habit($0) } }

    /// How the whole challenge did on a day.
    func challengeStatus(_ c: SfzChallenge, on date: Date) -> SfzDayStatus {
        let day = Repository.localDayKey(date)
        if day < c.effectiveStart { return .before }
        if day > Self.today { return .future }
        if c.pausedDays.contains(day) { return .rest }
        var anyDue = false, anyMissed = false, anyOpen = false, anyPartial = false
        for h in challengeHabits(c) {
            if let since = c.habitSince[h.id.uuidString], day < since { continue }
            switch status(h, on: date) {
            case .met: anyDue = true
            case .missed: anyDue = true; anyMissed = true
            case .partial: anyDue = true; anyPartial = true
            case .open: anyDue = true; anyOpen = true
            default: break
            }
        }
        if !anyDue { return .notDue }
        if anyMissed { return .missed }
        if anyPartial { return day == Self.today ? .partial : .missed }
        if anyOpen { return .open }
        return .met
    }

    /// Days fully met ÷ days decided, from the start (flexible) or the last restart (strict).
    func challengeConsistency(_ c: SfzChallenge) -> Double? {
        var met = 0, due = 0
        let start = c.strict ? c.effectiveStart : c.startDay
        let span = Self.daysBetween(start, Self.today)
        guard span >= 0 else { return nil }
        for i in 0...span {
            let date = Self.date(Self.dayKey(offset: i, from: start))
            let st = challengeStatus(c, on: date)
            if st.counts { due += 1; if st == .met { met += 1 } }
        }
        return due == 0 ? nil : Double(met) / Double(due)
    }

    func challengeStreak(_ c: SfzChallenge) -> Int {
        var n = 0
        let span = max(0, Self.daysBetween(c.effectiveStart, Self.today))
        for i in 0...span {
            let date = Self.date(Self.dayKey(offset: -i, from: Self.today))
            let st = challengeStatus(c, on: date)
            if st == .met { n += 1 } else if st == .rest || st == .notDue || st == .open { continue } else { return n }
        }
        return n
    }

    /// Strict mode: finds the first past day that was missed and holds it for you to choose: start
    /// again from Day 1, or switch to Flexible and carry on. Automatic habits with no data that day are
    /// not counted as a miss, so a late sync can't trigger it.
    func enforceStrict() {
        guard var c = challenge, c.strict, c.endedDay == nil, c.pendingMissDay == nil else { return }
        let span = max(0, Self.daysBetween(c.effectiveStart, Self.today))
        for i in 0..<span {
            let day = Self.dayKey(offset: i, from: c.effectiveStart)
            let st = challengeStatus(c, on: Self.date(day))
            if st == .missed || st == .partial {
                c.pendingMissDay = day
                challenge = c
                return
            }
        }
        // Today can already be missed when a screen-time limit is passed.
        if challengeStatus(c, on: Date()) == .missed {
            c.pendingMissDay = Self.today
            challenge = c
        }
    }

    /// Answers a strict miss: restart the day after it, or switch to Flexible and keep every day so far.
    func resolveMiss(restart: Bool) {
        guard var c = challenge, let f = c.pendingMissDay else { return }
        let when = Self.date(f).formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        c.pendingMissDay = nil
        if restart {
            c.restartDays.append(Self.dayKey(offset: 1, from: f))
            c.notes.append("Missed \(when): back to Day 1")
        } else {
            c.strict = false
            c.notes.append("Missed \(when): switched to Flexible")
        }
        challenge = c
        enforceStrict()
    }

    /// Strict to Flexible keeps everything so far. Flexible to Strict starts strict counting from today.
    func setStrict(_ strict: Bool) {
        guard var c = challenge, c.strict != strict else { return }
        c.strict = strict
        c.pendingMissDay = nil
        if strict {
            c.restartDays.append(Self.today)
            c.notes.append("Switched to Strict from today")
        } else {
            c.notes.append("Day \(dayNumber(c)): switched to Flexible")
        }
        challenge = c
    }

    /// Perfect days (every due habit met) in a row, ending today if it's already perfect, else yesterday.
    func perfectStreak() -> (current: Int, best: Int) {
        var current = 0, best = 0, run = 0
        var stillCurrent = true
        for offset in 0..<365 {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { break }
            if let start = gridStart, Repository.localDayKey(date) < start { break }
            let s = dayScore(date)
            if s.due == 0 { continue }
            if s.met == s.due {
                run += 1
                best = max(best, run)
                if stillCurrent { current = run }
            } else {
                if offset == 0 { continue }
                stillCurrent = false
                run = 0
            }
        }
        return (current, best)
    }

    /// Marks the challenge complete once its last day has passed.
    func checkFinished() {
        guard var c = challenge, c.endedDay == nil else { return }
        let elapsed = Self.daysBetween(c.effectiveStart, Self.today)
        let paused = c.pausedDays.filter { $0 >= c.effectiveStart }.count
        if elapsed - paused >= c.length {
            c.endedDay = Self.dayKey(offset: c.length - 1 + paused, from: c.effectiveStart)
            challenge = c
        }
    }

    /// Starts a challenge. Template habits are reused by name when they already exist, otherwise added.
    func start(name: String, length: Int, strict: Bool, specs: [SfzChallengeTemplate.HabitSpec],
               habitIds extra: [UUID], startTomorrow: Bool, targetOverrides: [UUID: Double] = [:]) {
        let day = startTomorrow ? Self.dayKey(offset: 1, from: Self.today) : Self.today
        for (id, value) in targetOverrides {
            guard var h = habit(id), h.kind.hasTarget, h.target(on: day) != value else { continue }
            h.targets.removeAll { $0.from >= day }
            h.targets.append(SfzTargetChange(from: day, value: value))
            update(h)
        }
        var ids: [UUID] = extra
        for spec in specs {
            if let existing = habits.first(where: { $0.name.lowercased() == spec.name.lowercased() && $0.kind == spec.kind }) {
                if existing.target(on: day) != spec.target && spec.kind.hasTarget {
                    var h = existing
                    h.targets.removeAll { $0.from >= day }
                    h.targets.append(SfzTargetChange(from: day, value: spec.target))
                    update(h)
                }
                if !ids.contains(existing.id) { ids.append(existing.id) }
            } else {
                let h = Self.make(spec, from: Self.today)
                add(h)
                ids.append(h.id)
            }
        }
        if let old = challenge { finished.append(old) }
        challenge = SfzChallenge(name: name, length: length, startDay: day, strict: strict, habitIds: ids)
    }

    func addToChallenge(_ id: UUID) {
        guard var c = challenge, !c.habitIds.contains(id) else { return }
        let from = Self.dayKey(offset: 1, from: Self.today)
        c.habitIds.append(id)
        c.habitSince[id.uuidString] = from
        c.notes.append("Day \(dayNumber(c)): \(habit(id)?.name ?? "habit") added from tomorrow")
        challenge = c
    }

    func pauseToday() {
        guard var c = challenge, !c.strict, !c.pausedDays.contains(Self.today) else { return }
        c.pausedDays.append(Self.today)
        c.notes.append("Day \(dayNumber(c)): paused")
        challenge = c
    }

    func restartChallenge() {
        guard var c = challenge else { return }
        c.restartDays.append(Self.today)
        c.notes.append("Restarted by you")
        c.endedDay = nil
        challenge = c
    }

    func endChallenge() {
        guard var c = challenge else { return }
        if c.endedDay == nil { c.endedDay = Self.today }
        finished.append(c)
        challenge = nil
    }

    // MARK: Persistence and reminders

    private func changed() { SfzHabitReminders.schedule(self); SfzGoalWidget.schedulePublish() }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ d: UserDefaults, _ key: String) -> T? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

/// Local reminders for habits: one at each set time for the next three days, skipped once the habit
/// is done for the day, plus an optional evening round-up of what is left. Rebuilt whenever habits or
/// logs change and each time the Goal page loads.
enum SfzHabitReminders {
    static let prefix = "sfz-habit-"

    static func requestPermission() {
        #if os(iOS)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    /// A notification when a running timer reaches its target, so it's heard with the phone locked.
    static func timerAlert(_ h: SfzHabit, after seconds: Double) {
        #if os(iOS)
        let content = UNMutableNotificationContent()
        content.title = h.name
        content.body = "Target reached: \(h.kind.format(h.target(on: SfzHabitStore.today)))."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "sfz-timer-\(h.id.uuidString)",
                                                                     content: content, trigger: trigger))
        #endif
    }

    static func cancelTimerAlert(_ h: SfzHabit) {
        #if os(iOS)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["sfz-timer-\(h.id.uuidString)"])
        #endif
    }

    @MainActor
    static func schedule(_ store: SfzHabitStore) {
        #if os(iOS)
        struct Item { let id: String; let title: String; let body: String; let date: Date }
        var items: [Item] = []
        let now = Date()
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        for offset in 0..<3 {
            guard let dayStart = cal.date(byAdding: .day, value: offset, to: todayStart) else { continue }
            let key = Repository.localDayKey(dayStart)
            for h in store.habits where h.isDue(on: dayStart) && !h.reminders.isEmpty {
                if offset == 0, store.status(h, on: dayStart) == .met { continue }
                for m in h.reminders {
                    guard let fire = cal.date(byAdding: .minute, value: m, to: dayStart), fire > now else { continue }
                    let target = h.target(on: key)
                    let body: String
                    if offset == 0, let v = store.value(h, day: key), h.kind.hasTarget {
                        body = "\(h.kind.format(v)) of \(h.kind.format(target)) so far."
                    } else if h.kind.hasTarget {
                        body = "Target \(h.kind.format(target))."
                    } else {
                        body = "Tap to open the Goal page."
                    }
                    items.append(Item(id: "\(prefix)\(h.id.uuidString)-\(key)-\(m)", title: h.name, body: body, date: fire))
                }
            }
            if store.roundUpEnabled, let fire = cal.date(byAdding: .minute, value: store.roundUpMinutes, to: dayStart), fire > now {
                let left = store.habits.filter { $0.isDue(on: dayStart) && store.status($0, on: dayStart) != .met }.map(\.name)
                if offset > 0 || !left.isEmpty {
                    let body = offset == 0
                        ? "\(left.count) left today: \(left.prefix(4).joined(separator: ", "))\(left.count > 4 ? "…" : "")."
                        : "Check today's habits before bed."
                    items.append(Item(id: "\(prefix)roundup-\(key)", title: "Habits", body: body, date: fire))
                }
            }
        }
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let old = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            for it in items.prefix(40) {
                let content = UNMutableNotificationContent()
                content.title = it.title
                content.body = it.body
                content.sound = .default
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: it.date)
                center.add(UNNotificationRequest(identifier: it.id, content: content,
                                                 trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
        }
        #endif
    }
}


// MARK: - Goal grid widget feed

/// What the Goal grid widget draws. The widget extension decodes the same JSON shape
/// (`SfzGoalGridFeed` in StrandiOSWidgets) from the shared App Group.
struct SfzGoalGridSnapshot: Codable {
    /// Week columns, oldest first, Monday→Sunday. Each cell: -4 future, -3 before the grid
    /// start, -2 missed, -1 rest, 0 nothing due, 0<x≤1 green strength.
    var weeks: [[Double]]
    var streak: Int
    var todayMet: Int
    var todayDue: Int
    var challengeName: String?
    var challengeDay: Int?
    var challengeLength: Int?
    var strict: Bool
    var percent30: Int?
    var updated: Date
}

@MainActor
enum SfzGoalWidget {
    static let storageKey = "sfz.goalGrid.snapshot"
    static let kind = "SfzGoalGridWidget"
    private static var pending: DispatchWorkItem?

    /// Coalesce bursts of habit changes into one publish.
    static func schedulePublish() {
        pending?.cancel()
        let work = DispatchWorkItem { Task { @MainActor in publish() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    static func level(_ date: Date, store: SfzHabitStore) -> Double {
        let cal = Calendar.current
        if cal.startOfDay(for: date) > cal.startOfDay(for: Date()) { return -4 }
        let key = Repository.localDayKey(date)
        if let start = store.gridStart, key < start { return -3 }
        let isToday = cal.isDateInToday(date)
        if let c = store.challenge, c.strict, c.endedDay == nil {
            if key >= c.effectiveStart {
                switch store.challengeStatus(c, on: date) {
                case .met: return 1
                case .missed: return -2
                case .partial: return isToday ? 0 : -2
                case .rest: return -1
                default: return 0
                }
            }
            if key >= c.startDay {
                let s = store.dayScore(date, ids: c.habitIds)
                if s.due == 0 { return 0 }
                return s.met == s.due ? 1 : -2
            }
        }
        let s = store.dayScore(date)
        if s.due == 0 { return 0 }
        if isToday && s.met < s.due {
            return s.met == 0 ? 0 : 0.25 + 0.5 * Double(s.met) / Double(s.due)
        }
        if s.met == 0 { return -2 }
        return 0.25 + 0.75 * Double(s.met) / Double(s.due)
    }

    static func publish() {
        let store = SfzHabitStore.shared
        var cal = Calendar.current
        cal.firstWeekday = 2
        let today = cal.startOfDay(for: Date())
        let monday = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let weeksCount = 20
        guard let first = cal.date(byAdding: .day, value: -7 * (weeksCount - 1), to: monday) else { return }
        let weeks: [[Double]] = (0..<weeksCount).map { w in
            (0..<7).map { d in
                guard let day = cal.date(byAdding: .day, value: w * 7 + d, to: first) else { return -4 }
                return level(day, store: store)
            }
        }
        let t = store.dayScore(Date())
        let recent = (0..<30).compactMap { cal.date(byAdding: .day, value: -$0, to: Date()) }
            .filter { d in store.gridStart.map { Repository.localDayKey(d) >= $0 } ?? true }
            .map { store.dayScore($0) }
        let met = recent.reduce(0) { $0 + $1.met }, due = recent.reduce(0) { $0 + $1.due }
        let c = store.challenge.flatMap { $0.endedDay == nil ? $0 : nil }
        let snap = SfzGoalGridSnapshot(
            weeks: weeks,
            streak: store.perfectStreak().current,
            todayMet: t.met, todayDue: t.due,
            challengeName: c?.name,
            challengeDay: c.map { min(store.dayNumber($0), $0.length) },
            challengeLength: c?.length,
            strict: c?.strict ?? false,
            percent30: due > 0 ? Int((Double(met) / Double(due) * 100).rounded()) : nil,
            updated: Date())
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = try? JSONEncoder().encode(snap) else { return }
        defaults.set(data, forKey: storageKey)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}
