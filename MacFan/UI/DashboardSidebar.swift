import SwiftUI

/// Left control panel: identity, control status, cooling modes, Smart Boost,
/// fan bank and manual tuning. Confirmation dialogs stay on DashboardView.
struct DashboardSidebar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Binding var selectedTab: DashboardTab
    @Binding var showExpertConfirmation: Bool
    @Binding var showClearHistoryConfirmation: Bool
    @State private var isSmartBoostExpanded = false
    @State private var isManualExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                identityRow
                navigation
                statusCard
            }
            .padding(18)

            Divider().overlay(Color.white.opacity(0.05))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {

                VStack(alignment: .leading, spacing: MacFanMetrics.spacingS) {
                    Text("Cooling mode").macFanSectionLabel()
                    ForEach([FanMode.system, .smartBoost, .max, .expert]) { mode in
                        SidebarModeButton(
                            mode: mode,
                            activeMode: model.activeMode,
                            isEnabled: mode == .system || (model.capability.canControl && model.pendingMode == nil),
                            isPending: model.pendingMode == mode
                        ) {
                            if mode == .expert, !model.isExpertUnlocked {
                                showExpertConfirmation = true
                            } else {
                                model.activate(mode)
                            }
                        }
                    }
                }

                comfortCoolCard

                DisclosureGroup(isExpanded: $isSmartBoostExpanded) {
                    smartBoostCard
                        .padding(.top, 8)
                } label: {
                    disclosureLabel(
                        title: "Smart Boost settings",
                        icon: "thermometer.high",
                        detail: "\(Int(model.smartBoostPolicy.triggerCelsius))°C"
                    )
                }
                .tint(Color.macFanSecondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Fan bank").macFanSectionLabel()
                    if model.snapshot.fans.isEmpty {
                        Text("No live fan reading yet.")
                            .macFanCallout()
                            .foregroundStyle(Color.macFanSecondary)
                    } else {
                        ForEach(model.snapshot.fans) { fan in
                            FanMeter(fan: fan)
                                .padding(MacFanMetrics.cardPaddingS)
                                .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous))
                                .overlay { RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1) }
                        }
                    }
                }

                DisclosureGroup(isExpanded: $isManualExpanded) {
                    manualTuningSection
                        .padding(.top, 8)
                } label: {
                    disclosureLabel(
                        title: "Manual controls",
                        icon: model.isExpertUnlocked ? "slider.horizontal.3" : "lock.fill",
                        detail: model.isExpertUnlocked ? "Unlocked" : "Protected"
                    )
                }
                .tint(Color.macFanSecondary)

                HStack {
                    Button("Clear local history", role: .destructive) { showClearHistoryConfirmation = true }
                        .buttonStyle(MacFanPressableStyle(pressedScale: 0.95))
                        .macFanCaption()
                        .foregroundStyle(Color.macFanMuted)
                    Spacer()
                    Text("Local only")
                        .macFanCaption()
                        .foregroundStyle(Color.macFanMuted)
                }
                }
                .padding(18)
            }
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Dashboard")
                .macFanSectionLabel()
                .padding(.horizontal, 4)

            ForEach(DashboardTab.allCases) { tab in
                Button {
                    guard selectedTab != tab else { return }
                    selectedTab = tab
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: tab.icon)
                            .macFanLabel(tracking: 0.3)
                            .foregroundStyle(selectedTab == tab ? Color.macFanVioletLight : Color.macFanSecondary)
                            .frame(width: 24)
                        Text(tab.rawValue)
                            .macFanSubhead()
                            .foregroundStyle(selectedTab == tab ? Color.macFanPrimary : Color.macFanSecondary)
                        Spacer()
                        if selectedTab == tab {
                            Circle()
                                .fill(Color.macFanVioletLight)
                                .frame(width: 5, height: 5)
                        }
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 40)
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.macFanViolet.opacity(0.14))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(Color.macFanViolet.opacity(0.24), lineWidth: 0.75)
                                }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MacFanPressableStyle())
                .macFanHoverLift()
                .accessibilityIdentifier("dashboard-tab-\(tab.rawValue)")
            }
        }
    }

    private func disclosureLabel(title: String, icon: String, detail: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .macFanSubhead()
                .foregroundStyle(Color.macFanSecondary)
                .frame(width: 18)
            Text(title)
                .macFanSubhead()
                .foregroundStyle(Color.macFanPrimary)
            Spacer()
            Text(detail)
                .macFanCaption()
                .foregroundStyle(Color.macFanMuted)
        }
        .contentShape(Rectangle())
    }

    private var identityRow: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.macFanViolet)
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 19, weight: .semibold, design: .default))  // SF Symbol exception - tuned size for icon
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 1) {
                Text("MacFan")
                    .macFanTitle2()
                    .foregroundStyle(Color.macFanPrimary)
                Text("Thermal control")
                    .macFanCallout()
                    .foregroundStyle(Color.macFanSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(model.snapshot.displayTemperature.map { settings.temperatureUnit.degrees($0.celsius) } ?? "—")
                    .macFanNumber(20, weight: .semibold)
                    .foregroundStyle(Color.macFanPrimary)
                Text("CPU")
                    .macFanCaption()
                    .kerning(1)
                    .foregroundStyle(Color.macFanMuted)
            }
        }
    }

    private var statusCard: some View {
        let ready = model.capability.canControl
        let tint: Color = ready ? .macFanMint : .macFanAmberLight
        return Group {
            if ready {
                HStack(spacing: 9) {
                    LiveDot(color: tint)
                    Text("Failsafe active")
                        .macFanHeadline()
                        .foregroundStyle(Color.macFanPrimary)
                    Spacer()
                    Text("Auto on exit")
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                    Image(systemName: "info.circle")
                        .foregroundStyle(Color.macFanMuted)
                        .help("Quitting MacFan or losing its heartbeat immediately returns every fan to Auto.")
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 9) {
                        Image(systemName: "lock.fill").foregroundStyle(tint)
                        Text("Control setup required")
                            .macFanHeadline()
                            .foregroundStyle(Color.macFanPrimary)
                    }
                    Text(model.capability.detail)
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MacFanMetrics.cardPaddingS)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous).stroke(Color.white.opacity(0.065), lineWidth: 0.5) }
    }

    /// One-tap comfort cooling — set it once and MacFan keeps the chassis off
    /// the owner's lap automatically, across restarts. Backed by the failsafed
    /// Smart Boost engine.
    private var comfortCoolCard: some View {
        let on = model.keepCoolAtLaunch
        let tint = Color.macFanCyan
        return Button {
            if on { model.stopComfortCooling() } else { model.engageComfortCooling() }
            MacFanHaptics.success()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "snowflake")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(on ? tint : Color.macFanSecondary)
                    .frame(width: 34, height: 34)
                    .background((on ? tint : Color.white).opacity(on ? 0.18 : 0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .macFanEngagePulse(isActive: on, accent: tint, cornerRadius: 10, maxScale: 1.6)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep my lap cool")
                        .macFanSubhead()
                        .foregroundStyle(Color.macFanPrimary)
                    Text(comfortSubtitle)
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                ZStack {
                    Capsule().fill(on ? tint.opacity(0.9) : Color.white.opacity(0.12)).frame(width: 38, height: 22)
                    Circle().fill(.white).frame(width: 17, height: 17).offset(x: on ? 8 : -8)
                }
            }
            .padding(13)
            .background(on ? tint.opacity(0.08) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(on ? tint.opacity(0.30) : Color.white.opacity(0.06), lineWidth: on ? 1 : 0.5) }
        }
        .buttonStyle(MacFanPressableStyle(pressedScale: 0.985))
        .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.80), value: on)
        .accessibilityLabel(on ? "Keep my lap cool, on" : "Keep my lap cool, off")
        .accessibilityHint("Automatically ramps the fans at 80 degrees and holds them for five minutes")
    }

    private var comfortSubtitle: String {
        if model.keepCoolAtLaunch {
            return model.capability.canControl
                ? "On · fans ramp at 80°C, hold 5 min"
                : "Armed · starts when control is ready"
        }
        return "Ramps fans at 80°C, holds 5 min. Stays on across restarts."
    }

    private var smartBoostCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Smart Boost").macFanSectionLabel()
                Spacer()
                Text(model.smartBoostStatus == .inactive
                     ? "\(Int(model.smartBoostPolicy.triggerCelsius))°C"
                     : model.smartBoostStatus.title.uppercased())
                    .macFanNumber(10, weight: .semibold)
                    .foregroundStyle(Color.macFanVioletLight)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.macFanViolet.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.macFanViolet.opacity(0.26), lineWidth: 1) }
            }
            HStack(spacing: 6) {
                ForEach([SmartBoostPolicy.comfort, .balanced, .quiet], id: \.triggerCelsius) { preset in
                    let selected = model.smartBoostPolicy == preset
                    Button(preset.presetName ?? "") {
                        model.smartBoostPolicy = preset
                    }
                    .buttonStyle(MacFanPressableStyle(pressedScale: 0.94))
                    .macFanCaption()
                    .foregroundStyle(selected ? Color.macFanPrimary : Color.macFanSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(selected ? Color.macFanBlue.opacity(0.18) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(selected ? Color.macFanBlue.opacity(0.32) : Color.white.opacity(0.06), lineWidth: selected ? 1 : 0.5) }
                }
            }
            .disabled(!model.capability.canControl)
            .padding(.top, 12)
            Slider(value: $model.smartBoostPolicy.triggerCelsius, in: 60...95, step: 1)
                .tint(.macFanBlue)
                .disabled(!model.capability.canControl)
                .padding(.top, 10)
            Text(model.capability.canControl
                 ? "Arms at \(Int(model.smartBoostPolicy.triggerCelsius))°C, requests Max only while hot, then eases back to Auto \(Int(model.smartBoostPolicy.cooldownHold / 60)) min after it cools \(Int(model.smartBoostPolicy.cooldownDelta))°C."
                 : "Available only after verified experimental control passes preflight.")
                .macFanCallout()
                .lineSpacing(2)
                .foregroundStyle(Color.macFanSecondary)
                .padding(.top, 10)
        }
        .opacity(model.capability.canControl ? 1 : 0.55)
        .padding(MacFanMetrics.cardPadding)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: MacFanMetrics.radiusL, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: MacFanMetrics.radiusL, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1) }
    }

    @ViewBuilder
    private var manualTuningSection: some View {
        if !model.capability.canControl {
            Text("Per-fan controls unlock after the local helper passes its hardware preflight.")
                .macFanCallout()
                .foregroundStyle(Color.macFanMuted)
        } else if model.isExpertUnlocked {
            VStack(alignment: .leading, spacing: 10) {
                Text("Manual tuning").macFanSectionLabel()
                expertControls
            }
            .padding(MacFanMetrics.cardPadding)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: MacFanMetrics.radiusL, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: MacFanMetrics.radiusL, style: .continuous).stroke(Color.macFanAmber.opacity(0.18), lineWidth: 1) }
        } else {
            Button { showExpertConfirmation = true } label: {
                HStack(spacing: 9) {
                    Image(systemName: "lock.open")
                        .macFanHeadline()
                    Text("Unlock manual control")
                        .macFanHeadline()
                }
                .foregroundStyle(Color.macFanAmberLight)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    LinearGradient(colors: [.macFanAmber.opacity(0.115), .macFanAmber.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous)
                )
                .overlay { RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous).stroke(Color.macFanAmber.opacity(0.26), lineWidth: 1) }
            }
            .buttonStyle(MacFanPressableStyle())
        }
    }

    @ViewBuilder
    private var expertControls: some View {
        if model.snapshot.fans.isEmpty {
            Text("Fan telemetry is required before targets can be edited.")
                .macFanCallout()
                .foregroundStyle(Color.macFanSecondary)
        } else {
            ForEach(model.snapshot.fans) { fan in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(fan.name).macFanLabel(tracking: 0.8).foregroundStyle(Color.macFanPrimary)
                        Spacer()
                        Text("\(Int((model.expertRPM[fan.id] ?? fan.actualRPM).rounded())) RPM")
                            .macFanNumber(11, weight: .bold)
                            .foregroundStyle(Color.macFanAmberLight)
                    }
                    Slider(
                        value: Binding(
                            get: { model.expertRPM[fan.id] ?? max(fan.minimumRPM, fan.actualRPM) },
                            set: { model.expertRPM[fan.id] = min(max($0, fan.minimumRPM), fan.maximumRPM) }
                        ),
                        in: fan.minimumRPM...max(fan.minimumRPM + 1, fan.maximumRPM),
                        step: 25
                    )
                    .tint(.macFanAmber)
                    HStack(spacing: 6) {
                        Text("\(Int(fan.minimumRPM))")
                            .macFanCaption()
                            .foregroundStyle(Color.macFanMuted)
                        Spacer()
                        ForEach([0.5, 0.75, 1.0], id: \.self) { fraction in
                            ManualPresetButton(title: fraction == 1 ? "Max" : "\(Int(fraction * 100))%") {
                                setExpertTarget(fan: fan, fraction: fraction)
                            }
                        }
                        Spacer()
                        Text("\(Int(fan.maximumRPM))")
                            .macFanCaption()
                            .foregroundStyle(Color.macFanMuted)
                    }
                }
                .padding(MacFanMetrics.cardPaddingS)
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous))
            }
            Toggle("Use temperature curve", isOn: $model.expertUsesCurve)
                .macFanLabel(tracking: 0.6)
                .tint(.macFanAmber)
            if model.expertUsesCurve { expertCurveSummary }
            Button { model.activate(.expert) } label: {
                HStack {
                    Image(systemName: model.expertUsesCurve ? "point.topleft.down.to.point.bottomright.curvepath" : "fanblades.fill")
                    Text(model.expertUsesCurve ? "Apply temperature curve" : "Apply manual speeds")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .macFanLabel(tracking: 0.4)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(MacFanPressableStyle(pressedScale: 0.98))
            .foregroundStyle(Color.macFanCanvas)
            .background(Color.macFanAmber, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityIdentifier("apply-manual-speeds")
        }
    }

    private func setExpertTarget(fan: FanReading, fraction: Double) {
        let value = fan.maximumRPM * fraction
        model.expertRPM[fan.id] = min(max(value, fan.minimumRPM), fan.maximumRPM)
    }

    @ViewBuilder
    private var expertCurveSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.snapshot.fans) { fan in
                if let curve = model.expertCurves[fan.id] {
                    DisclosureGroup("\(fan.name) curve") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(curve.points.enumerated()), id: \.offset) { index, point in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(Int(point.temperature.rounded()))°C  ·  \(Int(point.rpm.rounded())) RPM")
                                        .macFanNumber(11, weight: .regular)
                                        .foregroundStyle(Color.macFanSecondary)
                                    Slider(
                                        value: curveBinding(fan: fan, index: index, keyPath: \.temperature),
                                        in: 30...95,
                                        step: 1
                                    )
                                    .tint(.macFanViolet)
                                    Slider(
                                        value: curveBinding(fan: fan, index: index, keyPath: \.rpm),
                                        in: fan.minimumRPM...max(fan.minimumRPM + 1, fan.maximumRPM),
                                        step: 25
                                    )
                                    .tint(.macFanAmber)
                                }
                            }
                        }
                        .padding(.top, 5)
                    }
                    .macFanSubhead()
                    .tint(.macFanSecondary)
                }
            }
            Text("The 95°C point is always pinned to the reported maximum RPM.")
                .macFanCaption()
                .foregroundStyle(Color.macFanMuted)
        }
        .padding(MacFanMetrics.spacingS)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous))
    }

    private func curveBinding(fan: FanReading, index: Int, keyPath: WritableKeyPath<FanCurvePoint, Double>) -> Binding<Double> {
        Binding(
            get: {
                guard let curve = model.expertCurves[fan.id], curve.points.indices.contains(index) else {
                    return keyPath == \.temperature ? 30 : fan.minimumRPM
                }
                return curve.points[index][keyPath: keyPath]
            },
            set: { value in
                guard var curve = model.expertCurves[fan.id], curve.points.indices.contains(index) else { return }
                curve.points[index][keyPath: keyPath] = value
                model.expertCurves[fan.id] = curve.validated(minimumRPM: fan.minimumRPM, maximumRPM: fan.maximumRPM)
            }
        )
    }
}

struct SidebarModeButton: View {
    let mode: FanMode
    let activeMode: FanMode
    let isEnabled: Bool
    var isPending = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool { activeMode == mode }
    /// Each mode owns its accent, so engaging Max glows coral, Smart violet,
    /// Manual amber and Auto blue — the press reads as a distinct event.
    private var accent: Color { mode.uiAccent }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: mode.uiIcon)
                    .symbolEffect(.bounce, options: .nonRepeating, value: isActive && !reduceMotion)
                    .font(.system(size: 14, weight: .semibold))  // SF Symbol exception - tuned size for icon
                    .foregroundStyle(isActive ? accent : Color.macFanSecondary)
                    .frame(width: 34, height: 34)
                    .background(
                        isActive ? accent.opacity(0.20) : Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .macFanEngagePulse(isActive: isActive, accent: accent, cornerRadius: 10, maxScale: 1.6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.uiTitle)
                        .macFanSubhead()
                        .foregroundStyle(isActive ? Color.macFanPrimary : Color.macFanPrimary.opacity(0.82))
                    Text(mode.uiSubtitle)
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                }
                Spacer()
                if isPending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accent)
                        .transition(.opacity)
                } else if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))  // SF Symbol exception - tuned size for icon
                        .foregroundStyle(accent)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.35).combined(with: .opacity))
                } else if !isEnabled {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))  // SF Symbol exception - tuned size for icon
                        .foregroundStyle(Color.macFanMuted)
                        .frame(width: 18, height: 18)
                } else {
                    Circle()
                        .stroke(Color.white.opacity(0.14), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                        .transition(.opacity)
                }
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86),
                value: isActive
            )
            .animation(reduceMotion ? nil : MacFanMetrics.springFast, value: isPending)
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .background(isActive ? Color.white.opacity(0.07) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(isActive ? accent.opacity(0.28) : Color.white.opacity(0.055), lineWidth: isActive ? 1 : 0.5)
            }
        }
        .buttonStyle(MacFanPressableStyle(pressedScale: 0.98))
        .macFanHoverSpecial()
        .disabled(!isEnabled)
        .opacity(isEnabled || isPending ? 1 : 0.48)
        .accessibilityHint(isEnabled ? mode.subtitle : "Unavailable until experimental control has passed preflight")
        .accessibilityIdentifier("mode-\(mode.rawValue)")
    }
}

struct ManualPresetButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(MacFanPressableStyle(pressedScale: 0.92))
            .macFanLabel(tracking: 0.3)
            .foregroundStyle(Color.macFanAmberLight)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.macFanAmber.opacity(0.10), in: Capsule())
            .overlay { Capsule().stroke(Color.macFanAmber.opacity(0.24), lineWidth: 1) }
    }
}
