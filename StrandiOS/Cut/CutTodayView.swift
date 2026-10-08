import SwiftUI
import StrandDesign
import WhoopStore
import StrandAnalytics

/// The weight-loss Today screen: calorie budget, battery, live heart rate, calories burned, steps,
/// a food log and progress toward the goal weight. Nothing else.
struct CutTodayView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var router: NavRouter
    @ObservedObject private var plan = CutPlanStore.shared

    @State private var burned: Calories.DayEnergyEstimate?
    @State private var steps: Double?
    /// sfz: this week's workouts (Monday onwards) for the "This week" card.
    @State private var weekRows: [WorkoutRow] = []
    @State private var zoneMinutes: Int = 0
    @State private var waterML: Double = 0
    @State private var showAddFood = false
    @State private var showWeight = false
    @State private var showPlan = false
    @State private var showGoal = false
    @State private var showSettings = false
    @State private var showHealth = false

    /// sfz: the Goal page's cards, in order; any can be hidden from Edit page.
    enum GoalSection: String, CaseIterable, Identifiable {
        case challenge, habits, consistency, calories, food, water, weight, week, fat
        var id: String { rawValue }
        var title: String {
            switch self {
            case .challenge: return "Challenge"
            case .habits: return "Today's habits"
            case .consistency: return "Consistency grid"
            case .calories: return "Calories left"
            case .food: return "Food today"
            case .water: return "Water today"
            case .weight: return "Weight goal"
            case .week: return "This week"
            case .fat: return "Fat lost"
            }
        }
    }
    @AppStorage("sfz.goal.hidden") private var hiddenRaw = ""
    private var hiddenSections: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }
    @State private var editingPage = false

    private var dayKey: String { Repository.localDayKey(Date()) }
    private var male: Bool { profile.sex != "female" }

    /// Today's burn: the full day's everyday burn plus workouts the strap has measured so far. The one
    /// figure the Burned tile, the fat card, today's bar and today's expected weight all use.
    private var burnedSoFar: Double {
        plan.dayBurn(maintenance: budget.maintenance, activeKcal: burned?.activeKcal ?? 0)
    }

    private var budget: CutPlanStore.Budget {
        plan.budget(weightKg: profile.weightKg, heightCm: profile.heightCm, age: profile.age, male: male,
                    activeKcal: burned?.activeKcal ?? 0, eaten: plan.eaten(day: dayKey))
    }

    var body: some View {
        ScreenScaffold(title: "Goal", subtitle: LocalizedStringKey(Date().formatted(.dateTime.weekday(.wide).day().month(.wide))),
                       onRefresh: { ble.syncNow(); await load() }, lazy: false, topBackground: nil,
                       trailing: { gearMenu }) {
            // sfz: one job per card, in the order you use them: today's calories, what you ate,
            // the goal, then the fat/week view. Heart rate, battery, burned and steps tiles were
            // removed: burn is already in the calories and fat cards, the rest lives on Today.
            VStack(spacing: NoopMetrics.sectionGap) {
                ForEach(GoalSection.allCases.filter { !hiddenSections.contains($0.rawValue) }) { section in
                    switch section {
                    case .challenge: SfzChallengeCard()
                    case .habits: SfzHabitsSection()
                    case .consistency: SfzConsistencyHeatmap()
                    case .calories: budgetCard
                    case .food: foodCard
                    case .water: waterCard
                    case .weight: goalCard
                    case .week: weekCard
                    case .fat: fatCard
                    }
                }
            }
        }
        .task {
            seedPlanIfNeeded()
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
        .sheet(isPresented: $showAddFood) { AddFoodSheet(day: dayKey) }
        .sheet(isPresented: $showWeight) { LogWeightSheet() }
        .sheet(isPresented: $showPlan) { CutPlanSheet() }
        .sheet(isPresented: $editingPage) { editPageSheet }
        .sheet(isPresented: $showGoal) { GoalSheet(currentKg: estimate.kg) }
        .sheet(isPresented: $showHealth, onDismiss: { Task { await load() } }) {
            NavigationStack {
                AppleHealthView()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showHealth = false }.foregroundStyle(StrandPalette.accent)
                        }
                    }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showSettings = false }.foregroundStyle(StrandPalette.accent)
                        }
                    }
            }
        }
    }

    /// sfz: Devices, Apple Health and Settings already live in More and behind the profile button,
    /// so the page keeps one control: the plan (calorie target, pace, maintenance).
    private var gearMenu: some View {
        Menu {
            Button { showPlan = true } label: { Label("Calorie plan", systemImage: "slider.horizontal.3") }
            Button { editingPage = true } label: { Label("Edit page", systemImage: "square.grid.2x2") }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: NoopMetrics.compactControlSize, height: NoopMetrics.compactControlSize)
        }
        .accessibilityLabel("Plan and page settings")
    }

    /// Show or hide each card on the Goal page.
    private var editPageSheet: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(GoalSection.allCases) { section in
                        Toggle(section.title, isOn: Binding(
                            get: { !hiddenSections.contains(section.rawValue) },
                            set: { on in
                                var h = hiddenSections
                                if on { h.remove(section.rawValue) } else { h.insert(section.rawValue) }
                                hiddenRaw = GoalSection.allCases.map(\.rawValue).filter { h.contains($0) }.joined(separator: ",")
                            }))
                        .tint(StrandPalette.accent)
                    }
                } footer: {
                    Text("Hidden cards keep their data. The \"Calories under target\" habit uses the same allowance as the Calories left card.")
                }
            }
            .navigationTitle("Edit page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { editingPage = false } } }
        }
    }

    // MARK: Cards

    private var good: Color { StrandPalette.chargeColor }
    private var bad: Color { StrandPalette.statusCritical }

    private var budgetCard: some View {
        let b = budget
        let over = b.remaining < 0
        let tint = over ? bad : good
        return NoopCard(tint: tint) {
            VStack(spacing: NoopMetrics.space4) {
                HStack(spacing: NoopMetrics.space5) {
                    ZStack {
                        Circle().stroke(StrandPalette.hairline, lineWidth: 14)
                        Circle()
                            .trim(from: 0, to: min(b.eaten / max(b.allowance, 1), 1))
                            .stroke(tint, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.5), value: b.eaten)
                        VStack(spacing: 0) {
                            Text(format(abs(b.remaining)))
                                .font(StrandFont.number(32, weight: .bold))
                                .foregroundStyle(over ? bad : StrandPalette.textPrimary)
                                .lineLimit(1).minimumScaleFactor(0.6)
                            Text(over ? "over" : "kcal left")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                        .padding(NoopMetrics.space4)
                    }
                    .frame(width: 140, height: 140)

                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        iconStat("fork.knife", StrandPalette.metricAmber, format(b.eaten),
                                 plan.logBuffer > 0 ? "eaten · +\(Int((plan.logBuffer * 100).rounded()))%" : "eaten")
                        iconStat("flame.fill", StrandPalette.metricRose,
                                 "\(format(b.workoutDone)) / \(format(b.workoutTarget))",
                                 b.workoutBonus > 0 ? "workout · +\(format(b.workoutBonus)) food" : "workout burn")
                        iconStat("target", StrandPalette.accent, format(b.allowance), "allowed")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                proteinBar
                Button { showAddFood = true } label: {
                    Label("Add food", systemImage: "plus")
                        .font(StrandFont.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, NoopMetrics.space2)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(StrandPalette.accent)
            }
        }
    }

    private var proteinBar: some View {
        let got = plan.protein(day: dayKey)
        let target = max(plan.proteinTarget, 1)
        let tint = StrandPalette.metricPurple
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline) {
                Label("Protein", systemImage: "fish.fill")
                    .font(StrandFont.subhead).foregroundStyle(tint)
                Spacer()
                Text("\(Int(got.rounded())) / \(Int(target.rounded())) g")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(got >= target ? tint : StrandPalette.textPrimary)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.hairline)
                GeometryReader { g in
                    Capsule().fill(tint).frame(width: got > 0 ? max(8, g.size.width * min(got / target, 1)) : 0)
                }
            }
            .frame(height: 8)
        }
    }

    /// Calories → fat: today's burn − food as an equation, the resulting grams of fat, and a
    /// seven-day bar strip of daily deficits. Uses 1 kg fat ≈ 7,700 kcal.
    private var fatCard: some View {
        let b = budget
        let burn = burnedSoFar
        let deficit = burn - b.eaten
        let days = weekDays(maintenance: b.maintenance)
        let weekKcal = days.compactMap(\.deficit).reduce(0, +)
        let tint = deficit >= 0 ? good : bad
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack {
                    Text("FAT").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    chip("1 kg = 7,700 kcal")
                }

                HStack(spacing: NoopMetrics.space2) {
                    eqTile("flame.fill", StrandPalette.metricRose, format(burn), "burned")
                    op("−")
                    eqTile("fork.knife", StrandPalette.metricAmber, format(b.eaten), "eaten")
                    op("=")
                    eqTile(deficit >= 0 ? "arrow.down" : "arrow.up", tint, format(abs(deficit)),
                           deficit >= 0 ? "deficit" : "surplus")
                }

                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Image(systemName: "drop.fill").foregroundStyle(tint)
                    Text(fatText(deficit)).font(StrandFont.number(40, weight: .bold)).foregroundStyle(tint)
                    Text(deficit >= 0 ? "fat burned today" : "fat stored today")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }

                weekBars(days, totalKcal: weekKcal)
            }
        }
    }

    private struct DayBar: Identifiable {
        let id: String
        let letter: String
        let deficit: Double?   // nil = no food logged that day
        let isToday: Bool
    }

    private func weekBars(_ days: [DayBar], totalKcal: Double) -> some View {
        let peak = max(days.compactMap { $0.deficit.map(abs) }.max() ?? 1, 1)
        let logged = days.contains { $0.deficit != nil }
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                Text("This week").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                if logged {
                    Text(String(format: "%@%.2f kg", totalKcal >= 0 ? "−" : "+", abs(totalKcal) / CutPlanStore.kcalPerKgFat))
                        .font(StrandFont.bodyNumber).foregroundStyle(totalKcal >= 0 ? good : bad)
                }
            }
            HStack(alignment: .bottom, spacing: NoopMetrics.space2) {
                ForEach(days) { d in
                    VStack(spacing: NoopMetrics.space1) {
                        ZStack(alignment: .bottom) {
                            Capsule().fill(StrandPalette.hairline).frame(height: 56)
                            if let v = d.deficit {
                                Capsule()
                                    .fill(v >= 0 ? good : bad)
                                    .frame(height: max(6, 56 * abs(v) / peak))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        Text(d.letter)
                            .font(StrandFont.caption)
                            .foregroundStyle(d.isToday ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    private func iconStat(_ icon: String, _ tint: Color, _ value: String, _ label: String) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(StrandPalette.hairline.opacity(0.5)))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(StrandFont.number(17, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func eqTile(_ icon: String, _ tint: Color, _ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            Text(value).font(StrandFont.number(17, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NoopMetrics.space2)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.hairline.opacity(0.5)))   // sfz minimal: neutral tile
    }

    private func op(_ s: String) -> some View {
        Text(s).font(StrandFont.headline).foregroundStyle(StrandPalette.textTertiary)
    }

    private func chip(_ s: String) -> some View {
        Text(s)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, NoopMetrics.space2)
            .padding(.vertical, NoopMetrics.space1)
            .background(Capsule().fill(StrandPalette.hairline))
    }

    /// Grams (under 1 kg) or kilograms of fat for a kcal deficit; sign dropped (the label carries it).
    // MARK: This week (sfz)

    /// Monday 00:00 of the current week, local time.
    private static var weekStart: Date {
        var cal = Calendar.current
        cal.firstWeekday = 2
        return cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? Calendar.current.startOfDay(for: Date())
    }

    static func thisWeeksWorkouts(repo: Repository) async -> [WorkoutRow] {
        let lo = Int(weekStart.timeIntervalSince1970)
        return await repo.workoutRows(days: 8).filter { $0.startTs >= lo }
    }

    /// Active Zone Minutes since Monday, the way Google Health counts them, from the WHOOP's all-day heart
    /// rate rather than from logged workouts alone. Each minute's mean bpm is placed on the heart-rate
    /// reserve for that day: 40-59% (fat burn) earns 1, 60% and above (cardio, peak) earns 2. A day with no
    /// resting heart rate yet falls back to the latest one, then to 60 bpm.
    static func activeZoneMinutes(repo: Repository, hrMax: Int) async -> Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fallbackRest = Double(repo.today?.restingHr ?? repo.days.last(where: { $0.restingHr != nil })?.restingHr ?? 60)
        var total = 0
        var day = cal.startOfDay(for: weekStart)
        while day <= today {
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            let key = Repository.localDayKey(day)
            let rest = repo.days.last(where: { $0.day == key })?.restingHr.map(Double.init) ?? fallbackRest
            total += zonePoints(await repo.hrBuckets(from: Int(day.timeIntervalSince1970),
                                                    to: Int(next.timeIntervalSince1970) - 1, bucketSeconds: 60),
                                rest: rest, hrMax: Double(hrMax))
            day = next
        }
        return total
    }

    /// Zone points for one day's one-minute means. Pure, so the thresholds are easy to check.
    static func zonePoints(_ minutes: [HRBucket], rest: Double, hrMax: Double) -> Int {
        let reserve = hrMax - rest
        guard reserve > 10 else { return 0 }
        let fatBurn = rest + 0.40 * reserve
        let cardio = rest + 0.60 * reserve
        return minutes.reduce(0) { sum, m in
            m.bpm >= cardio ? sum + 2 : (m.bpm >= fatBurn ? sum + 1 : sum)
        }
    }

    /// Minutes of workouts this week; a row without a stored duration counts its start-to-end span.
    static func cardioMinutes(_ rows: [WorkoutRow]) -> Int {
        Int(rows.reduce(0.0) { $0 + max(0, $1.durationS ?? Double($1.endTs - $1.startTs)) } / 60)
    }

    /// Distinct local days this week with at least one workout.
    static func exerciseDays(_ rows: [WorkoutRow]) -> Int {
        Set(rows.map { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs))) }).count
    }

    private var weekCard: some View {
        let minutes = zoneMinutes
        let days = Self.exerciseDays(weekRows)
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                Text("THIS WEEK").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                weekRow("Active Zone Minutes", value: minutes, target: plan.weeklyCardioTarget, unit: "min",
                        tint: StrandPalette.effortColor)
                weekRow("Exercise days", value: days, target: plan.exerciseDaysTarget, unit: "days",
                        tint: StrandPalette.chargeColor)
                Text("Zone minutes come from your WHOOP's heart rate all day: 1 per minute in fat burn, 2 in cardio or peak. Exercise days count workouts since Monday.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func weekRow(_ label: String, value: Int, target: Int, unit: String, tint: Color) -> some View {
        let frac = target > 0 ? min(Double(value) / Double(target), 1) : 0
        return VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack {
                Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text("\(value) / \(target) \(unit)").font(StrandFont.bodyNumber)
                    .foregroundStyle(value >= target ? good : StrandPalette.textSecondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.hairline)
                    Capsule().fill(tint).frame(width: value > 0 ? max(8, g.size.width * frac) : 0)
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
    }

    private func fatText(_ kcal: Double) -> String {
        let g = abs(kcal) / CutPlanStore.kcalPerKgFat * 1000
        return g < 1000 ? "\(Int(g.rounded())) g" : String(format: "%.2f kg", g / 1000)
    }

    /// This week, Monday to Sunday (sfz). A day with nothing logged has no deficit rather than being
    /// counted as a full fast; days still ahead stay empty.
    private func weekDays(maintenance: Double) -> [DayBar] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let sinceMonday = (cal.component(.weekday, from: today) + 5) % 7   // Mon = 0 … Sun = 6
        return (0..<7).compactMap { i -> DayBar? in
            let back = sinceMonday - i   // >0 past, 0 today, <0 future
            guard let date = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            let k = Repository.localDayKey(date)
            var deficit: Double?
            if back >= 0, !plan.entries(day: k).isEmpty {
                let burn = k == dayKey ? burnedSoFar
                    : plan.dayBurn(maintenance: maintenance, activeKcal: plan.activeByDay[k] ?? 0)
                deficit = burn - plan.eaten(day: k)
            }
            return DayBar(id: k, letter: String(date.formatted(.dateTime.weekday(.narrow))),
                          deficit: deficit, isToday: back == 0)
        }
    }

    /// The pace the goal date is predicted from: the average burn − food over the last 7 COMPLETE logged
    /// days (today is still in progress, so excluded). Under two such days, the planned deficit stands in.
    private var pace: (kcal: Double, days: Int, fromPlan: Bool) {
        let maintenance = budget.maintenance
        let recent = plan.loggedDays.filter { $0 < dayKey && $0 >= plan.startDay }.suffix(7)
        guard recent.count >= 2 else { return (budget.requiredDeficit, 0, true) }
        let total = recent.reduce(0.0) { sum, k in
            sum + plan.dayBurn(maintenance: maintenance, activeKcal: plan.activeByDay[k] ?? 0) - plan.eaten(day: k)
        }
        return (total / Double(recent.count), recent.count, false)
    }

    /// Estimated weight right now: the start-of-day estimate minus today's deficit so far.
    private var estimate: (kg: Double, days: Int) {
        let base = plan.estimatedKg(beforeDay: dayKey, heightCm: profile.heightCm, age: profile.age, male: male)
        let todayLogged = !plan.entries(day: dayKey).isEmpty
        let today = todayLogged ? (burnedSoFar - plan.eaten(day: dayKey)) / CutPlanStore.kcalPerKgFat : 0
        return (base.kg - today, base.days + (todayLogged ? 1 : 0))
    }

    /// sfz: today's water with one-tap adds; the full log (edit, delete, custom size) opens from here.
    private var waterCard: some View {
        let goal = repo.hydrationGoalML(profileSex: profile.sex)
        let frac = goal > 0 ? min(waterML / Double(goal), 1) : 0
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack {
                    Text("WATER TODAY").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    NavigationLink(value: TabRoute.hydration) {
                        HStack(spacing: 2) {
                            Text("Log").font(StrandFont.caption)
                            Image(systemName: "chevron.right").font(StrandFont.caption)
                        }
                        .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(waterML)) ml").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    Text("of \(goal) ml").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StrandPalette.hairline)
                        Capsule().fill(StrandPalette.metricCyan).frame(width: waterML > 0 ? max(8, g.size.width * frac) : 0)
                    }
                }
                .frame(height: 8)
                HStack(spacing: NoopMetrics.space2) {
                    ForEach([250, 500, 750], id: \.self) { ml in
                        Button {
                            Task {
                                await repo.logHydration(amountMl: ml)
                                waterML = await repo.hydrationTotal(day: dayKey)
                            }
                        } label: {
                            Text("+\(ml) ml").font(StrandFont.subhead)
                                .frame(maxWidth: .infinity).padding(.vertical, NoopMetrics.space2)
                                .background(Capsule().fill(StrandPalette.metricCyan.opacity(0.14)))
                                .foregroundStyle(StrandPalette.metricCyan)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add \(ml) millilitres of water")
                    }
                }
            }
        }
        .task(id: repo.hydrationSeq) { waterML = await repo.hydrationTotal(day: dayKey) }
    }

    private var foodCard: some View {
        let entries = plan.entries(day: dayKey)
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("FOOD TODAY").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                if entries.isEmpty {
                    Text("Nothing logged yet.").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                }
                ForEach(entries) { e in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            Text(e.at.formatted(date: .omitted, time: .shortened))
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(e.kcal) kcal").font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                            let macros = [e.protein.map { "\(Int($0.rounded())) g P" },
                                          e.carbs.map { "\(Int($0.rounded())) g C" },
                                          e.fat.map { "\(Int($0.rounded())) g F" }].compactMap { $0 }
                            if !macros.isEmpty {
                                Text(macros.joined(separator: " · ")).font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                        Button { plan.removeFood(e.id, day: dayKey) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(StrandPalette.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(e.name)")
                    }
                }
            }
        }
    }

    /// The goal in three plain parts: what you're aiming for, how you're doing, and what today needs.
    private var goalCard: some View {
        let current = estimate.kg
        let toLose = max(current - plan.goalKg, 0)
        let reached = current <= plan.goalKg
        let b = budget
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack {
                    Text("GOAL").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Button { showGoal = true } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(StrandFont.caption)
                            .padding(.horizontal, NoopMetrics.space2)
                            .padding(.vertical, NoopMetrics.space1)
                            .background(Capsule().strokeBorder(StrandPalette.hairline, lineWidth: 1))
                            .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                }

                // 1. What you're aiming for.
                Text(reached ? "Goal reached: \(String(format: "%.1f", plan.goalKg)) kg"
                     : "Lose \(String(format: "%.1f", toLose)) kg → \(String(format: "%.1f", plan.goalKg)) kg by \(plan.targetDate.formatted(.dateTime.day().month(.abbreviated)))")
                    .font(StrandFont.number(20, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                weightBar(current: current)

                // 2. How you're doing.
                statusLine(current: current)

                if !reached {
                    Divider().overlay(StrandPalette.hairline)
                    // 3. What today needs. The same numbers the calories card above uses.
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("TODAY'S PLAN").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                        planLine("fork.knife", StrandPalette.metricAmber, "Eat up to **\(format(b.allowance)) kcal**")
                        if b.workoutTarget >= 1 {
                            planLine("flame.fill", StrandPalette.metricRose, "Burn **\(format(b.workoutTarget)) kcal** in workouts")
                        }
                    }
                }

                Button { showWeight = true } label: {
                    Label("Set weight", systemImage: "scalemass")
                        .font(StrandFont.subhead).frame(maxWidth: .infinity).padding(.vertical, NoopMetrics.space1)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(StrandPalette.accent)
            }
        }
    }

    /// Start weight on the left, goal on the right, a dot where the estimate is now.
    private func weightBar(current: Double) -> some View {
        let span = max(plan.startKg - plan.goalKg, 0.1)
        let done = min(max((plan.startKg - current) / span, 0), 1)
        return VStack(spacing: NoopMetrics.space1) {
            HStack {
                Text(String(format: "%.1f", plan.startKg))
                Spacer()
                Text(String(format: "%.1f", plan.goalKg))
            }
            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            GeometryReader { g in
                let x = g.size.width * done
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.hairline).frame(height: 8)
                    Capsule().fill(good).frame(width: max(8, x), height: 8)
                    Circle().fill(StrandPalette.textPrimary).frame(width: 16, height: 16)
                        .offset(x: min(max(x - 8, 0), g.size.width - 16))
                }
                .frame(height: 16)
                Text(String(format: "%.1f now", current))
                    .font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize()
                    .position(x: min(max(x, 28), g.size.width - 28), y: 28)
            }
            .frame(height: 38)
        }
    }

    private func statusLine(current: Double) -> some View {
        let p = pace
        let eta = plan.projectedGoalDate(currentKg: current, avgDailyDeficit: p.kcal)
        let cal = Calendar.current
        let late = eta.map { cal.dateComponents([.day], from: cal.startOfDay(for: plan.targetDate),
                                                to: cal.startOfDay(for: $0)).day ?? 0 }
        let when = eta.map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? ""
        let (text, tint): (String, Color) = {
            if current <= plan.goalKg { return ("Done. Set a new goal any time.", good) }
            if p.fromPlan { return ("Log 2 full days to see if you're on track", StrandPalette.textTertiary) }
            guard let late else { return ("Not losing lately: eat less or move more", bad) }
            if late <= 0 { return ("On track: you'll get there \(when)", good) }
            return ("\(late) day\(late == 1 ? "" : "s") behind: you'll get there \(when)", StrandPalette.statusWarning)
        }()
        return HStack(spacing: NoopMetrics.space2) {
            Circle().fill(tint).frame(width: 10, height: 10)
            Text(text).font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func planLine(_ icon: String, _ tint: Color, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(StrandPalette.hairline.opacity(0.5)))
            Text(text).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    // MARK: Pieces

    private func tile(_ title: String, icon: String, value: String, unit: String, caption: String, tint: Color) -> some View {
        NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Label(title, systemImage: icon)
                    .font(StrandFont.subhead).foregroundStyle(tint)
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                    Text(value).font(StrandFont.number(28, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if !unit.isEmpty {
                        Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                Text(caption).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var hrText: String {
        guard live.connected, let hr = live.heartRate, hr > 0 else { return "–" }
        return "\(hr)"
    }

    private var batteryText: String {
        guard live.activeIsWhoop, let pct = live.batteryPct else { return "–" }
        return "\(Int(pct.rounded()))%"
    }

    private var batteryIcon: String {
        if live.charging == true { return "battery.100.bolt" }
        guard let pct = live.batteryPct else { return "battery.0" }
        switch pct {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    private func format(_ v: Double) -> String { Int(v.rounded()).formatted() }

    // MARK: Data

    /// First launch: write the owner's stated numbers into the profile once, so every estimate
    /// (calories, HR zones) uses them. Editable afterwards under Edit plan.
    private func seedPlanIfNeeded() {
        guard !plan.configured else { return }
        profile.weightKg = 83.3
        profile.heightCm = 180
        profile.sex = "male"
        profile.dateOfBirth = ProfileStore.dateOfBirth(forAge: 24)
        plan.startKg = 83.3
        plan.startDay = dayKey
        plan.goalKg = 75
        plan.configured = true
    }

    private func load() async {
        // No scale: the start-of-day estimate IS the weight every calculation uses (BMR, allowance,
        // strap calorie estimates). Rounded to 0.1 kg so it doesn't churn.
        let base = plan.estimatedKg(beforeDay: dayKey, heightCm: profile.heightCm, age: profile.age, male: male)
        let rounded = (base.kg * 10).rounded() / 10
        if abs(profile.weightKg - rounded) >= 0.05 { profile.weightKg = rounded }
        let start = Calendar.current.startOfDay(for: Date())
        let from = Int(start.timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        if hr.isEmpty {
            burned = nil
        } else {
            let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                                 age: Double(profile.age), sex: profile.sex)
            burned = Calories.estimateDayEnergy(hr, profile: up, hrmax: Double(profile.hrMax),
                                                restingHR: repo.today?.restingHr.map(Double.init))
        }
        await backfillActive()

        weekRows = await Self.thisWeeksWorkouts(repo: repo)
        zoneMinutes = await Self.activeZoneMinutes(repo: repo, hrMax: profile.hrMax)

        let key = dayKey
        let apple = await repo.appleDailyRows(days: 3).filter { $0.day == key }.compactMap { $0.steps }.max()
        let est = await repo.exploreSeries(key: "steps_est", source: "my-whoop", days: 3).last { $0.day == key }?.value
        let measured = repo.today?.day == key ? repo.today?.steps : nil
        steps = measured.map(Double.init) ?? apple.map(Double.init) ?? est
        await SfzHabitAuto.refresh(repo: repo, plan: plan, profile: profile, activeToday: burned?.activeKcal ?? 0,
                                   stepsToday: steps)

    }

    /// Workout kcal for past logged days since the plan started (up to 120 days back) that have no
    /// stored value, computed once from each whole day's heart rate so the fat totals count them.
    private func backfillActive() async {
        let cal = Calendar.current
        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex)
        for offset in 1..<120 {
            guard let start = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: Date())),
                  let end = cal.date(byAdding: .day, value: 1, to: start) else { continue }
            let key = Repository.localDayKey(start)
            if key < plan.startDay { break }
            guard plan.activeByDay[key] == nil, !plan.entries(day: key).isEmpty else { continue }
            let hr = await repo.hrSamples(from: Int(start.timeIntervalSince1970),
                                          to: Int(end.timeIntervalSince1970) - 1, limit: 200_000)
            let resting = repo.days.last(where: { $0.day == key })?.restingHr.map(Double.init)
            let e = Calories.estimateDayEnergy(hr, profile: up, hrmax: Double(profile.hrMax), restingHR: resting)
            plan.setActive(e.activeKcal, day: key)
        }
    }
}

// MARK: - Sheets

private struct AddFoodSheet: View {
    let day: String
    @ObservedObject private var plan = CutPlanStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kcal = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @FocusState private var kcalFocused: Bool

    private func grams(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What did you eat? (optional)", text: $name)
                    TextField("Calories", text: $kcal)
                        .keyboardType(.numberPad)
                        .focused($kcalFocused)
                    TextField("Protein, g (optional)", text: $protein)
                        .keyboardType(.decimalPad)
                    TextField("Carbs, g (optional)", text: $carbs)
                        .keyboardType(.decimalPad)
                    TextField("Fat, g (optional)", text: $fat)
                        .keyboardType(.decimalPad)
                }
                let recent = plan.recentFoods()
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent) { f in
                            Button {
                                plan.addFood(name: f.name, kcal: f.kcal, protein: f.protein, carbs: f.carbs,
                                             fat: f.fat, day: day)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(f.name).foregroundStyle(StrandPalette.textPrimary)
                                    Spacer()
                                    Text(f.summary)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        plan.addFood(name: name, kcal: Int(kcal) ?? 0, protein: grams(protein),
                                     carbs: grams(carbs), fat: grams(fat), day: day)
                        dismiss()
                    }
                    .disabled((Int(kcal) ?? 0) <= 0)
                }
            }
            .onAppear { kcalFocused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct LogWeightSheet: View {
    @EnvironmentObject var profile: ProfileStore
    @ObservedObject private var plan = CutPlanStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var kg = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Weight (kg)", text: $kg).keyboardType(.decimalPad)
                } footer: {
                    Text("Optional. If you weigh yourself somewhere, enter it here and the estimate restarts from it.")
                }
                if !plan.weighIns.isEmpty {
                    Section("History") {
                        ForEach(plan.weighIns.reversed().prefix(14)) { w in
                            HStack {
                                Text(w.at.formatted(date: .abbreviated, time: .omitted))
                                Spacer()
                                Text(String(format: "%.1f kg", w.kg)).foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Set weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let v = parsed {
                            plan.logWeight(v)
                            profile.weightKg = v
                        }
                        dismiss()
                    }
                    .disabled(parsed == nil)
                }
            }
            .onAppear { kg = String(format: "%.1f", profile.weightKg) }
        }
        .presentationDetents([.medium, .large])
    }

    private var parsed: Double? {
        Double(kg.replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 20 && $0 < 400 ? $0 : nil }
    }
}

private struct CutPlanSheet: View {
    @EnvironmentObject var profile: ProfileStore
    @ObservedObject private var plan = CutPlanStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    Stepper(value: $profile.heightCm, in: 120...230, step: 1) {
                        row("Height", String(format: "%.0f cm", profile.heightCm))
                    }
                    Stepper(value: ageBinding, in: 14...100) { row("Age", "\(profile.age)") }
                    Picker("Sex", selection: $profile.sex) {
                        Text("Male").tag("male")
                        Text("Female").tag("female")
                    }
                }
                Section("Goal") {
                    Stepper(value: $plan.startKg, in: 40...250, step: 0.1) {
                        row("Starting weight", String(format: "%.1f kg", plan.startKg))
                    }
                    Picker("Deficit from", selection: $plan.workoutShare) {
                        ForEach([0.0, 0.2, 0.3, 0.4, 0.5], id: \.self) { s in
                            Text(s == 0 ? "Food only"
                                 : "\(Int(((1 - s) * 100).rounded()))% food · \(Int((s * 100).rounded()))% workout").tag(s)
                        }
                    }
                    Picker("Protein target", selection: $plan.proteinPerKg) {
                        ForEach([1.6, 2.0, 2.2], id: \.self) { v in
                            Text(String(format: "%.1f g/kg · %.0f g", v, v * plan.goalKg)).tag(v)
                        }
                    }
                    Picker("Logging buffer", selection: $plan.logBuffer) {
                        Text("Off").tag(0.0)
                        Text("+10%").tag(0.10)
                        Text("+20%").tag(0.20)
                        Text("+30%").tag(0.30)
                    }
                    Picker("Eat back extra workout", selection: $plan.workoutEatBack) {
                        Text("None").tag(0.0)
                        Text("Half").tag(0.5)
                        Text("All").tag(1.0)
                    }
                }
                Section("This week") {
                    Stepper(value: $plan.weeklyCardioTarget, in: 30...600, step: 10) {
                        row("Active Zone Minutes", "\(plan.weeklyCardioTarget) min")
                    }
                    Stepper(value: $plan.exerciseDaysTarget, in: 1...7) {
                        row("Exercise days", "\(plan.exerciseDaysTarget) days")
                    }
                }
                Section {
                    let b = plan.budget(weightKg: profile.weightKg, heightCm: profile.heightCm, age: profile.age,
                                        male: profile.sex != "female", activeKcal: 0, eaten: 0)
                    row("BMR", "\(Int(b.bmr.rounded())) kcal")
                    row("Maintenance (no workouts)", "\(Int(b.maintenance.rounded())) kcal")
                    row("Daily deficit", "\(Int(b.requiredDeficit.rounded())) kcal · \(String(format: "%.2f", b.kgPerWeek)) kg/week")
                    row("Food allowance", "\(Int(b.allowance.rounded())) kcal")
                    row("Workout burn target", "\(Int(b.workoutTarget.rounded())) kcal")
                } header: {
                    Text("Your numbers")
                } footer: {
                    Text("BMR uses Mifflin–St Jeor; maintenance assumes a desk day (×1.2).")
                }
            }
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var ageBinding: Binding<Int> {
        Binding(get: { profile.age }, set: { profile.dateOfBirth = ProfileStore.dateOfBirth(forAge: $0) })
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

/// Set the goal (weight + date) and see what it means per day before saving: how much to eat and burn,
/// the deficit and weekly pace, with warnings when it is unsafe or hits the food floor.
struct GoalSheet: View {
    let currentKg: Double
    @EnvironmentObject var profile: ProfileStore
    @ObservedObject private var plan = CutPlanStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var goalKg = 75.0
    @State private var date = Date()
    @State private var share = 0.3

    private static var earliest: Date { Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date() }

    var body: some View {
        let male = profile.sex != "female"
        let b = plan.budget(weightKg: currentKg, heightCm: profile.heightCm, age: profile.age, male: male,
                            activeKcal: 0, eaten: 0, goalKg: goalKg, targetDate: date, workoutShare: share)
        let now = plan.budget(weightKg: currentKg, heightCm: profile.heightCm, age: profile.age, male: male,
                              activeKcal: 0, eaten: 0)
        // More than ~1% of body weight a week costs muscle and is hard to sustain.
        let tooFast = b.kgPerWeek > currentKg * 0.01
        return NavigationStack {
            ScrollView {
                VStack(spacing: NoopMetrics.sectionGap) {
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            Text("GOAL WEIGHT").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                            HStack {
                                Text(String(format: "%.1f kg", goalKg)).font(StrandFont.number(28, weight: .bold))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                Stepper("", value: $goalKg, in: 40...max(40, currentKg - 0.5), step: 0.5).labelsHidden()
                            }
                            Text(String(format: "%.1f kg to lose from %.1f kg", max(currentKg - goalKg, 0), currentKg))
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    NoopCard {
                        DatePicker("By", selection: $date, in: Self.earliest..., displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .tint(StrandPalette.accent)
                    }
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                            Text("DEFICIT FROM").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                            Picker("Split", selection: $share) {
                                Text("Food").tag(0.0)
                                Text("80/20").tag(0.2)
                                Text("70/30").tag(0.3)
                                Text("60/40").tag(0.4)
                                Text("50/50").tag(0.5)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: NoopMetrics.gap),
                                        GridItem(.flexible(), spacing: NoopMetrics.gap)], spacing: NoopMetrics.gap) {
                        stat("fork.knife", StrandPalette.metricAmber, n(b.allowance), "eat / day", delta: b.allowance - now.allowance)
                        stat("flame.fill", StrandPalette.metricRose, n(b.workoutTarget), "workout burn / day",
                             delta: b.workoutTarget - now.workoutTarget)
                        stat("arrow.down", StrandPalette.chargeColor, n(b.requiredDeficit), "deficit / day", delta: nil)
                        stat("scalemass", tooFast ? StrandPalette.statusCritical : StrandPalette.chargeColor,
                             String(format: "%.2f kg", b.kgPerWeek), "per week", delta: nil)
                    }
                    if tooFast {
                        Label("Faster than 1% of body weight a week", systemImage: "exclamationmark.triangle.fill")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.statusCritical)
                    }
                    if b.floorHit {
                        Label("Food is at the 1,500 kcal floor; the rest moved to workouts", systemImage: "info.circle.fill")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.statusWarning)
                    }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.vertical, NoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        plan.goalKg = goalKg
                        plan.targetDate = date
                        plan.workoutShare = share
                        dismiss()
                    }
                }
            }
            .onAppear {
                goalKg = plan.goalKg
                date = max(plan.targetDate, Self.earliest)
                share = [0.0, 0.2, 0.3, 0.4, 0.5].contains(plan.workoutShare) ? plan.workoutShare : 0.3
            }
        }
    }

    private func n(_ v: Double) -> String { Int(v.rounded()).formatted() }

    /// A preview tile; `delta` shows the change against the current plan so the effect is obvious.
    private func stat(_ icon: String, _ tint: Color, _ value: String, _ label: String, delta: Double?) -> some View {
        NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(value).font(StrandFont.number(24, weight: .bold)).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                if let delta, abs(delta) >= 1 {
                    Text((delta > 0 ? "+" : "−") + n(abs(delta)) + " vs now")
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }
}

// MARK: - sfz: Habits on the Goal page

/// Fills the automatic habits (steps, water, sleep, Active Zone Minutes, protein) for recent days,
/// marks Gym done on days the WHOOP recorded a workout, then applies challenge rules.
@MainActor
enum SfzHabitAuto {
    static func refresh(repo: Repository, plan: CutPlanStore, profile: ProfileStore, activeToday: Double,
                        stepsToday: Double?) async {
        let hrMax = profile.hrMax
        let store = SfzHabitStore.shared
        let cal = Calendar.current
        var span = 35
        if let c = store.challenge { span = max(span, min(400, SfzHabitStore.daysBetween(c.startDay, SfzHabitStore.today) + 2)) }
        let days = (0..<span).compactMap { cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: Date())) }
        let keys = days.map { Repository.localDayKey($0) }
        let todayKey = SfzHabitStore.today
        let byDay = Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { _, b in b })
        let kinds = Set(store.habits.map(\.kind))

        if kinds.contains(.steps) {
            var v: [String: Double] = [:]
            for k in keys { if let s = byDay[k]?.steps { v[k] = Double(s) } }
            if let t = stepsToday { v[todayKey] = t }
            store.setAuto(.steps, v)
        }
        if kinds.contains(.sleep) {
            var v: [String: Double] = [:]
            for k in keys { if let s = byDay[k]?.totalSleepMin { v[k] = s } }
            store.setAuto(.sleep, v)
        }
        if kinds.contains(.water) {
            var v: [String: Double] = [:]
            for r in await repo.hydrationHistory(days: span) { v[r.day] = r.value }
            store.setAuto(.water, v)
        }
        if kinds.contains(.calories) {
            // Calories eaten (with the logging buffer) against that day's food allowance from the plan.
            var eaten: [String: Double] = [:], allowance: [String: Double] = [:]
            for k in keys where !plan.entries(day: k).isEmpty {
                let e = plan.eaten(day: k)
                let active = k == todayKey ? activeToday : (plan.activeByDay[k] ?? 0)
                let b = plan.budget(weightKg: profile.weightKg, heightCm: profile.heightCm, age: profile.age,
                                    male: profile.sex != "female", activeKcal: active, eaten: e)
                eaten[k] = e
                allowance[k] = b.allowance
            }
            store.setCalorieTargets(allowance)
            store.setAuto(.calories, eaten)
        }
        if kinds.contains(.protein) {
            var v: [String: Double] = [:]
            for k in keys where !plan.entries(day: k).isEmpty { v[k] = plan.protein(day: k) }
            store.setAuto(.protein, v)
        }
        if kinds.contains(.zone) {
            var v: [String: Double] = [:]
            let fallbackRest = Double(repo.today?.restingHr ?? repo.days.last(where: { $0.restingHr != nil })?.restingHr ?? 60)
            // Past days don't change once synced, so only today and days not yet known are read.
            let known = store.auto[SfzHabitKind.zone.rawValue] ?? [:]
            for (i, day) in days.prefix(35).enumerated() where i == 0 || known[keys[i]] == nil {
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { continue }
                let b = await repo.hrBuckets(from: Int(day.timeIntervalSince1970),
                                             to: Int(next.timeIntervalSince1970) - 1, bucketSeconds: 60)
                if b.isEmpty { continue }
                let rest = byDay[keys[i]]?.restingHr.map(Double.init) ?? fallbackRest
                v[keys[i]] = Double(CutTodayView.zonePoints(b, rest: rest, hrMax: Double(hrMax)))
            }
            store.setAuto(.zone, v)
        }
        if kinds.contains(.gym) {
            let rows = await repo.workoutRows(days: 35)
            let workoutDays = Set(rows.map { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs))) })
            for h in store.habits where h.kind == .gym {
                for k in workoutDays where k >= h.createdDay && store.gymState(h.id, day: k) == nil {
                    store.setGym(h.id, .done, day: k)
                }
            }
        }
        SfzScreenTime.sync(store)
        store.enforceStrict()
        store.checkFinished()
        SfzHabitReminders.schedule(store)
    }
}

/// Colour for a day's status in calendars and badges.
func sfzStatusColor(_ s: SfzDayStatus) -> Color {
    switch s {
    case .met: return StrandPalette.chargeColor
    case .partial: return StrandPalette.statusWarning
    case .missed: return StrandPalette.statusCritical.opacity(0.75)
    case .rest: return StrandPalette.restColor.opacity(0.6)
    default: return StrandPalette.hairline
    }
}

/// A Monday-first month-style grid of days coloured by status.
struct SfzStatusGrid: View {
    let days: [Date]
    let status: (Date) -> SfzDayStatus

    var body: some View {
        let cal = Calendar.current
        let lead = days.first.map { (cal.component(.weekday, from: $0) + 5) % 7 } ?? 0
        let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { i in
                    Text(["M", "T", "W", "T", "F", "S", "S"][i]).font(.system(size: 10, design: .rounded))
                        .foregroundStyle(StrandPalette.textTertiary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 26) }
                ForEach(days, id: \.self) { d in
                    let isToday = cal.isDateInToday(d)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(sfzStatusColor(status(d)))
                        .frame(height: 26)
                        .overlay(Text("\(cal.component(.day, from: d))")
                            .font(.system(size: 10, weight: isToday ? .bold : .regular, design: .rounded))
                            .foregroundStyle(StrandPalette.textPrimary.opacity(0.8)))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(isToday ? StrandPalette.textPrimary : .clear, lineWidth: 1.5))
                }
            }
            HStack(spacing: 10) {
                legend(.met, "Met"); legend(.partial, "Partly"); legend(.missed, "Missed"); legend(.rest, "Rest")
            }
            .padding(.top, 2)
        }
    }

    private func legend(_ s: SfzDayStatus, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(sfzStatusColor(s)).frame(width: 10, height: 10)
            Text(label).font(.system(size: 10, design: .rounded)).foregroundStyle(StrandPalette.textTertiary)
        }
    }
}

/// Today's habits: a two-column grid of cards with an overall count, Add habit, and a detail page per habit.
struct SfzHabitsSection: View {
    @ObservedObject private var store = SfzHabitStore.shared
    @EnvironmentObject var ble: BLEManager
    @State private var detail: SfzHabit?
    @State private var adding = false
    @State private var editingTargets = false

    var body: some View {
        let score = store.dayScore(Date())
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(alignment: .firstTextBaseline) {
                Text("TODAY'S HABITS").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text("\(score.met) of \(score.due) done").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Button { editingTargets = true } label: {
                    Label("Targets", systemImage: "slider.horizontal.3").font(StrandFont.caption)
                        .padding(.horizontal, NoopMetrics.space3).padding(.vertical, NoopMetrics.space1)
                        .background(Capsule().fill(StrandPalette.accent.opacity(0.12)))
                }
                .buttonStyle(.plain).foregroundStyle(StrandPalette.accent)
                Button { adding = true } label: {
                    Label("Add", systemImage: "plus").font(StrandFont.caption)
                        .padding(.horizontal, NoopMetrics.space3).padding(.vertical, NoopMetrics.space1)
                        .background(Capsule().fill(StrandPalette.accent.opacity(0.12)))
                }
                .buttonStyle(.plain).foregroundStyle(StrandPalette.accent)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.hairline)
                    Capsule().fill(StrandPalette.chargeColor)
                        .frame(width: score.due > 0 && score.met > 0 ? max(8, g.size.width * CGFloat(score.met) / CGFloat(score.due)) : 0)
                }
            }
            .frame(height: 6)
            if store.habits.isEmpty {
                Text("No habits yet. Tap Add to pick push-ups, a plank timer, water and more.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: NoopMetrics.space3),
                                GridItem(.flexible(), spacing: NoopMetrics.space3)], spacing: NoopMetrics.space3) {
                ForEach(store.habits) { h in
                    SfzHabitCard(habit: h, onOpen: { detail = h }, onTargetHit: { ble.buzzStrapOnce() })
                }
            }
        }
        .sheet(item: $detail) { h in SfzHabitDetail(habitId: h.id) }
        .sheet(isPresented: $adding) { SfzAddHabitSheet() }
        .sheet(isPresented: $editingTargets) { SfzTargetsSheet() }
    }
}

/// One habit on the Goal page. Counter: +1 / +5 / +10. Timer: Start / Stop. Yes / No: one tap.
/// Gym: Done, Skip or Rest. Automatic habits fill themselves. Tap the card for the detail page.
struct SfzHabitCard: View {
    let habit: SfzHabit
    var onOpen: () -> Void
    var onTargetHit: () -> Void
    @ObservedObject private var store = SfzHabitStore.shared
    @State private var pickingParts = false

    private var today: String { SfzHabitStore.today }
    private var target: Double { habit.target(on: today) }
    private var due: Bool { habit.isDue(on: Date()) }
    private var status: SfzDayStatus { store.status(habit, on: Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: 6) {
                Image(systemName: habit.icon).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(status == .met ? StrandPalette.chargeColor : StrandPalette.accent)
                    .frame(width: 18)
                Text(habit.name).font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                if !habit.reminders.isEmpty {
                    HStack(spacing: 1) {
                        Image(systemName: "bell.fill").font(.system(size: 9))
                        if habit.reminders.count > 1 { Text("\(habit.reminders.count)").font(.system(size: 9, weight: .semibold)) }
                    }
                    .foregroundStyle(StrandPalette.textTertiary)
                }
                if status == .met {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(StrandPalette.chargeColor)
                }
            }
            if due {
                content
            } else {
                Spacer(minLength: 0)
                Text("Not due today").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(StrandPalette.surfaceRaised))
        .opacity(due ? 1 : 0.6)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture(perform: onOpen)
    }

    @ViewBuilder private var content: some View {
        switch habit.kind {
        case .counter: counter
        case .timer: timer
        case .check: check
        case .gym: gymRow
        case .screen: SfzScreenCardBody(habit: habit, status: status)
        case .calories: caloriesValue
        default: autoValue
        }
    }

    private func bar(_ frac: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.hairline)
                Capsule().fill(frac >= 1 ? StrandPalette.chargeColor : StrandPalette.accent)
                    .frame(width: frac > 0 ? max(6, g.size.width * CGFloat(min(frac, 1))) : 0)
            }
        }
        .frame(height: 6)
    }

    private func valueLine(_ v: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(habit.kind.format(v)).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text("/ \(habit.kind.format(target))").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func chip(_ label: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(StrandFont.caption.weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(Capsule().fill(filled ? StrandPalette.accent : StrandPalette.accent.opacity(0.12)))
                .foregroundStyle(filled ? Color.white : StrandPalette.accent)
        }
        .buttonStyle(.plain)
    }

    private var counter: some View {
        let v = store.value(habit, day: today) ?? 0
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            valueLine(v)
            bar(v / max(target, 1))
            HStack(spacing: 6) {
                chip("+1") { store.log(habit.id, 1) }
                chip("+5") { store.log(habit.id, 5) }
                chip("+10") { store.log(habit.id, 10) }
            }
        }
    }

    private var timer: some View {
        let running = store.isRunning(habit.id)
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            TimelineView(.periodic(from: .now, by: running ? 1 : 60)) { ctx in
                let secs = store.timerSeconds(habit.id, now: ctx.date)
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    valueLine(secs)
                    bar(secs / max(target, 1))
                }
            }
            chip(running ? "Stop" : "Start", filled: running) {
                if running {
                    store.stopTimer(habit.id)
                    SfzHabitReminders.cancelTimerAlert(habit)
                } else {
                    let remaining = target - store.timerSeconds(habit.id)
                    store.startTimer(habit.id)
                    if remaining > 0 {
                        SfzHabitReminders.timerAlert(habit, after: remaining)
                        let id = habit.id
                        let hit = onTargetHit
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                            if SfzHabitStore.shared.isRunning(id) { hit() }
                        }
                    }
                }
            }
        }
    }

    private var check: some View {
        let done = status == .met
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Spacer(minLength: 0)
            Button { store.toggleCheck(habit.id) } label: {
                HStack {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.system(size: 22))
                    Text(done ? "Done" : "Mark done").font(StrandFont.subhead)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(Capsule().fill(done ? StrandPalette.chargeColor.opacity(0.15) : StrandPalette.accent.opacity(0.10)))
                .foregroundStyle(done ? StrandPalette.chargeColor : StrandPalette.accent)
            }
            .buttonStyle(.plain)
            Text(store.streak(habit) > 0 ? "\(store.streak(habit))-day streak" : " ")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var gymRow: some View {
        let st = store.gymState(habit.id)
        let parts = store.gymParts(habit.id)
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(st == .done ? (parts.isEmpty ? "Done" : parts.joined(separator: " · "))
                 : st == .rest ? "Rest day" : st == .skipped ? "Skipped" : "Not yet")
                .font(parts.isEmpty ? StrandFont.title2 : StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(2).minimumScaleFactor(0.7)
            HStack(spacing: 6) {
                chip("Done", filled: st == .done) {
                    if st == .done { store.setGym(habit.id, nil) } else { store.setGym(habit.id, .done); pickingParts = true }
                }
                chip("Skip", filled: st == .skipped) { store.setGym(habit.id, st == .skipped ? nil : .skipped) }
                chip("Rest", filled: st == .rest) { store.setGym(habit.id, st == .rest ? nil : .rest) }
            }
            if st == .done {
                Button { pickingParts = true } label: {
                    Text(parts.isEmpty ? "What did you train?" : "Change")
                        .font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            } else {
                Text("\(habit.restPerWeek) rest days a week").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .sheet(isPresented: $pickingParts) { SfzGymPartsSheet(habitId: habit.id) }
    }

    /// Linked to the calorie card: today's food against today's allowance.
    private var caloriesValue: some View {
        let eaten = store.value(habit, day: today) ?? 0
        let allowance = store.auto["caloriesTarget"]?[today]
        let over = allowance.map { eaten > $0 } ?? false
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(eaten.rounded()).formatted())").font(StrandFont.title2)
                    .foregroundStyle(over ? StrandPalette.statusCritical : StrandPalette.textPrimary)
                Text(allowance.map { "/ \(Int($0.rounded()).formatted()) kcal" } ?? "kcal")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            bar(allowance.map { eaten / max($0, 1) } ?? 0)
            Spacer(minLength: 0)
            Text(over ? "Over today's target" : eaten == 0 ? "Log food below" : "Within target so far")
                .font(StrandFont.caption)
                .foregroundStyle(over ? StrandPalette.statusCritical : StrandPalette.textTertiary)
        }
    }

    private var autoValue: some View {
        let v = store.value(habit, day: today) ?? 0
        let source: String = {
            switch habit.kind {
            case .steps: return "From your WHOOP and iPhone"
            case .water: return "From your water log"
            case .sleep: return "Last night, from your WHOOP"
            case .zone: return "From your WHOOP"
            case .protein: return "From your food log"
            default: return ""
            }
        }()
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            valueLine(v)
            bar(v / max(target, 1))
            Spacer(minLength: 0)
            Text(source).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// Everything about one habit: today's log, streaks and a five-week calendar, the target (changes
/// apply from tomorrow unless you choose today), days, reminders, name, and removing it.
struct SfzHabitDetail: View {
    let habitId: UUID
    @ObservedObject private var store = SfzHabitStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draftTarget: Double = 0
    @State private var applyToday = false
    @State private var newReminder = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var name = ""
    @State private var confirmLower = false
    @State private var confirmRemove = false

    private var today: String { SfzHabitStore.today }
    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]
    private static let weekdayLetters = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        NavigationStack {
            Group {
                if let h = store.habit(habitId) {
                    form(h)
                } else {
                    Text("This habit was removed.").foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .navigationTitle(store.habit(habitId)?.name ?? "Habit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear {
            if let h = store.habit(habitId) { draftTarget = h.target(on: today); name = h.name }
        }
    }

    private var lowersStrictChallenge: Bool {
        guard let c = store.challenge, c.strict, c.endedDay == nil, c.habitIds.contains(habitId),
              let h = store.habit(habitId) else { return false }
        return draftTarget < h.target(on: today)
    }

    private func saveTarget() {
        store.setTarget(habitId, to: draftTarget, fromToday: applyToday)
        SfzScreenTime.sync(store)
    }

    @ViewBuilder private func form(_ h: SfzHabit) -> some View {
        Form {
            if h.kind == .screen { SfzScreenSetupSection(habit: h) }
            Section("Today") { todayRows(h) }

            Section("Progress") {
                HStack {
                    stat("\(store.streak(h))", "Streak")
                    stat("\(store.bestStreak(h))", "Best")
                    stat(store.consistency(h).map { "\(Int(($0 * 100).rounded()))%" } ?? "–", "Last 30 days")
                }
                SfzStatusGrid(days: Self.lastFiveWeeks) { store.status(h, on: $0) }
                    .padding(.vertical, 4)
            }

            if h.kind.hasTarget {
                Section {
                    Stepper(value: $draftTarget, in: h.kind.targetRange, step: h.kind.targetStep) {
                        HStack {
                            Text("Target")
                            Spacer()
                            Text(h.kind.format(draftTarget)).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    Toggle("Apply from today", isOn: $applyToday).tint(StrandPalette.accent)
                    Button("Save target") {
                        if lowersStrictChallenge { confirmLower = true } else { saveTarget() }
                    }
                    .disabled(draftTarget == h.target(on: applyToday ? today : SfzHabitStore.dayKey(offset: 1, from: today)))
                } header: {
                    Text(h.kind == .screen ? "Daily limit" : "Target")
                } footer: {
                    Text("Changes start tomorrow unless you choose today. Past days keep the target they had.")
                }
            }

            if h.kind == .gym {
                Section {
                    SfzGymPartsGrid(habitId: h.id)
                    let counts = store.gymPartCounts(h.id)
                    if !counts.isEmpty {
                        Text(counts.prefix(8).map { "\($0.part) \($0.count)×" }.joined(separator: " · "))
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                } header: {
                    Text("What you trained today")
                } footer: {
                    Text("Under the grid: how often you trained each in the last 30 days, so a skipped leg day shows.")
                }
                Section("Rest days") {
                    Stepper(value: Binding(get: { h.restPerWeek }, set: { var x = h; x.restPerWeek = $0; store.update(x) }),
                            in: 0...6) {
                        HStack { Text("Rest days a week"); Spacer(); Text("\(h.restPerWeek)").foregroundStyle(StrandPalette.textSecondary) }
                    }
                }
            }

            Section {
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { i in
                        let wd = Self.weekdayOrder[i]
                        let on = h.weekdays.isEmpty || h.weekdays.contains(wd)
                        Button {
                            var x = h
                            var set = Set(x.weekdays.isEmpty ? Self.weekdayOrder : x.weekdays)
                            if set.contains(wd) { set.remove(wd) } else { set.insert(wd) }
                            x.weekdays = set.count == 7 || set.isEmpty ? [] : Array(set).sorted()
                            store.update(x)
                        } label: {
                            Text(Self.weekdayLetters[i]).font(StrandFont.subhead.weight(.semibold))
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(on ? StrandPalette.accent : StrandPalette.hairline))
                                .foregroundStyle(on ? Color.white : StrandPalette.textSecondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Days")
            } footer: {
                Text(h.weekdays.isEmpty ? "Every day." : "Only on the days shown. Other days don't count against you.")
            }

            Section {
                ForEach(h.reminders.sorted(), id: \.self) { m in
                    HStack {
                        Image(systemName: "bell").foregroundStyle(StrandPalette.accent)
                        Text(Self.clock(m))
                        Spacer()
                        Button(role: .destructive) {
                            var x = h; x.reminders.removeAll { $0 == m }; store.update(x)
                        } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(StrandPalette.statusCritical)
                    }
                }
                HStack(spacing: 6) {
                    ForEach([7 * 60, 9 * 60, 13 * 60, 18 * 60, 21 * 60], id: \.self) { m in
                        Button(Self.clock(m)) {
                            var x = h
                            if !x.reminders.contains(m) { x.reminders.append(m) }
                            store.update(x)
                            SfzHabitReminders.requestPermission()
                        }
                        .font(StrandFont.caption)
                        .buttonStyle(.borderless)
                        .disabled(h.reminders.contains(m))
                        .frame(maxWidth: .infinity)
                    }
                }
                HStack {
                    DatePicker("Other time", selection: $newReminder, displayedComponents: .hourAndMinute)
                    Button("Add") {
                        let c = Calendar.current.dateComponents([.hour, .minute], from: newReminder)
                        let m = (c.hour ?? 8) * 60 + (c.minute ?? 0)
                        var x = h
                        if !x.reminders.contains(m) { x.reminders.append(m) }
                        store.update(x)
                        SfzHabitReminders.requestPermission()
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("Reminders")
            } footer: {
                Text("Add as many as you like. Tap a time above, or pick another. A reminder is skipped once the habit is done for the day.")
            }

            Section("Name") {
                TextField("Name", text: $name)
                    .onSubmit { renameIfNeeded(h) }
                Button("Save name") { renameIfNeeded(h) }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == h.name)
            }

            if let c = store.challenge, c.endedDay == nil, !c.habitIds.contains(h.id) {
                Section {
                    Button("Add to \(c.name)") { store.addToChallenge(h.id) }
                } footer: {
                    Text("It counts toward the challenge from tomorrow.")
                }
            }

            Section {
                Button("Move up") { store.move(h.id, by: -1) }
                Button("Move down") { store.move(h.id, by: 1) }
                Button("Remove habit", role: .destructive) { confirmRemove = true }
            }
        }
        .alert("Lower a challenge target?", isPresented: $confirmLower) {
            Button("Lower it", role: .destructive) { saveTarget() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("This is a strict challenge. Lowering a target marks it Modified.")
        }
        .confirmationDialog("Remove \(h.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { store.remove(h.id); dismiss() }
        } message: {
            Text(store.challenge?.habitIds.contains(h.id) == true
                 ? "It is part of your challenge. Its past days are kept."
                 : "Its past days are kept.")
        }
    }

    private func renameIfNeeded(_ h: SfzHabit) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != h.name else { return }
        var x = h; x.name = n; store.update(x)
    }

    @ViewBuilder private func todayRows(_ h: SfzHabit) -> some View {
        switch h.kind {
        case .counter, .timer:
            let entries = store.entries(h.id)
            HStack {
                Text(h.kind.format(h.kind == .timer ? store.timerSeconds(h.id) : entries.reduce(0, +)))
                    .font(StrandFont.title2)
                Text("of \(h.kind.format(h.target(on: today)))").foregroundStyle(StrandPalette.textSecondary)
            }
            if !entries.isEmpty {
                Text(entries.map { h.kind == .timer ? h.kind.format($0) : "+\(Int($0))" }.joined(separator: "  "))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Button("Undo last") { store.undo(h.id) }
            }
            if h.kind == .counter {
                HStack {
                    ForEach([1, 5, 10, 25], id: \.self) { n in
                        Button("+\(n)") { store.log(h.id, Double(n)) }.buttonStyle(.borderless)
                    }
                }
            }
        case .check:
            Toggle("Done today", isOn: Binding(get: { !store.entries(h.id).isEmpty }, set: { _ in store.toggleCheck(h.id) }))
                .tint(StrandPalette.chargeColor)
        case .screen:
            Text(store.status(h, on: Date()) == .missed ? "Over the limit today: missed" : "Under the limit so far today")
                .foregroundStyle(store.status(h, on: Date()) == .missed ? StrandPalette.statusCritical : StrandPalette.chargeColor)
        case .gym:
            Picker("Today", selection: Binding(get: { store.gymState(h.id).map(\.rawValue) ?? "" },
                                               set: { store.setGym(h.id, SfzGymState(rawValue: $0)) })) {
                Text("Not yet").tag("")
                Text("Done").tag("done")
                Text("Skipped").tag("skipped")
                Text("Rest").tag("rest")
            }
            .pickerStyle(.segmented)
        default:
            HStack {
                Text(h.kind.format(store.value(h, day: today) ?? 0)).font(StrandFont.title2)
                Text("of \(h.kind.format(h.target(on: today)))").foregroundStyle(StrandPalette.textSecondary)
            }
            if h.kind == .water {
                NavigationLink("Open the water log") { HydrationView() }
            }
            Text(h.kind.label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    static var lastFiveWeeks: [Date] {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let today = cal.startOfDay(for: Date())
        let monday = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let start = cal.date(byAdding: .day, value: -28, to: monday) ?? monday
        return (0..<35).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    static func clock(_ minutes: Int) -> String {
        var c = DateComponents(); c.hour = minutes / 60; c.minute = minutes % 60
        return (Calendar.current.date(from: c) ?? Date()).formatted(date: .omitted, time: .shortened)
    }
}

/// Add a habit from the presets, or make your own.
struct SfzAddHabitSheet: View {
    @ObservedObject private var store = SfzHabitStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: SfzHabitKind = .counter
    @State private var target: Double = SfzHabitKind.counter.defaultTarget

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    let taken = Set(store.habits.map { $0.name.lowercased() })
                    let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
                    LazyVGrid(columns: cols, spacing: 8) {
                        ForEach(SfzHabitStore.presets.indices, id: \.self) { i in
                            let p = SfzHabitStore.presets[i]
                            let added = taken.contains(p.name.lowercased())
                            Button {
                                if !added { store.add(SfzHabitStore.make(p)) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Image(systemName: p.icon).foregroundStyle(StrandPalette.accent)
                                        Spacer()
                                        Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                                            .foregroundStyle(added ? StrandPalette.chargeColor : StrandPalette.accent)
                                    }
                                    Text(p.name).font(StrandFont.subhead.weight(.semibold))
                                        .foregroundStyle(StrandPalette.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
                                    Text(p.kind.hasTarget ? p.kind.format(p.target) : (p.kind == .gym ? "Done / skip / rest" : "Yes / no"))
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.surfaceRaised))
                                .opacity(added ? 0.6 : 1)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Tap to add")
                }

                Section {
                    TextField("Name, e.g. Lunges", text: $name)
                    Picker("Type", selection: $kind) {
                        ForEach(SfzHabitKind.allCases.filter { $0 != .screen }) { k in Text(k.label).tag(k) }
                    }
                    .onChange(of: kind) { _, k in target = k.defaultTarget }
                    if kind.hasTarget {
                        Stepper(value: $target, in: kind.targetRange, step: kind.targetStep) {
                            HStack { Text("Target"); Spacer(); Text(kind.format(target)).foregroundStyle(StrandPalette.textSecondary) }
                        }
                    }
                    Button("Add habit") {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        store.add(SfzHabitStore.make(.init(name: n, icon: kind.defaultIcon, kind: kind, target: target)))
                        name = ""
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Your own")
                }
            }
            .navigationTitle("Add habit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - sfz: Challenges

/// The challenge at the top of the Goal page: Day X of N, today's checklist, streak and consistency.
/// With none running, a short invitation to start one.
struct SfzChallengeCard: View {
    @ObservedObject private var store = SfzHabitStore.shared
    @State private var picking = false
    @State private var showing = false

    var body: some View {
        Group {
            if let c = store.challenge {
                active(c)
                    .contentShape(Rectangle())
                    .onTapGesture { showing = true }
            } else {
                Button { picking = true } label: { invite }.buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $picking) { SfzChallengePicker() }
        .sheet(isPresented: $showing) { SfzChallengeDetail() }
    }

    private var invite: some View {
        NoopCard {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: "flag.checkered").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start a challenge").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text("75 Hard, 75 Soft, 30-day push-ups, or your own.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func active(_ c: SfzChallenge) -> some View {
        let n = min(store.dayNumber(c), c.length)
        let done = c.endedDay != nil
        let habits = store.challengeHabits(c)
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack {
                    Text("\(c.name.uppercased()) · \(c.strict ? "STRICT" : "FLEXIBLE")\(c.modified ? " · MODIFIED" : "")")
                        .font(StrandFont.overline).tracking(1.4).foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer()
                    Image(systemName: "chevron.right").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Text(done ? "Completed: \(c.length) days"
                     : c.effectiveStart > SfzHabitStore.today ? "Starts tomorrow · \(c.length) days" : "Day \(n) of \(c.length)")
                    .font(StrandFont.title2).foregroundStyle(done ? StrandPalette.chargeColor : StrandPalette.textPrimary)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StrandPalette.hairline)
                        Capsule().fill(StrandPalette.chargeColor)
                            .frame(width: max(8, g.size.width * CGFloat(done ? 1 : Double(n - 1) / Double(max(c.length, 1)))))
                    }
                }
                .frame(height: 8)
                if let miss = c.pendingMissDay {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("You missed \(SfzHabitStore.date(miss).formatted(.dateTime.weekday(.wide).day().month(.abbreviated))).")
                            .font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.statusWarning)
                        Text("Strict means starting again from Day 1. Or switch to Flexible: the miss lowers your consistency and you carry on.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        HStack(spacing: NoopMetrics.space2) {
                            Button { store.resolveMiss(restart: true) } label: {
                                Text("Restart Day 1").font(StrandFont.subhead).frame(maxWidth: .infinity).padding(.vertical, 8)
                                    .background(Capsule().fill(StrandPalette.statusCritical.opacity(0.14)))
                                    .foregroundStyle(StrandPalette.statusCritical)
                            }
                            .buttonStyle(.plain)
                            Button { store.resolveMiss(restart: false) } label: {
                                Text("Switch to Flexible").font(StrandFont.subhead).frame(maxWidth: .infinity).padding(.vertical, 8)
                                    .background(Capsule().fill(StrandPalette.accent.opacity(0.14)))
                                    .foregroundStyle(StrandPalette.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(NoopMetrics.space3)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.statusWarning.opacity(0.10)))
                }
                if !done {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(habits) { h in
                            let st = store.status(h, on: Date())
                            HStack(spacing: 8) {
                                Image(systemName: st == .met ? "checkmark.circle.fill" : st == .partial ? "circle.lefthalf.filled" : st == .rest ? "moon.circle" : "circle")
                                    .foregroundStyle(st == .met ? StrandPalette.chargeColor : StrandPalette.textTertiary)
                                Text(h.name).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                if h.kind.hasTarget {
                                    Text("\(h.kind.format(h.kind == .timer ? store.timerSeconds(h.id) : (store.value(h, day: SfzHabitStore.today) ?? 0))) / \(h.kind.format(h.target(on: SfzHabitStore.today)))")
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                }
                            }
                        }
                    }
                }
                let pct = store.challengeConsistency(c).map { "\(Int(($0 * 100).rounded()))% consistent" } ?? "Consistency shows after day 1"
                Text("\(store.challengeStreak(c))-day streak · \(pct)")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}

/// Choose a challenge template, or build your own.
struct SfzChallengePicker: View {
    @ObservedObject private var store = SfzHabitStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let c = store.challenge, c.endedDay == nil {
                    Section {
                        Text("Starting a new challenge ends \(c.name) (day \(store.dayNumber(c)) of \(c.length)).")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                    }
                }
                Section("Templates") {
                    ForEach(SfzChallengeTemplate.all) { t in
                        NavigationLink {
                            SfzChallengeSetup(template: t, onStarted: { dismiss() })
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(t.name).font(StrandFont.headline)
                                    Spacer()
                                    Text("\(t.length) days · \(t.strict ? "Strict" : "Flexible")")
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                }
                                Text(t.blurb).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                Section("Your own") {
                    NavigationLink {
                        SfzChallengeSetup(template: nil, onStarted: { dismiss() })
                    } label: {
                        Label("Custom challenge", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .navigationTitle("Start a challenge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Name, length, mode, start day and habits for a new challenge.
struct SfzChallengeSetup: View {
    let template: SfzChallengeTemplate?
    var onStarted: () -> Void
    @ObservedObject private var store = SfzHabitStore.shared
    @State private var name = ""
    @State private var length = 30
    @State private var strict = false
    @State private var startTomorrow = false
    @State private var chosen: Set<UUID> = []
    /// Targets for the template's habits and for chosen habits, set here so nothing needs editing card by card.
    @State private var specTargets: [Double] = []
    @State private var overrides: [UUID: Double] = [:]

    var body: some View {
        Form {
            Section("Challenge") {
                TextField("Name", text: $name)
                Stepper(value: $length, in: 7...365) {
                    HStack { Text("Length"); Spacer(); Text("\(length) days").foregroundStyle(StrandPalette.textSecondary) }
                }
                Picker("Start", selection: $startTomorrow) {
                    Text("Today").tag(false)
                    Text("Tomorrow").tag(true)
                }
                .pickerStyle(.segmented)
            }
            Section {
                Picker("Mode", selection: $strict) {
                    Text("Flexible").tag(false)
                    Text("Strict").tag(true)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Mode")
            } footer: {
                Text(strict
                     ? "Strict: miss anything on a day and you go back to Day 1. Lowering a target marks the challenge Modified."
                     : "Flexible: a missed day lowers your consistency but the challenge carries on. You can pause a day for illness or travel.")
            }
            if let t = template, !t.habits.isEmpty {
                Section {
                    ForEach(t.habits.indices, id: \.self) { i in
                        let spec = t.habits[i]
                        if spec.kind.hasTarget, i < specTargets.count {
                            Stepper(value: $specTargets[i], in: spec.kind.targetRange, step: spec.kind.targetStep) {
                                HStack {
                                    Image(systemName: spec.icon).foregroundStyle(StrandPalette.accent).frame(width: 24)
                                    Text(spec.name)
                                    Spacer()
                                    Text(spec.kind.format(specTargets[i])).foregroundStyle(StrandPalette.textSecondary)
                                }
                            }
                        } else {
                            HStack {
                                Image(systemName: spec.icon).foregroundStyle(StrandPalette.accent).frame(width: 24)
                                Text(spec.name)
                                Spacer()
                                Text("Yes / no").foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                    }
                } header: {
                    Text("Every day")
                } footer: {
                    Text("Set each target here. Habits you already have are reused; the rest are added to your Goal page.")
                }
            }
            Section {
                ForEach(store.habits) { h in
                    Button {
                        if chosen.contains(h.id) { chosen.remove(h.id) } else { chosen.insert(h.id) }
                    } label: {
                        HStack {
                            Image(systemName: chosen.contains(h.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosen.contains(h.id) ? StrandPalette.accent : StrandPalette.textTertiary)
                            Text(h.name).foregroundStyle(StrandPalette.textPrimary)
                        }
                    }
                    if chosen.contains(h.id), h.kind.hasTarget {
                        Stepper(value: Binding(get: { overrides[h.id] ?? h.target(on: SfzHabitStore.today) },
                                               set: { overrides[h.id] = $0 }),
                                in: h.kind.targetRange, step: h.kind.targetStep) {
                            HStack {
                                Text("Target").foregroundStyle(StrandPalette.textSecondary)
                                Spacer()
                                Text(h.kind.format(overrides[h.id] ?? h.target(on: SfzHabitStore.today)))
                            }
                        }
                        .padding(.leading, 28)
                    }
                }
            } header: {
                Text(template?.habits.isEmpty == false ? "Also include" : "Habits")
            }
            Section {
                Button("Start challenge") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    var specs = template?.habits ?? []
                    for i in specs.indices where i < specTargets.count {
                        specs[i] = .init(name: specs[i].name, icon: specs[i].icon, kind: specs[i].kind,
                                         target: specTargets[i], rest: specs[i].rest)
                    }
                    store.start(name: n.isEmpty ? (template?.name ?? "My challenge") : n, length: length, strict: strict,
                                specs: specs, habitIds: Array(chosen), startTomorrow: startTomorrow,
                                targetOverrides: overrides.filter { chosen.contains($0.key) })
                    onStarted()
                }
                .disabled((template?.habits.isEmpty ?? true) && chosen.isEmpty)
            }
        }
        .navigationTitle(template?.name ?? "Custom challenge")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = template?.name ?? "My challenge"
            length = template?.length ?? 30
            strict = template?.strict ?? false
            if template?.id == "90day" { chosen = Set(store.habits.map(\.id)) }
            if specTargets.isEmpty { specTargets = (template?.habits ?? []).map(\.target) }
        }
    }
}

/// The running challenge in full: progress, the whole calendar, today's habits, the change log, and
/// pause, restart or end.
struct SfzChallengeDetail: View {
    @ObservedObject private var store = SfzHabitStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEnd = false
    @State private var confirmRestart = false
    @State private var picking = false
    @State private var editingTargets = false

    var body: some View {
        NavigationStack {
            Group {
                if let c = store.challenge { content(c) } else { Text("No challenge running.") }
            }
            .navigationTitle(store.challenge?.name ?? "Challenge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .sheet(isPresented: $picking) { SfzChallengePicker() }
        .sheet(isPresented: $editingTargets) { SfzTargetsSheet(onlyChallenge: true) }
    }

    private func calendarDays(_ c: SfzChallenge) -> [Date] {
        let start = c.startDay
        let total = max(c.length + c.pausedDays.count + SfzHabitStore.daysBetween(c.startDay, c.effectiveStart), 1)
        let shown = min(total, 400)
        return (0..<shown).map { SfzHabitStore.date(SfzHabitStore.dayKey(offset: $0, from: start)) }
    }

    @ViewBuilder private func content(_ c: SfzChallenge) -> some View {
        let n = min(store.dayNumber(c), c.length)
        Form {
            Section {
                HStack {
                    stat(c.endedDay == nil ? "\(n)" : "\(c.length)", "of \(c.length) days")
                    stat("\(store.challengeStreak(c))", "Streak")
                    stat(store.challengeConsistency(c).map { "\(Int(($0 * 100).rounded()))%" } ?? "–", "Consistent")
                }
                Text(summary(c)).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            Section("Calendar") {
                SfzStatusGrid(days: calendarDays(c)) { store.challengeStatus(c, on: $0) }
                    .padding(.vertical, 4)
            }
            Section("Today") {
                ForEach(store.challengeHabits(c)) { h in
                    let st = store.status(h, on: Date())
                    HStack {
                        Image(systemName: h.icon).foregroundStyle(StrandPalette.accent).frame(width: 24)
                        Text(h.name)
                        Spacer()
                        Text(st == .met ? "Done" : st == .rest ? "Rest" : st == .notDue ? "Not due" : "To do")
                            .foregroundStyle(st == .met ? StrandPalette.chargeColor : StrandPalette.textSecondary)
                    }
                }
            }
            if !c.notes.isEmpty {
                Section("Changes") {
                    ForEach(Array(c.notes.indices.reversed()), id: \.self) { i in
                        Text(c.notes[i]).font(StrandFont.caption)
                    }
                }
            }
            Section {
                if c.endedDay != nil {
                    Button("Finish and keep the record") { store.endChallenge(); dismiss() }
                    Button("Start another challenge") { picking = true }
                } else {
                    if !c.strict {
                        Button("Pause today (sick or travelling)") { store.pauseToday() }
                            .disabled(c.pausedDays.contains(SfzHabitStore.today))
                    }
                    if c.pendingMissDay != nil {
                        Button("Missed a day: restart from Day 1") { store.resolveMiss(restart: true) }
                        Button("Missed a day: switch to Flexible") { store.resolveMiss(restart: false) }
                    }
                    if c.strict {
                        Button("Switch to Flexible") { store.setStrict(false) }
                    } else {
                        Button("Switch to Strict from today") { store.setStrict(true) }
                    }
                    Button("Edit targets") { editingTargets = true }
                    Button("Restart from Day 1") { confirmRestart = true }
                    Button("End challenge", role: .destructive) { confirmEnd = true }
                }
            } footer: {
                Text("Target changes start tomorrow and never change past days. In a strict challenge, raising a target is fine; lowering one or removing a habit marks it Modified.")
            }
        }
        .alert("Restart from Day 1?", isPresented: $confirmRestart) {
            Button("Restart", role: .destructive) { store.restartChallenge() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("End \(c.name)?", isPresented: $confirmEnd) {
            Button("End", role: .destructive) { store.endChallenge(); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your record so far is kept.")
        }
    }

    private func summary(_ c: SfzChallenge) -> String {
        var parts: [String] = [c.strict ? "Strict" : "Flexible"]
        if c.modified { parts.append("modified") }
        parts.append("started " + SfzHabitStore.date(c.startDay).formatted(.dateTime.day().month(.wide)))
        if !c.restartDays.isEmpty { parts.append("\(c.restartDays.count) restart" + (c.restartDays.count == 1 ? "" : "s")) }
        return parts.joined(separator: " · ")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}


/// A one-line habits summary on Today; tapping it opens the Goal tab.
struct SfzTodayHabitsStrip: View {
    @ObservedObject private var store = SfzHabitStore.shared

    var body: some View {
        let score = store.dayScore(Date())
        if score.due > 0 || store.challenge != nil {
            Button {
                NotificationCenter.default.post(name: Notification.Name("sfz.openGoal"), object: nil)
            } label: {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        HStack {
                            Image(systemName: "checklist").foregroundStyle(StrandPalette.chargeColor)
                            Text("Habits \(score.met) of \(score.due) today")
                                .font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            if let c = store.challenge, c.endedDay == nil, c.effectiveStart <= SfzHabitStore.today {
                                Text("\(c.name) · Day \(min(store.dayNumber(c), c.length))")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.right").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(StrandPalette.hairline)
                                Capsule().fill(StrandPalette.chargeColor)
                                    .frame(width: score.met > 0 ? max(6, g.size.width * CGFloat(score.met) / CGFloat(max(score.due, 1))) : 0)
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}


/// Every target on one page: each habit's daily target and the weekly goals, saved together. Changes
/// start tomorrow unless you choose today; past days keep the targets they had.
struct SfzTargetsSheet: View {
    var onlyChallenge = false
    @ObservedObject private var store = SfzHabitStore.shared
    @ObservedObject private var plan = CutPlanStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [UUID: Double] = [:]
    @State private var fromToday = false
    @State private var confirmLower = false
    @State private var detail: SfzHabit?

    private var list: [SfzHabit] {
        guard onlyChallenge, let c = store.challenge else { return store.habits }
        return store.challengeHabits(c)
    }

    private var effectiveDay: String { fromToday ? SfzHabitStore.today : SfzHabitStore.dayKey(offset: 1, from: SfzHabitStore.today) }

    private var changes: [(SfzHabit, Double)] {
        list.compactMap { h in
            guard let v = draft[h.id], v != h.target(on: effectiveDay) else { return nil }
            return (h, v)
        }
    }

    private var lowersStrict: Bool {
        guard let c = store.challenge, c.strict, c.endedDay == nil else { return false }
        return changes.contains { c.habitIds.contains($0.0.id) && $0.1 < $0.0.target(on: SfzHabitStore.today) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Apply from today", isOn: $fromToday).tint(StrandPalette.accent)
                } footer: {
                    Text("Off: changes start tomorrow, so today isn't suddenly missed. Past days always keep the target they had.")
                }
                Section("Daily targets") {
                    ForEach(list) { h in
                        if h.kind.hasTarget {
                            Stepper(value: Binding(get: { draft[h.id] ?? h.target(on: effectiveDay) },
                                                   set: { draft[h.id] = $0 }),
                                    in: h.kind.targetRange, step: h.kind.targetStep) {
                                row(h, h.kind.format(draft[h.id] ?? h.target(on: effectiveDay)))
                            }
                        } else {
                            row(h, h.kind == .gym ? "\(h.restPerWeek) rest days a week" : "Yes / no")
                        }
                    }
                }
                if !onlyChallenge {
                    Section("Weekly") {
                        Stepper(value: $plan.weeklyCardioTarget, in: 30...600, step: 10) {
                            HStack { Text("Active Zone Minutes"); Spacer(); Text("\(plan.weeklyCardioTarget) min").foregroundStyle(StrandPalette.textSecondary) }
                        }
                        Stepper(value: $plan.exerciseDaysTarget, in: 1...7) {
                            HStack { Text("Exercise days"); Spacer(); Text("\(plan.exerciseDaysTarget) days").foregroundStyle(StrandPalette.textSecondary) }
                        }
                    }
                    Section {
                        Stepper(value: $plan.proteinPerKg, in: 1.0...3.0, step: 0.1) {
                            HStack {
                                Text("Protein")
                                Spacer()
                                Text("\(Int(plan.proteinTarget.rounded())) g a day").foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                    } header: {
                        Text("Food")
                    } footer: {
                        Text(String(format: "%.1f g for each kg of your goal weight. Shown on the Goal page under Protein.", plan.proteinPerKg))
                    }
                }
                Section {
                    Button("Save \(changes.count) change\(changes.count == 1 ? "" : "s")") {
                        if lowersStrict { confirmLower = true } else { save() }
                    }
                    .disabled(changes.isEmpty)
                } footer: {
                    Text("Tap a habit's bell for its reminders, days and history.")
                }
            }
            .navigationTitle(onlyChallenge ? "Challenge targets" : "Targets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Lower a challenge target?", isPresented: $confirmLower) {
                Button("Lower it", role: .destructive) { save() }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("This is a strict challenge. Lowering a target marks it Modified.")
            }
        }
        .sheet(item: $detail) { h in SfzHabitDetail(habitId: h.id) }
    }

    private func row(_ h: SfzHabit, _ value: String) -> some View {
        HStack {
            Image(systemName: h.icon).foregroundStyle(StrandPalette.accent).frame(width: 24)
            Text(h.name)
            Spacer()
            Text(value).foregroundStyle(StrandPalette.textSecondary)
            Button { detail = h } label: {
                Image(systemName: h.reminders.isEmpty ? "bell" : "bell.fill")
                    .foregroundStyle(h.reminders.isEmpty ? StrandPalette.textTertiary : StrandPalette.accent)
            }
            .buttonStyle(.borderless)
        }
    }

    private func save() {
        for (h, v) in changes { store.setTarget(h.id, to: v, fromToday: fromToday) }
        draft = [:]
        SfzScreenTime.sync(store)
    }
}

/// A GitHub-style grid of the last 20 weeks: one square a day, greener the more of that day's habits
/// were met, red when none were, grey when nothing was due.
struct SfzConsistencyHeatmap: View {
    @ObservedObject private var store = SfzHabitStore.shared

    private static let weeks = 20

    private var columns: [[Date]] {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let today = cal.startOfDay(for: Date())
        let monday = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        guard let first = cal.date(byAdding: .day, value: -7 * (Self.weeks - 1), to: monday) else { return [] }
        return (0..<Self.weeks).map { w in
            (0..<7).compactMap { d in cal.date(byAdding: .day, value: w * 7 + d, to: first) }
        }
    }

    private func color(_ date: Date) -> Color {
        if date > Date() { return .clear }
        let s = store.dayScore(date)
        if s.due == 0 { return StrandPalette.hairline }
        if Calendar.current.isDateInToday(date) && s.met < s.due {
            return s.met == 0 ? StrandPalette.hairline : StrandPalette.chargeColor.opacity(0.25 + 0.5 * Double(s.met) / Double(s.due))
        }
        if s.met == 0 { return StrandPalette.statusCritical.opacity(0.55) }
        return StrandPalette.chargeColor.opacity(0.25 + 0.75 * Double(s.met) / Double(s.due))
    }

    var body: some View {
        let streaks = store.perfectStreak()
        let cols = columns
        let recent = (0..<30).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }.map { store.dayScore($0) }
        let met = recent.reduce(0) { $0 + $1.met }, due = recent.reduce(0) { $0 + $1.due }
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack {
                    Text("CONSISTENCY").font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Text(due > 0 ? "\(Int((Double(met) / Double(due) * 100).rounded()))% · last 30 days" : "Last 30 days")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                GeometryReader { g in
                    let gap: CGFloat = 3
                    let side = max(6, min(14, (g.size.width - gap * CGFloat(Self.weeks - 1)) / CGFloat(Self.weeks)))
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(cols.indices, id: \.self) { w in
                            VStack(spacing: gap) {
                                ForEach(cols[w], id: \.self) { d in
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(color(d))
                                        .frame(width: side, height: side)
                                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .stroke(Calendar.current.isDateInToday(d) ? StrandPalette.textPrimary : .clear, lineWidth: 1))
                                }
                            }
                        }
                    }
                }
                .frame(height: 7 * 14 + 6 * 3)
                HStack(spacing: NoopMetrics.space3) {
                    Text("\(streaks.current)-day perfect streak").font(StrandFont.caption).foregroundStyle(StrandPalette.textPrimary)
                    Text("Best \(streaks.best)").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    HStack(spacing: 3) {
                        Text("Less").font(.system(size: 9, design: .rounded)).foregroundStyle(StrandPalette.textTertiary)
                        ForEach([0.3, 0.55, 0.8, 1.0], id: \.self) { o in
                            RoundedRectangle(cornerRadius: 2).fill(StrandPalette.chargeColor.opacity(o)).frame(width: 9, height: 9)
                        }
                        Text("More").font(.system(size: 9, design: .rounded)).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }
}


/// Splits and body parts to tag a gym session with. Tapping one marks the gym done for the day.
struct SfzGymPartsGrid: View {
    let habitId: UUID
    var day: String = SfzHabitStore.today
    @ObservedObject private var store = SfzHabitStore.shared

    var body: some View {
        let chosen = Set(store.gymParts(habitId, day: day))
        let cols = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        LazyVGrid(columns: cols, spacing: 8) {
            ForEach(SfzHabitStore.gymParts, id: \.self) { part in
                let on = chosen.contains(part)
                Button { store.toggleGymPart(habitId, part, day: day) } label: {
                    Text(part).font(StrandFont.subhead.weight(on ? .semibold : .regular))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Capsule().fill(on ? StrandPalette.accent : StrandPalette.accent.opacity(0.10)))
                        .foregroundStyle(on ? Color.white : StrandPalette.accent)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The sheet that opens after tapping Done on a gym card.
struct SfzGymPartsSheet: View {
    let habitId: UUID
    @ObservedObject private var store = SfzHabitStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    Text("Pick a split, the body parts, or both.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    SfzGymPartsGrid(habitId: habitId)
                    let counts = store.gymPartCounts(habitId)
                    if !counts.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LAST 30 DAYS").font(StrandFont.overline).tracking(1.4).foregroundStyle(StrandPalette.textSecondary)
                            Text(counts.prefix(10).map { "\($0.part) \($0.count)×" }.joined(separator: " · "))
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                .padding(NoopMetrics.screenHPadding)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("What did you train?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
