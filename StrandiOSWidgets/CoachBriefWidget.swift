import WidgetKit
import SwiftUI
import StrandDesign

/// K10: A Lock Screen / Home Screen widget showing the stored Coach morning brief.
///
/// Design contract (see PRD-K10 + D8):
/// - The widget reads **stored** brief text from the App Group — it NEVER calls the network.
///   The brief is generated on a schedule by `CoachBriefScheduler` (K5) and mirrored into the
///   App Group via `publishToWidget`. The widget just displays whatever text is there.
/// - Tap → opens the Coach tab (via the app's URL scheme / deeplink).
/// - Supported families: `accessoryRectangular` (Lock Screen), `systemSmall` (Home Screen).
///   The Lock Screen accessory shows the first line; the Home Screen widget shows more.
struct CoachBriefEntry: TimelineEntry {
    let date: Date
    let briefText: String?
    let briefDate: Date?
}

struct CoachBriefProvider: TimelineProvider {
    /// App Group keys — must match `CoachBriefScheduler.K.widgetBriefKey` / `.widgetBriefDateKey`.
    private static let briefKey = "coachBrief.widgetText"
    private static let briefDateKey = "coachBrief.widgetDate"

    func placeholder(in context: Context) -> CoachBriefEntry {
        CoachBriefEntry(
            date: Date(),
            briefText: "Recovery is strong today — consider a higher-intensity session this afternoon.",
            briefDate: Date()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (CoachBriefEntry) -> Void) {
        let entry = loadEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CoachBriefEntry>) -> Void) {
        let entry = loadEntry()
        // Refresh every 30 minutes — the app pushes a reload via WidgetCenter when a new brief is
        // published, so this is just a safety net for when the app isn't running.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date())
            ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadEntry() -> CoachBriefEntry {
        let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName)
        let text = defaults?.string(forKey: CoachBriefProvider.briefKey)
        let date = defaults?.object(forKey: CoachBriefProvider.briefDateKey) as? Date
        return CoachBriefEntry(date: Date(), briefText: text, briefDate: date)
    }
}

struct CoachBriefWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CoachBriefEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            inline
        default:
            small
        }
    }

    // MARK: - Lock Screen: accessoryRectangular

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(StrandPalette.accent)
                Text("Coach")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
                if let date = entry.briefDate {
                    Text(date, style: .time)
                        .font(.caption2)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Text(briefDisplay)
                .font(.system(size: 11))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: - Lock Screen: accessoryInline

    private var inline: some View {
        Text(briefOneLine)
    }

    // MARK: - Home Screen: systemSmall

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(StrandPalette.accent)
                Text("Coach Brief")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
            }
            if entry.briefText == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No brief yet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text("Enable Morning Brief in Coach settings to see today's readiness here.")
                        .font(.system(size: 11))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(briefDisplay)
                    .font(.system(size: 12))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(5)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            if let date = entry.briefDate {
                Text(date, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(12)
    }

    // MARK: - Text helpers

    /// The full brief text for the widget body, or a placeholder when there's no brief.
    private var briefDisplay: String {
        entry.briefText ?? "No brief available."
    }

    /// One-line summary for the inline accessory (capped at ~100 chars).
    private var briefOneLine: String {
        guard let text = entry.briefText else { return "Coach: no brief yet" }
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 100 else { return "Coach: \(trimmed)" }
        let cut = trimmed.index(trimmed.startIndex, offsetBy: 100)
        return "Coach: \(trimmed[..<cut].trimmingCharacters(in: .whitespaces))…"
    }
}

struct CoachBriefWidget: Widget {
    static let kind = "CoachBriefWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: CoachBriefProvider()) { entry in
            if #available(iOS 17.0, *) {
                CoachBriefWidgetView(entry: entry)
                    .containerBackground(StrandPalette.surfaceBase, for: .widget)
            } else {
                CoachBriefWidgetView(entry: entry)
                    .padding()
                    .background(StrandPalette.surfaceBase)
            }
        }
        .configurationDisplayName("Coach Brief")
        .description("Today's coaching brief at a glance. Tap to open Coach.")
        .supportedFamilies([
            .systemSmall,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}


// MARK: - sfz: Goal consistency grid widget

/// Mirrors `SfzGoalGridSnapshot` in the app (StrandiOS/Cut/CutPlanStore.swift). Same JSON keys.
struct SfzGoalGridFeed: Codable {
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

    static let storageKey = "sfz.goalGrid.snapshot"

    static func load() -> SfzGoalGridFeed? {
        guard let data = UserDefaults(suiteName: WidgetSnapshot.suiteName)?.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(SfzGoalGridFeed.self, from: data)
    }

    static var sample: SfzGoalGridFeed {
        let weeks: [[Double]] = (0..<20).map { w in
            (0..<7).map { d in
                if w == 19 && d > 3 { return -4 }
                let v = Double((w * 7 + d) * 37 % 10) / 10
                return v < 0.15 ? -2 : max(0.3, v)
            }
        }
        return SfzGoalGridFeed(weeks: weeks, streak: 6, todayMet: 4, todayDue: 6,
                               challengeName: "75 Soft", challengeDay: 18, challengeLength: 75,
                               strict: false, percent30: 82, updated: Date())
    }
}

struct SfzGoalGridEntry: TimelineEntry {
    let date: Date
    let feed: SfzGoalGridFeed?
}

struct SfzGoalGridProvider: TimelineProvider {
    func placeholder(in context: Context) -> SfzGoalGridEntry { SfzGoalGridEntry(date: Date(), feed: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (SfzGoalGridEntry) -> Void) {
        completion(SfzGoalGridEntry(date: Date(), feed: SfzGoalGridFeed.load() ?? (context.isPreview ? .sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SfzGoalGridEntry>) -> Void) {
        let entry = SfzGoalGridEntry(date: Date(), feed: SfzGoalGridFeed.load())
        // The app reloads this whenever a habit changes; refresh after midnight as a safety net.
        let cal = Calendar.current
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date().addingTimeInterval(3600)
        let next = min(midnight.addingTimeInterval(60), Date().addingTimeInterval(2 * 3600))
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct SfzGoalGridWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SfzGoalGridEntry

    private func color(_ v: Double) -> Color {
        switch v {
        case ..<(-3.5): return .clear
        case ..<(-2.5): return StrandPalette.hairline.opacity(0.4)
        case ..<(-1.5): return StrandPalette.statusCritical.opacity(0.75)
        case ..<(-0.5): return StrandPalette.restColor.opacity(0.6)
        case ..<0.01: return StrandPalette.hairline
        default: return StrandPalette.chargeColor.opacity(min(1, v))
        }
    }

    private var weeksShown: Int { family == .systemSmall ? 8 : 18 }

    var body: some View {
        Group {
            if let feed = entry.feed {
                content(feed)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    header(nil)
                    Spacer(minLength: 0)
                    Text("Open sfz and log a habit to fill your grid.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .widgetURL(URL(string: "noop://goal"))
    }

    private func header(_ feed: SfzGoalGridFeed?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "target")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(StrandPalette.accent)
            Text(feed?.challengeName ?? "Consistency")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let feed, let d = feed.challengeDay, let l = feed.challengeLength {
                Text("Day \(d)/\(l)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    private func grid(_ feed: SfzGoalGridFeed) -> some View {
        let cols = Array(feed.weeks.suffix(weeksShown))
        return GeometryReader { g in
            let gap: CGFloat = family == .systemSmall ? 3 : 2.5
            let byW = (g.size.width - gap * CGFloat(cols.count - 1)) / CGFloat(max(cols.count, 1))
            let byH = (g.size.height - gap * 6) / 7
            let side = max(4, min(byW, byH))
            HStack(alignment: .top, spacing: gap) {
                ForEach(cols.indices, id: \.self) { w in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { d in
                            let v = d < cols[w].count ? cols[w][d] : -4
                            RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                                .fill(color(v))
                                .frame(width: side, height: side)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func content(_ feed: SfzGoalGridFeed) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(feed)
            grid(feed)
            HStack(spacing: 10) {
                if feed.todayDue > 0 {
                    Label("\(feed.todayMet)/\(feed.todayDue) today", systemImage: feed.todayMet >= feed.todayDue ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(feed.todayMet >= feed.todayDue ? StrandPalette.chargeColor : StrandPalette.textPrimary)
                }
                Spacer(minLength: 0)
                Label("\(feed.streak)", systemImage: "flame.fill")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(StrandPalette.accent)
                if family != .systemSmall, let p = feed.percent30 {
                    Text("\(p)% · 30d")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .labelStyle(.titleAndIcon)
        }
    }
}

struct SfzGoalGridWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SfzGoalGridWidget", provider: SfzGoalGridProvider()) { entry in
            SfzGoalGridWidgetView(entry: entry)
                .containerBackground(for: .widget) { StrandPalette.surfaceBase }
        }
        .configurationDisplayName("Goal grid")
        .description("Your habit consistency grid, today's progress and streak.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
