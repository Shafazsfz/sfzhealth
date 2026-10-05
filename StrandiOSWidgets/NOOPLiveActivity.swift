import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for an active live-HR session — shown on the Lock Screen and in the Dynamic Island.
struct NOOPLiveActivity: Widget {
    /// The heart rate to draw: none once iOS has marked the banner stale. Each push is fresh for 30 s
    /// (`LiveActivityController.staleAfter`) and NOOP re-pushes a steady number well inside that, so a stale banner
    /// means the readings stopped — the strap off the wrist, or out of reach — even while NOOP itself is asleep and
    /// cannot say so: iOS redraws the banner at the stale date on its own.
    static func shownBpm(_ context: ActivityViewContext<NOOPActivityAttributes>) -> Int? {
        context.isStale ? nil : context.state.bpm
    }

    // sfz: the banner shows today's three scores (Recovery · Strain · Sleep) instead of live heart rate.
    static func text(_ v: Int?, _ suffix: String = "") -> String { v.map { "\($0)\(suffix)" } ?? "–" }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            // Lock Screen / banner presentation: three plain columns.
            HStack(spacing: 0) {
                bannerStat(label: "Recovery", value: Self.text(context.state.recovery, "%"),
                           tint: StrandPalette.chargeColor)
                    .frame(maxWidth: .infinity)
                bannerStat(label: "Strain", value: Self.text(context.state.effort),
                           tint: StrandPalette.effortColor)
                    .frame(maxWidth: .infinity)
                bannerStat(label: "Sleep", value: Self.text(context.state.sleep, "%"),
                           tint: StrandPalette.restColor)
                    .frame(maxWidth: .infinity)
            }
            .padding()
            .activityBackgroundTint(StrandPalette.surfaceBase)
            .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 0) {
                        statColumn(label: "Recovery", value: Self.text(context.state.recovery, "%"),
                                   tint: StrandPalette.chargeColor)
                            .frame(maxWidth: .infinity)
                        statColumn(label: "Strain", value: Self.text(context.state.effort),
                                   tint: StrandPalette.effortColor)
                            .frame(maxWidth: .infinity)
                        statColumn(label: "Sleep", value: Self.text(context.state.sleep, "%"),
                                   tint: StrandPalette.restColor)
                            .frame(maxWidth: .infinity)
                    }
                }
            } compactLeading: {
                Text(Self.text(context.state.recovery, "%"))
                    .foregroundStyle(StrandPalette.chargeColor)
            } compactTrailing: {
                Text(Self.text(context.state.effort))
                    .foregroundStyle(StrandPalette.effortColor)
            } minimal: {
                Text(Self.text(context.state.recovery))
                    .foregroundStyle(StrandPalette.chargeColor)
            }
        }
    }
}

/// Lock-Screen banner stat column (label over value). File-scope because the `ActivityConfiguration`
/// content closure isn't a method of `NOOPLiveActivity`.
///
/// #759 - the label and value are CENTRE-aligned so each value sits directly under its own label. The
/// old `.trailing` alignment right-pinned both to the column's edge: when the value was narrower than
/// the label (e.g. "12" under "Effort") it drifted to the label's right edge instead of under it, which
/// read as "the number doesn't line up with its label". `fixedSize` stops either line truncating so the
/// pairing is never clipped at narrow widths.
@ViewBuilder
private func bannerStat(label: String, value: String, tint: Color) -> some View {
    VStack(alignment: .center, spacing: 2) {
        Text(label).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
        Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(tint)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}

/// Dynamic Island expanded-region stat column (label over value). File-scope for the same reason as
/// `bannerStat`. #759 - centre-aligned + `fixedSize` for the same value-under-its-label fix as the banner.
@ViewBuilder
private func statColumn(label: String, value: String, tint: Color) -> some View {
    VStack(alignment: .center, spacing: 1) {
        Text(label).font(.caption2).foregroundStyle(.secondary)
        Text(value).font(.headline).foregroundStyle(tint)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}
