import SwiftUI

// MARK: - Native Liquid Glass search field
//
// Shared search chrome for every in-app filter/search bar. iOS 26 uses the platform
// `glassEffect` capsule; macOS and older iOS keep a solid elevated pill (not a
// hand-rolled blur stack). Liquid Glass is intentionally iOS-only — macOS stays on
// the standard surface. Clear control, magnifying-glass glyph, and accessibility
// wiring stay identical across call sites.

/// Full-width rounded search field with native Liquid Glass on iOS 26+.
public struct NoopLiquidGlassSearchField: View {
    @Binding private var text: String
    private let prompt: String
    private let accessibilityPrompt: String
    private var externalFocus: FocusState<Bool>.Binding?
    @FocusState private var internalFocus: Bool

    public init(text: Binding<String>,
                prompt: String,
                accessibilityLabel: String? = nil,
                isFocused: FocusState<Bool>.Binding? = nil) {
        self._text = text
        self.prompt = prompt
        self.accessibilityPrompt = accessibilityLabel ?? prompt
        self.externalFocus = isFocused
    }

    public var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .focused(focusBinding)
                .submitLabel(.search)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.vertical, NoopMetrics.space3)
        .nativeLiquidGlassSearchChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityPrompt))
    }

    private var focusBinding: FocusState<Bool>.Binding {
        externalFocus ?? $internalFocus
    }
}

public extension View {
    /// Capsule Liquid Glass search chrome. iOS 26 uses interactive `glassEffect`; macOS and older
    /// iOS use the shared elevated pill surface. Glass APIs stay behind `#if os(iOS)` so macOS
    /// (deployment 13) never type-checks or applies Liquid Glass.
    @ViewBuilder
    func nativeLiquidGlassSearchChrome() -> some View {
        #if os(iOS)
        self.noopStandardSearchChrome()   // sfz minimal: flat pill, no glass
        #else
        self.noopStandardSearchChrome()
        #endif
    }

    /// Circular / capsule interactive Liquid Glass button chrome (Home header, live-workout controls,
    /// workout-selection close/chips). iOS 26 only; every other platform keeps the caller's
    /// `fallback` (standard material / press style) unchanged.
    @ViewBuilder
    func nativeLiquidGlassButtonChrome<Fallback: View>(
        controlSize: ControlSize = .small,
        capsule: Bool = false,
        @ViewBuilder fallback: () -> Fallback
    ) -> some View {
        #if os(iOS)
        // sfz minimal: flat circle/capsule with a hairline, no glass material.
        // The style makes the whole shape tappable: some labels are transparent (the profile photo
        // button draws its picture in an overlay), and a plain style would only hit visible pixels.
        if capsule {
            self.buttonStyle(SfzFlatButtonStyle(capsule: true))
                .background(NoopVisualStyle.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(NoopVisualStyle.border, lineWidth: 0.8).allowsHitTesting(false))
        } else {
            self.buttonStyle(SfzFlatButtonStyle(capsule: false))
                .background(NoopVisualStyle.surface, in: Circle())
                .overlay(Circle().strokeBorder(NoopVisualStyle.border, lineWidth: 0.8).allowsHitTesting(false))
        }
        #else
        fallback()
        #endif
    }

    /// Interactive circular `glassEffect` finish layer (e.g. Home profile photo over glass).
    /// No-op outside iOS 26 so macOS never imports the glass path.
    @ViewBuilder
    func nativeLiquidGlassCircleFinish() -> some View {
        #if os(iOS)
        self   // sfz minimal: no glass finish
        #else
        self
        #endif
    }

    @ViewBuilder
    private func noopStandardSearchChrome() -> some View {
        self.background(
            NoopPanelSurface(cornerRadius: NoopVisualStyle.pillRadius, elevated: false)
        )
    }
}


/// sfz: flat header-button style: the full circle/capsule is the tap target, with a light press dim.
struct SfzFlatButtonStyle: ButtonStyle {
    var capsule: Bool
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if capsule {
                configuration.label.contentShape(Capsule())
            } else {
                configuration.label.contentShape(Circle())
            }
        }
        .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
