import DeviceActivity
import SwiftUI

/// sfz: draws screen-time usage inside the app. iOS runs this in its own sandbox and shows the view
/// in the app; the app itself never sees the minutes.
@main
struct SfzScreenReportExtension: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        SfzUsageScene(context: .init("sfzAverage")) { SfzUsageView(usage: $0, showAverage: true) }
        SfzUsageScene(context: .init("sfzToday")) { SfzUsageView(usage: $0, showAverage: false) }
    }
}

struct SfzUsage {
    var todaySeconds: Double = 0
    var averageSeconds: Double?
    var days: Int = 0
}

struct SfzUsageScene: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context
    let content: (SfzUsage) -> SfzUsageView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> SfzUsage {
        var perDay: [Date: Double] = [:]
        for await d in data {
            for await seg in d.activitySegments {
                var secs = 0.0
                for await cat in seg.categories {
                    for await app in cat.applications { secs += app.totalActivityDuration }
                    for await web in cat.webDomains { secs += web.totalActivityDuration }
                }
                let day = Calendar.current.startOfDay(for: seg.dateInterval.start)
                perDay[day, default: 0] += secs
            }
        }
        let today = Calendar.current.startOfDay(for: Date())
        let past = perDay.filter { $0.key < today }
        var u = SfzUsage()
        u.todaySeconds = perDay[today] ?? 0
        u.days = past.count
        if !past.isEmpty { u.averageSeconds = past.values.reduce(0, +) / Double(past.count) }
        return u
    }
}

struct SfzUsageView: View {
    let usage: SfzUsage
    let showAverage: Bool

    private func text(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m) min"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showAverage {
                if let avg = usage.averageSeconds {
                    Text("Your average: \(text(avg)) a day")
                        .font(.system(.headline, design: .rounded))
                    Text("Over the last \(usage.days) days · today so far \(text(usage.todaySeconds))")
                        .font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
                } else {
                    Text("Today so far \(text(usage.todaySeconds))").font(.system(.headline, design: .rounded))
                    Text("Your average appears after a full day.").font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(text(usage.todaySeconds)).font(.system(.title2, design: .rounded).weight(.semibold))
                Text("used today").font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
