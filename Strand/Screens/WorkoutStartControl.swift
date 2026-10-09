import SwiftUI
import StrandDesign

/// #459: "Start Workout" used to live ONLY on the Live screen, so a user reaching Workouts (via the
/// Quick-action FAB or the tab) had no way to begin one from the obvious place. This button starts a live
/// session and presents the in-exercise view directly.
///
/// PERF (chart-invalidation): this is the ONE place `WorkoutsView` needs live `AppModel` state
/// (`activeWorkout`) — everything else it needs (`hrMax`, `analyzeRecent()`) lives on sub-objects that
/// don't publish at live-tick frequency. `AppModel` publishes `bpm` at ~1 Hz (AppModel.swift:202), and
/// `@EnvironmentObject` subscribes to the WHOLE object's `objectWillChange`, so if `WorkoutsView` itself
/// held `model: AppModel`, every tick would re-evaluate its entire ~1900-line body (chart + grids +
/// sorting) even though only this button's label and its two sheets read `model`. Isolating it here
/// (mirroring `HealthView`'s live-observing-leaf pattern, HealthView.swift:17-22, 44-46) means a tick
/// re-renders only this small leaf. Owns its own sheet-presentation state so nothing about it needs to
/// live on the parent either.
struct WorkoutStartControl: View {
    var showsActiveIndicator = false
    /// sfz: the Coach shortcut beside the button. Off where the row is already shared (Workouts).
    var showsCoach = true
    @EnvironmentObject var model: AppModel
    @State private var showLiveWorkout = false
    @State private var showStartSport = false

    var body: some View {
        Group {
            if showsActiveIndicator, let active = ActiveWorkoutIndicatorModel.make(from: model.activeWorkout) {
                ActiveWorkoutIndicatorCard(model: active) {
                    StrandHaptic.selection.play()
                    showLiveWorkout = true
                }
            } else {
                // sfz: Start workout takes three quarters of the row, a Coach shortcut the first quarter on the left.
                HStack(spacing: 10) {
                if showsCoach {
                    SfzCoachShortcutButton()
                        .frame(width: 88)
                }
                NoopButton(model.activeWorkout == nil ? "Start workout" : "View active workout",
                           systemImage: model.activeWorkout == nil ? "figure.run" : "timer",
                           kind: .primary,
                           fullWidth: true) {
                    // No active session → pick a named sport first (#519), then the sheet's onStart begins it
                    // and opens the in-exercise view. Already active → jump straight back into the live view.
                    if model.activeWorkout == nil { showStartSport = true }
                    else { showLiveWorkout = true }
                }
                .accessibilityLabel(model.activeWorkout == nil ? "Start a workout" : "View the active workout")
                .layoutPriority(1)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        // #459: the in-exercise view, presented when Start Workout is tapped here (same screen LiveView
        // shows). activeWorkout is global on AppModel, so ending it from either surface stays in sync.
        .sheet(isPresented: $showLiveWorkout) {
            LiveWorkoutView(onClose: { showLiveWorkout = false })
                // Inject the shared live snapshot so the in-exercise sensor readout (speed/cadence/power)
                // resolves here too, matching how LiveView presents the same screen.
                .environmentObject(model.live)
        }
        // #519: name the sport before a live session starts, then open the in-exercise view directly
        // (same direct present as the button's already-active path — no cross-view auto-present race).
        .workoutSelectionCover(isPresented: $showStartSport) {
            StartWorkoutSheet { name in
                model.startWorkout(sport: name)
                showLiveWorkout = true
            }
        }
    }
}


/// sfz: a one-tap way into the Coach chat from anywhere, opened as a sheet.
struct SfzCoachShortcutButton: View {
    var compact = false
    @EnvironmentObject var coach: AICoachEngine
    @EnvironmentObject var repo: Repository
    @State private var showCoach = false

    var body: some View {
        Button {
            StrandHaptic.selection.play()
            showCoach = true
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
                Text("Coach")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, compact ? 6 : 8)
            .background(NoopPanelSurface(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(StrandPalette.accent.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel("Open Coach")
        .sheet(isPresented: $showCoach) {
            NavigationStack {
                CoachView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showCoach = false }
                        }
                    }
            }
            .environmentObject(coach)
            .environmentObject(repo)
        }
    }
}
