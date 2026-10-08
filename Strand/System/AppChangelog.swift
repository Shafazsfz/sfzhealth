import Foundation

/// Single source of truth for the in-app "What's New" screen and the expectation-setting copy used
/// in onboarding. Mirrored byte-for-byte by the Android `AppChangelog.kt` and the repo CHANGELOG.md
/// so every surface tells the same story.
enum AppChangelog {

    /// Bump this when you add a release below. The "What's New" sheet shows automatically when the
    /// stored last-seen version is behind this. (Decoupled from the bundle version on purpose.)
    static let currentVersion = "1.0.0"

    struct Release: Identifiable {
        let version: String
        let title: String
        let date: String
        let items: [String]
        var id: String { version }
    }

    /// Newest first.
    static let releases: [Release] = [
        // sfz releases only, newest first. sfz keeps its own version numbers.
        Release(
            version: "1.0.0",
            title: "sfz 1.0: a Goal page with habits, challenges and your own targets",
            date: "October 2026",
            items: [
                "**Goal page.** Calories left, food with protein, carbs and fat, water, weight goal, this week's Active Zone Minutes and exercise days, and fat lost. Every card can be shown or hidden from Edit page.",
                "**Habits.** Counters (push-ups, pull-ups, crunches), timers (plank), yes/no (no sugar, reading, skin care), gym with done, skip or rest and what you trained, plus steps, water, calories under target and burn target filled in for you. Set reminders, days and targets on each, or every target on one Targets page.",
                "**Challenges.** 75 Hard, 75 Soft, 30-day push-ups, 90 days or your own, strict or flexible. Day X of N, streaks, consistency, a calendar, and a choice to restart or switch to flexible after a miss.",
                "**Consistency grid.** Twenty weeks at a glance, all-or-nothing in a strict challenge, and it can start fresh when your targets change.",
                "**Trends.** Key metrics cards in the style of Google Health, with your habits, food, water, sleep and vitals over the week.",
                "**Sleep and reminders.** Wind-down nudge with your sleep need, a bedtime reminder and a countdown; reminders to put your WHOOP back on, with snooze and quiet hours; high and low heart rate alerts.",
                "**Today.** Your cards three to a row, a habits summary, and Recovery, Strain and Sleep in the Dynamic Island.",
                "**Apple Health.** Food (calories, protein, carbs, fat) and Breathe sessions as mindful minutes are written to Apple Health.",
                "Built on NOOP 12.0.0.",
            ]
        ),
    ]

    /// Expectation-setting points shown during onboarding and at the top of "What's New". This is the
    /// “what is this and what should I expect” story, so people don't have to go read GitHub.
    struct Expectation: Identifiable {
        let icon: String      // SF Symbol
        let title: String
        let body: String
        var id: String { title }
    }

    static let expectations: [Expectation] = [
        Expectation(
            icon: "flask",
            title: String(localized: "Independent, and experimental"),
            body: String(localized: "Sfz Health is a personal, open project: not the WHOOP app, and not affiliated with WHOOP. It reads a WHOOP you own, on your own device. Treat it as a capable work-in-progress rather than a finished product.")),
        Expectation(
            icon: "checkmark.seal",
            title: String(localized: "WHOOP 4.0 is the supported path"),
            body: String(localized: "WHOOP 4.0 is tested and works end to end. WHOOP 5.0/MG is newer: live heart rate works today, but deeper metrics (recovery, strain, sleep) for 5/MG are still being figured out. Sfz Health always tells you what's live versus still building.")),
        Expectation(
            icon: "hourglass",
            title: String(localized: "Your scores build over a few nights"),
            body: String(localized: "Live heart rate is instant. Recovery, strain and sleep sharpen as Sfz Health learns your baseline over your first nights of wear. Want your history now? Import your WHOOP export in Data Sources and it backfills in about a minute.")),
        Expectation(
            icon: "lock.shield",
            title: String(localized: "Everything stays on your device"),
            body: String(localized: "No account, no cloud, no sync. Sfz Health talks only to your WHOOP and keeps everything local. Your data is yours alone.")),
    ]
}
