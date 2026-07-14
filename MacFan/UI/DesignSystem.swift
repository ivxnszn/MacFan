import AppKit
import SwiftUI

/// Shared layout tokens. New code should reach for these instead of ad-hoc
/// literals; values follow an 8-point rhythm with half-steps where the design
/// needs them.
enum MacFanMetrics {
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacing: CGFloat = 16
    static let spacingL: CGFloat = 24

    static let radiusS: CGFloat = 8
    static let radius: CGFloat = 12
    static let radiusL: CGFloat = 16

    static let animationFast: TimeInterval = 0.18
    static let animation: TimeInterval = 0.3

    // Short, highly damped motion keeps feedback immediate on a trackpad.
    static let springResponse: Double = 0.28
    static let springDamping: Double = 0.82
    static let springFast: Animation = .spring(response: 0.22, dampingFraction: 0.85)
    static let springStandard: Animation = .spring(response: MacFanMetrics.springResponse, dampingFraction: MacFanMetrics.springDamping)

    static let springPress: Animation = .spring(response: 0.18, dampingFraction: 0.90)
    static let springRelease: Animation = .spring(response: 0.30, dampingFraction: 0.86)
    static let springSelection: Animation = .spring(response: 0.22, dampingFraction: 0.85)

    static let pressScale: CGFloat = 0.985
    static let pressOffsetY: CGFloat = 0.7
    static let pressBrightness: Double = -0.015

    static let hoverScale: CGFloat = 1.003
    static let hoverBrightness: Double = 0.012

    // Consistent inner paddings for premium cards (Apple-like generous but precise)
    static let cardPadding: CGFloat = 16
    static let cardPaddingS: CGFloat = 12
    static let cardPaddingL: CGFloat = 20

    // Grain is a static material cue on large surfaces, never an interaction
    // effect. This keeps scrolling composited and avoids inserting texture
    // layers under a stationary pointer.
    static let grainOpacity: Double = 0.012
    static let grainDensity: CGFloat = 96
    static let grainDotSize: CGFloat = 0.45
}

// Palette: refined blue-purple for depth, harmony, and premium SF Pro layering.
// Deeper, more balanced saturations; subtle cool shifts for better gradient blending
// and visual hierarchy on dark canvas. Opacities/gradients refined in usage sites.
extension Color {
    static let macFanCanvas = Color(red: 0.035, green: 0.037, blue: 0.047)
    static let macFanSurface = Color(red: 0.055, green: 0.058, blue: 0.071)
    static let macFanSurfaceHigh = Color(red: 0.076, green: 0.080, blue: 0.096)
    static let macFanRaised = Color(red: 0.105, green: 0.110, blue: 0.130)
    static let macFanStroke = Color(red: 0.150, green: 0.158, blue: 0.184)
    static let macFanPrimary = Color(red: 0.953, green: 0.957, blue: 0.973)
    static let macFanSecondary = Color(red: 0.650, green: 0.660, blue: 0.704)
    static let macFanMuted = Color(red: 0.535, green: 0.548, blue: 0.602)

    // Refined blue-purple family (harmonious depth, better mid-tone blending)
    static let macFanBlue = Color(red: 0.282, green: 0.455, blue: 0.925)          // deeper, richer #4874ec
    static let macFanBlueMuted = Color(red: 0.235, green: 0.380, blue: 0.780)     // subtle variant for strokes/fills
    static let macFanCyan = Color(red: 0.118, green: 0.755, blue: 0.875)          // #1ec1df
    static let macFanSky = Color(red: 0.200, green: 0.710, blue: 0.945)           // #33b5f1
    static let macFanIndigo = Color(red: 0.510, green: 0.565, blue: 0.980)        // #8290fa
    static let macFanViolet = Color(red: 0.455, green: 0.400, blue: 0.945)        // #7466f1
    static let macFanVioletLight = Color(red: 0.635, green: 0.675, blue: 0.975)   // #a2acfa
    static let macFanPurple = Color(red: 0.510, green: 0.340, blue: 0.905)        // #8257e7

    static let macFanAmber = Color(red: 0.961, green: 0.651, blue: 0.137)         // #f5a623
    static let macFanAmberLight = Color(red: 0.961, green: 0.722, blue: 0.306)    // #f5b84e
    static let macFanCoral = Color(red: 1.0, green: 0.420, blue: 0.361)           // #ff6b5c
    static let macFanMint = Color(red: 0.282, green: 0.839, blue: 0.659)          // #48d6a8
}

// MARK: - Blue-purple gradient helpers for consistent premium depth
extension LinearGradient {
    static let macFanBluePurple = LinearGradient(
        colors: [Color.macFanBlue, Color.macFanViolet, Color.macFanPurple],
        startPoint: .leading, endPoint: .trailing
    )
    static let macFanBluePurpleVertical = LinearGradient(
        colors: [Color.macFanBlue, Color.macFanViolet],
        startPoint: .top, endPoint: .bottom
    )
    static let macFanVioletCyan = LinearGradient(
        colors: [Color.macFanViolet, Color.macFanCyan],
        startPoint: .leading, endPoint: .trailing
    )
}

// MARK: - Typography scale
// A deliberately small set of SF Pro roles. Ten points is the floor for
// visible text; tabular figures are used for measurements.
extension Font {
    // Hierarchy (macOS HIG-inspired, tuned for dashboard/popover density)
    static let macFanLargeTitle = Font.system(size: 26, weight: .semibold)
    static let macFanTitle1 = Font.system(size: 22, weight: .semibold)
    static let macFanTitle2 = Font.system(size: 17, weight: .semibold)
    static let macFanHeadline = Font.system(size: 15, weight: .semibold)
    static let macFanBody = Font.system(size: 13, weight: .regular)
    static let macFanCallout = Font.system(size: 12, weight: .regular)
    static let macFanSubhead = Font.system(size: 12, weight: .medium)
    static let macFanCaption = Font.system(size: 11, weight: .medium)

    /// Base numeric (tabular figures). Always pair with .monospacedDigit() + tracking in modifiers.
    static func macFanNumeric(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    // Dedicated display/hero for temps + live values that need to "sing".
    static let macFanDisplay = Font.system(size: 42, weight: .semibold)

    // Chart / HUD / inspection optimized (crisper at small sizes on dark canvas)
    static let macFanChartAxis = Font.system(size: 10, weight: .medium, design: .default)
    static let macFanChartTick = Font.system(size: 10, weight: .regular, design: .default)
    static let macFanChartValue = Font.system(size: 11, weight: .semibold, design: .default)
    static let macFanInspection = Font.system(size: 11, weight: .medium, design: .default)

    // Legacy canvas names kept for minimal breakage; prefer the new macFanChart* above.
    static let macFanCanvasAxis = Font.system(size: 10, weight: .medium, design: .default)
    static let macFanCanvasSmall = Font.system(size: 10, weight: .medium, design: .default)
    static let macFanCanvasValue = Font.system(size: 11, weight: .semibold, design: .default)
}

// Typography view modifiers for consistency — all dashboard text should use these
// for a uniform premium SF Pro (system) feel with proper weights, tracking, and digit handling.
extension View {
    func macFanLargeTitle() -> some View { font(.macFanLargeTitle) }
    func macFanTitle1() -> some View { font(.macFanTitle1) }
    func macFanTitle2() -> some View { font(.macFanTitle2) }
    func macFanHeadline() -> some View { font(.macFanHeadline) }
    func macFanBody() -> some View { font(.macFanBody) }
    func macFanCallout() -> some View { font(.macFanCallout) }
    func macFanSubhead() -> some View { font(.macFanSubhead) }
    func macFanCaption() -> some View { font(.macFanCaption) }

    /// Compact label with restrained tracking. Wide letter spacing is reserved
    /// for the handful of uppercase section labels.
    func macFanLabel(tracking: CGFloat = 0.25, uppercase: Bool = false) -> some View {
        font(.macFanCaption)
            .kerning(tracking)
            .textCase(uppercase ? .uppercase : .none)
    }

    /// Hero / display numeric — large prominent temperatures, RPMs, key live values.
    /// Makes numbers "sing": tight negative tracking, monospaced digits, premium weight.
    /// Use for popover hero, big stat cards. Align units with .lastTextBaseline.
    /// Always follow with .macFanLiveNumberTransition() + ancestor .animation(..., value:) for live updates.
    func macFanHeroNumeric(size: CGFloat = 44) -> some View {
        font(.macFanNumeric(size: size, weight: .semibold))
            .monospacedDigit()
            .tracking(size >= 40 ? -1.65 : (size >= 32 ? -1.25 : -0.95))
            .lineLimit(1)
    }

    /// Perfect metric number: monospaced digits + dynamic tracking for premium tabular feel.
    /// Use everywhere for live values (temps, RPMs, %, stats). Size-aware tracking creates
    /// the "Apple instrument panel" tightness on large numbers and clean readability on small.
    /// Chain .macFanLiveNumberTransition() for smooth .contentTransition(.numericText()) on updating values.
    func macFanNumber(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        font(.macFanNumeric(size: size, weight: weight))
            .monospacedDigit()
            .tracking(
                size >= 36 ? -1.35 :
                size >= 28 ? -0.95 :
                size >= 20 ? -0.55 :
                size >= 14 ? -0.25 : 0.0
            )
            .lineLimit(1)
    }

    /// Large dashboard numerals remain SF Pro so cards and chart HUDs share one
    /// typographic voice. The popover may opt into rounded display text itself.
    func macFanDisplayNumber(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        font(.system(size: size, weight: weight, design: .default))
            .monospacedDigit()
            .kerning(size >= 36 ? -0.8 : -0.4)
            .lineLimit(1)
    }

    /// Applies the lightweight, 144Hz-friendly numeric digit morph for smooth live value changes.
    /// Use on any Text showing updating temperatures, RPMs, %, loads, battery, etc.
    /// Pair with .animation(.easeOut(duration: 0.22), value: rawValue) on an ancestor for best results.
    /// Avoid on static or Canvas-drawn numbers.
    func macFanLiveNumberTransition() -> some View {
        self.contentTransition(.numericText())
    }

    /// Dedicated for chart axis, tick labels, legends. Crisp on dark HUDs.
    func macFanChartLabel() -> some View {
        font(.macFanChartAxis)
            .foregroundStyle(Color.macFanMuted)
            .kerning(0.25)
    }

    /// Chart/HUD value or inspection label (e.g. hovered point values).
    func macFanChartValue() -> some View {
        font(.macFanChartValue)
            .monospacedDigit()
            .kerning(-0.05)
    }

    /// Premium inspection / HUD pill used on chart scrubs. Feels special when it appears.
    func macFanInspectionPill() -> some View {
        self
            .font(.macFanChartValue)
            .monospacedDigit()
            .kerning(-0.05)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.macFanStroke.opacity(0.35), lineWidth: 0.6))
    }

    /// Tiny crisp tick / axis annotation (used in Canvas draws).
    func macFanChartTick() -> some View {
        font(.macFanChartTick)
            .foregroundStyle(Color.macFanMuted.opacity(0.92))
            .kerning(0.1)
    }

    /// Cheap hover acknowledgement for actionable controls. It never adds a
    /// layer, shadow, or texture, so scrolling beneath the pointer stays calm.
    func macFanHoverLift(scale: CGFloat = MacFanMetrics.hoverScale, grainBoost: CGFloat = 0) -> some View {
        modifier(MacFanHoverLift(scale: scale, grainBoost: grainBoost))
    }
}

private struct MacFanHoverLift: ViewModifier {
    let scale: CGFloat
    let grainBoost: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(!reduceMotion && isHovering ? min(scale, 1.004) : 1)
            .brightness(isHovering ? MacFanMetrics.hoverBrightness : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isHovering)
            .onHover { hovering in isHovering = hovering }
    }
}

extension FanMode {
    var uiTitle: String {
        switch self {
        case .system: "Auto"
        case .smartBoost: "Smart"
        case .max: "Max"
        case .expert: "Manual"
        }
    }

    var uiSubtitle: String {
        switch self {
        case .system: "macOS control"
        case .smartBoost: "Heat aware"
        case .max: "Full blast"
        case .expert: "Per-fan speed"
        }
    }

    var uiIcon: String {
        switch self {
        case .system: "moon"
        case .smartBoost: "sparkles"
        case .max: "wind"
        case .expert: "slider.horizontal.3"
        }
    }

    var uiAccent: Color {
        switch self {
        case .system: .macFanBlue
        case .smartBoost: .macFanViolet
        case .max: .macFanCoral
        case .expert: .macFanAmber
        }
    }
}

extension ThermalBand {
    var color: Color {
        switch self {
        case .muted: .macFanMuted
        case .cool: .macFanSky
        case .indigo: .macFanIndigo
        case .violet: .macFanPurple
        case .amber: .macFanAmber
        case .hot: .macFanCoral
        }
    }
}

extension View {
    func macFanCard(padding: CGFloat = 10, radius: CGFloat = 12, flatten: Bool = true) -> some View {
        self.padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.macFanSurfaceHigh.opacity(0.94))
                    .shadow(
                        color: .black.opacity(flatten ? 0 : 0.10),
                        radius: flatten ? 0 : 4,
                        y: flatten ? 0 : 1
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.white.opacity(0.075), lineWidth: 0.5)
            }
    }

    /// Section headers use a restrained uppercase rhythm.
    func macFanSectionLabel() -> some View {
        font(.macFanCaption)
            .kerning(0.42)
            .foregroundStyle(Color.macFanMuted)
            .textCase(.uppercase)
    }

}

/// Default row/card press. Large surfaces move less than one point and lose a
/// little luminance, which reads as contact without forcing a new render layer.
struct MacFanPressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var thermalBand: ThermalBand? = nil
    /// Icon-only buttons may pass about 0.97; rows should keep the default.
    var pressedScale: CGFloat = MacFanMetrics.pressScale

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed
        let scale = !reduceMotion && isPressed ? pressedScale : 1.0
        let yOff = !reduceMotion && isPressed ? MacFanMetrics.pressOffsetY : 0
        let bright = isPressed ? MacFanMetrics.pressBrightness : 0

        configuration.label
            .scaleEffect(scale)
            .offset(y: yOff)
            .brightness(bright)
            .opacity(isPressed ? 0.94 : 1)
            .animation(reduceMotion ? nil : MacFanMetrics.springPress, value: isPressed)
    }
}

/// A one-shot accent ring that expands and fades the instant something
/// *engages* — a mode actually taking hold, a boost arming. It is the visual
/// half of the arrival haptic: sight and touch on the same frame. Finite and
/// transform-only, so the view returns to a fully static composite at rest;
/// fully suppressed under Reduce Motion.
struct MacFanEngagePulse: ViewModifier {
    let isActive: Bool
    var accent: Color = .macFanVioletLight
    var cornerRadius: CGFloat = 10
    var maxScale: CGFloat = 1.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringScale: CGFloat = 1
    @State private var ringOpacity: Double = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(accent, lineWidth: 1.5)
                        .scaleEffect(ringScale)
                        .opacity(ringOpacity)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: isActive) { _, active in
                guard active, !reduceMotion else { return }
                // Reset without animation, then animate the expansion — the
                // established "ping" pattern (see LiveDot.playArrivalPulse).
                ringScale = 1
                ringOpacity = 0.85
                withAnimation(.easeOut(duration: 0.55)) {
                    ringScale = maxScale
                    ringOpacity = 0
                }
            }
    }
}

extension View {
    /// Play a one-shot accent ring when `isActive` becomes true.
    func macFanEngagePulse(isActive: Bool, accent: Color, cornerRadius: CGFloat = 10, maxScale: CGFloat = 1.5) -> some View {
        modifier(MacFanEngagePulse(isActive: isActive, accent: accent, cornerRadius: cornerRadius, maxScale: maxScale))
    }
}

/// Subtle trackpad tick on press — the physical half of the press spring.
/// Force Touch trackpads render it; others simply ignore it.
enum MacFanHaptics {
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
    }

    /// Deeper thunk for a completed state change — a mode actually engaging,
    /// control passing preflight. The moment of arrival, not the request.
    static func success() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .drawCompleted)
    }
}

/// Legacy names retained for call sites; behavior is intentionally cheap.
extension View {
    func macFanHoverSpecial(scale: CGFloat = MacFanMetrics.hoverScale) -> some View {
        self.modifier(MacFanHoverSpecial(scale: scale))
    }
}

private struct MacFanHoverSpecial: ViewModifier {
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(!reduceMotion && isHovering ? min(scale, 1.004) : 1.0)
            .brightness(isHovering ? MacFanMetrics.hoverBrightness : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isHovering)
            .onHover { hovering in isHovering = hovering }
    }
}



/// A fan glyph with one restrained arrival turn. Live RPM updates intentionally
/// do not animate it: telemetry must never compete with scrolling or control
/// feedback for the render loop.
struct SpinningFanBlades: View {
    let rpm: Double
    var font: Font = .macFanCaption
    var color: Color = .macFanVioletLight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = 0.0

    var body: some View {
        Image(systemName: "fanblades.fill")
            .font(font)
            .foregroundStyle(color)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                guard !reduceMotion, rpm >= 1 else { return }
                withAnimation(.easeOut(duration: 0.42).delay(0.05)) { rotation += 120 }
            }
    }
}

struct MacFanBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.macFanSurface.opacity(0.92), Color.macFanCanvas],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            GrainOverlay()
        }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Live status indicator with a short arrival pulse. Keeping this animation
/// finite lets the window return to a static composited state while idle.
struct LiveDot: View {
    var color: Color = .macFanMint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            if !reduceMotion {
                Circle()
                    .stroke(color.opacity(0.42), lineWidth: 1)
                    .frame(width: 7, height: 7)
                    .scaleEffect(pulsing ? 2.2 : 1)
                    .opacity(pulsing ? 0 : 0.55)
            }
        }
        .frame(width: 9, height: 9)
        .onAppear { playArrivalPulse() }
        .onChange(of: color) { _, _ in playArrivalPulse() }
        .accessibilityHidden(true)
    }

    private func playArrivalPulse() {
        guard !reduceMotion else { return }
        pulsing = false
        withAnimation(.easeOut(duration: 0.7)) { pulsing = true }
    }
}

struct FanMeter: View {
    let fan: FanReading
    var isSelected: Bool = false

    private var coolingPercent: Int {
        Int((fan.normalizedActual * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 9) {
                    SpinningFanBlades(rpm: fan.actualRPM)
                        .frame(width: 24, height: 24)
                        .background(Color.macFanViolet.opacity(0.12), in: RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous))
                    Text(fan.name)
                        .macFanHeadline()
                        .foregroundStyle(Color.macFanPrimary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Text(fan.actualRPM < 1 ? "Stopped" : fan.displayActual)
                        .macFanLabel(tracking: 0.6)
                        .foregroundStyle(Color.macFanSecondary)
                        .macFanLiveNumberTransition()
                    if fan.actualRPM >= 1 {
                        Text("RPM")
                            .macFanCaption()
                            .foregroundStyle(Color.macFanMuted)
                    }
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    if fan.normalizedActual > 0 {
                        Capsule()
                            .fill(LinearGradient(colors: [.macFanViolet, .macFanCyan], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, proxy.size.width * fan.normalizedActual))
                    }
                    if let normalized = fan.normalizedFirmwareTarget {
                        Rectangle()
                            .fill(Color.macFanPrimary.opacity(0.75))
                            .frame(width: 2, height: 10)
                            .offset(x: max(0, proxy.size.width * normalized - 1))
                    }
                }
            }
            .frame(height: 6)
            HStack {
                let targetHigh = fan.firmwareTargetRPM.map { $0 > fan.maximumRPM * 0.9 } ?? false
                Text(fan.actualRPM < 1 ? (targetHigh ? "Target max (ramping...)" : "Stopped / ramping") : "\(coolingPercent)% of range")
                    .macFanNumber(11, weight: .medium)
                    .foregroundStyle(Color.macFanSecondary)
                Spacer()
                Text(fan.firmwareTargetRPM == nil ? "SMC auto" : "SMC \(fan.displayFirmwareTarget)")
                    .macFanNumber(11, weight: .regular)
                    .foregroundStyle(Color.macFanMuted)
            }
            if fan.hasObservedOverspeed {
                Label("Observed above reported maximum", systemImage: "exclamationmark.triangle.fill")
                    .macFanLabel(tracking: 0.5)
                    .foregroundStyle(Color.macFanAmberLight)
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous)
                    .stroke(Color.macFanAmber.opacity(0.32), lineWidth: 0.75)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(fan.name) fan")
        .accessibilityValue(fan.actualRPM < 1
            ? "stopped or ramping (full blast requested if in Max mode), reported maximum \(Int(fan.maximumRPM)) RPM"
            : "actual \(fan.displayActual) RPM, reported maximum \(Int(fan.maximumRPM)) RPM\(fan.firmwareTargetRPM.map { ", firmware target \(Int($0.rounded())) RPM" } ?? ", firmware automatic")")
    }
}

/// Fritsch–Carlson monotone cubic through `points`. Clamped tangents keep the
/// curve inside the data envelope, so smoothing can never draw a peak the
/// samples don't contain — critical for a thermal chart.
func addMonotoneCurve(_ points: [CGPoint], to path: inout Path) {
    guard let first = points.first else { return }
    guard points.count > 2 else {
        path.move(to: first)
        if points.count == 2 { path.addLine(to: points[1]) }
        return
    }
    let n = points.count
    var secants = [CGFloat](repeating: 0, count: n - 1)
    for i in 0..<(n - 1) {
        let dx = points[i + 1].x - points[i].x
        secants[i] = dx == 0 ? 0 : (points[i + 1].y - points[i].y) / dx
    }
    var tangents = [CGFloat](repeating: 0, count: n)
    tangents[0] = secants[0]
    tangents[n - 1] = secants[n - 2]
    for i in 1..<(n - 1) {
        tangents[i] = secants[i - 1] * secants[i] <= 0 ? 0 : (secants[i - 1] + secants[i]) / 2
    }
    for i in 0..<(n - 1) {
        guard secants[i] != 0 else {
            tangents[i] = 0
            tangents[i + 1] = 0
            continue
        }
        let a = tangents[i] / secants[i]
        let b = tangents[i + 1] / secants[i]
        let magnitude = a * a + b * b
        if magnitude > 9 {
            let t = 3 / magnitude.squareRoot()
            tangents[i] = t * a * secants[i]
            tangents[i + 1] = t * b * secants[i]
        }
    }
    path.move(to: first)
    for i in 0..<(n - 1) {
        let dx = points[i + 1].x - points[i].x
        path.addCurve(
            to: points[i + 1],
            control1: CGPoint(x: points[i].x + dx / 3, y: points[i].y + tangents[i] * dx / 3),
            control2: CGPoint(x: points[i + 1].x - dx / 3, y: points[i + 1].y - tangents[i + 1] * dx / 3)
        )
    }
}

/// Lightweight sparkline used by summary cards. The endpoint is a crisp dot;
/// there are no blur or glow layers.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    var lineWidth: CGFloat = 2
    /// Minimum vertical domain. Without it, 1° of idle noise fills the full
    /// height and reads as a thermal event; with it the trace is centered and
    /// honest. Pass in the series' native unit (°C, RPM, %).
    var minimumSpan: Double = 0

    var body: some View {
        Canvas { context, size in
            guard values.count > 1,
                  let minimum = values.min(),
                  let maximum = values.max() else { return }
            let dataSpan = maximum - minimum
            let span = max(dataSpan, minimumSpan, 0.001)
            let floor = span > dataSpan ? (maximum + minimum) / 2 - span / 2 : minimum
            let step = size.width / CGFloat(values.count - 1)
            let isConstant = dataSpan < 0.001 && minimumSpan <= 0
            let point: (Int) -> CGPoint = { index in
                CGPoint(
                    x: CGFloat(index) * step,
                    y: isConstant
                        ? size.height / 2
                        : size.height - 3 - (size.height - 6) * CGFloat((values[index] - floor) / span)
                )
            }
            let points = (0..<values.count).map(point)

            var line = Path()
            addMonotoneCurve(points, to: &line)

            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.14), color.opacity(0)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            let last = points[points.count - 1]
            let dotRadius = max(lineWidth * 1.3, 2)
            context.fill(
                Path(ellipseIn: CGRect(x: last.x - dotRadius, y: last.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)),
                with: .color(color)
            )
        }
        .accessibilityHidden(true)
    }
}

/// Procedural fine-grain texture overlay for premium tactile quality.
/// Delivers the noticeable yet refined "grainy" feel you asked for (like high-end Usage-style apps).
/// Apple-made: perfectly uniform, deterministic, never noisy or cheap. Fine dots give subtle paper-like tactility
/// under materials. Interaction boost makes it come alive on hover/tap for that alive, perfect micro-detail.
struct GrainOverlay: View {
    var opacity: Double = MacFanMetrics.grainOpacity
    var density: CGFloat = MacFanMetrics.grainDensity
    var dotSize: CGFloat = MacFanMetrics.grainDotSize
    var interactionBoost: CGFloat = 0.0
    private let seed: UInt64

    init(opacity: Double = MacFanMetrics.grainOpacity, density: CGFloat = MacFanMetrics.grainDensity, dotSize: CGFloat = MacFanMetrics.grainDotSize, interactionBoost: CGFloat = 0.0, seed: UInt64 = 42) {
        self.opacity = opacity
        self.density = density
        self.dotSize = dotSize
        self.interactionBoost = interactionBoost
        self.seed = seed
    }

    var body: some View {
        // A single pre-rendered noise tile, repeated. The previous per-view
        // Canvas looped width×height/density times on every card (and re-ran
        // whenever interactionBoost flipped on hover); the tile renders once
        // per (density, dotSize, seed) for the app's lifetime.
        GrainTileCache.tile(density: density, dotSize: dotSize, seed: seed)
            .resizable(resizingMode: .tile)
            .opacity(opacity * (1.0 + Double(interactionBoost) * 0.4))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Renders and memoizes small grain tiles. Views only ever pay a dictionary
/// lookup; the bitmap work happens once per parameter set.
private enum GrainTileCache {
    private static let lock = NSLock()
    private static var tiles: [String: Image] = [:]
    /// Tile edge in points; rendered at 2× for Retina crispness.
    private static let edge: CGFloat = 96

    static func tile(density: CGFloat, dotSize: CGFloat, seed: UInt64) -> Image {
        let key = "\(density)-\(dotSize)-\(seed)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = tiles[key] { return cached }
        let image = render(density: density, dotSize: dotSize, seed: seed)
        tiles[key] = image
        return image
    }

    private static func render(density: CGFloat, dotSize: CGFloat, seed: UInt64) -> Image {
        let scale: CGFloat = 2
        let pixels = Int(edge * scale)
        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Image(nsImage: NSImage()) }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let count = Int(edge * edge / max(density, 1))
        let side = max(dotSize, 0.5) * scale
        for index in 0..<count {
            let h = hash(UInt64(index) &+ 1 &+ seed &* 0x9e3779b97f4a7c15)
            let x = CGFloat(h % UInt64(pixels))
            let y = CGFloat((h >> 32) % UInt64(pixels))
            context.fillEllipse(in: CGRect(x: x, y: y, width: side, height: side))
        }
        guard let cgImage = context.makeImage() else { return Image(nsImage: NSImage()) }
        return Image(decorative: cgImage, scale: scale)
    }

    private static func hash(_ x: UInt64) -> UInt64 {
        var h = x
        h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33; h &*= 0xc4ceb9fe1a85ec53; h ^= h >> 33
        return h
    }
}

// MARK: - Premium recap components (for ThermalBriefCard, Overview summaries, and consistent glance UIs)
// Reusable, scannable, use DesignSystem typography/metrics/colors. Lightweight. Actionable context.

/// Compact, premium metric tile for key stats in recap headers and glance rows.
/// Aligns with BriefMetric evolution + Statlet patterns. Icon optional for visual weight.
/// Always monospaced digits on value. Supports sublabel for context (e.g. "of range").
struct RecapMetric: View {
    let label: String
    let value: String
    let tint: Color
    var icon: String? = nil
    var sublabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.macFanCallout)
                        .foregroundStyle(tint.opacity(0.9))
                }
                Text(label)
                    .macFanSubhead()
                    .textCase(.uppercase)
            }
            Text(value)
                .macFanNumber(20, weight: .semibold)
                .foregroundStyle(tint)
                .macFanLiveNumberTransition()
            if let sublabel {
                Text(sublabel)
                    .macFanCallout()
                    .foregroundStyle(Color.macFanMuted)
            }
        }
        .frame(minWidth: 72, alignment: .leading)
    }
}

/// Lightweight Canvas mini-gauge for % based glance values (e.g. cool ratio, effort, coverage).
/// Rounded pill fill, premium subtle gradient + inner stroke. 144Hz friendly, no heavy views.
struct MiniPercentGauge: View {
    let fraction: Double   // 0...1
    let tint: Color
    let label: String?     // e.g. "COOL"
    var height: CGFloat = 9

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label {
                Text(label).macFanSectionLabel()
            }
            Canvas { context, size in
                let w = size.width
                let h = size.height
                let clamped = max(0, min(1, fraction))
                let fillW = max(2, w * clamped)

                // Background track (subtle)
                let bg = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerSize: CGSize(width: h/2, height: h/2))
                context.fill(bg, with: .color(Color.white.opacity(0.06)))

                // Filled portion
                if clamped > 0.001 {
                    let fillRect = CGRect(x: 0, y: 0, width: fillW, height: h)
                    let fillPath = Path(roundedRect: fillRect, cornerSize: CGSize(width: h/2, height: h/2))
                    context.fill(
                        fillPath,
                        with: .linearGradient(
                            Gradient(colors: [tint.opacity(0.92), tint.opacity(0.72)]),
                            startPoint: CGPoint(x: 0, y: 0),
                            endPoint: CGPoint(x: 1, y: 0)
                        )
                    )
                    // Delicate premium highlight
                    if fillW > 8 {
                        let inner = fillRect.insetBy(dx: 0.6, dy: 0.6)
                        context.stroke(Path(roundedRect: inner, cornerSize: CGSize(width: max(1, (h-1.2)/2), height: max(1, (h-1.2)/2))), with: .color(.white.opacity(0.15)), lineWidth: 0.5)
                    }
                }
                // Outer definition
                let outline = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerSize: CGSize(width: h/2, height: h/2))
                context.stroke(outline, with: .color(Color.white.opacity(0.12)), lineWidth: 0.5)
            }
            .frame(height: height)
        }
    }
}
