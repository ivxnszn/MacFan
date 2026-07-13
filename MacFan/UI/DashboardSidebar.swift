import AppKit
import SwiftUI

/// Left control panel (premium compact): identity + nav, capability status with
/// explanation, vitals strip (sensors/fans/avg-RPM/uptime/health), quick actions micros,
/// modes + Smart/fan/expert. Uses DesignSystem everywhere. Keeps dense but readable.
struct DashboardSidebar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Binding var selectedTab: DashboardTab
    @Binding var showExpertConfirmation: Bool
    @Binding var showClearHistoryConfirmation: Bool
    @State private var isSmartBoostExpanded = false
    @State private var isManualExpanded = false
    /// Local focus only; the helper still receives a complete validated target map.
    @State private var selectedFanID: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: MacFanMetrics.spacing) {
                identityRow
                navigation
                statusCard
                glanceRow
                    .padding(.top, -3)

                quickActions
                    .padding(.top, MacFanMetrics.spacingXS)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().overlay(Color.white.opacity(0.05))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: MacFanMetrics.spacing) {

                VStack(alignment: .leading, spacing: MacFanMetrics.spacingXS) {
                    Text("Cooling mode").macFanSectionLabel()
                    ForEach([FanMode.system, .smartBoost, .max, .expert]) { mode in
                        SidebarModeButton(
                            mode: mode,
                            activeMode: model.activeMode,
                            isEnabled: mode == .system || model.pendingMode == nil || model.pendingMode == mode,
                            isPending: model.pendingMode == mode
                        ) {
                            if mode == .expert, !model.isExpertUnlocked {
                                showExpertConfirmation = true
                            } else {
                                if mode != .system && !model.capability.canControl {
                                    model.forceCapabilityRefresh()
                                }
                                model.activate(mode)
                            }
                        }
                    }

                    // Current mode explanation — compact, interesting context without clutter.
                    // Uses active accent for micro LiveDot. Lightweight single-line.
                    HStack(spacing: 5) {
                        LiveDot(color: model.activeMode.uiAccent.opacity(0.75))
                        Text(modeExplanation)
                            .macFanCallout()
                            .foregroundStyle(Color.macFanSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 0)
                    .padding(.bottom, 2)
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

                VStack(alignment: .leading, spacing: MacFanMetrics.spacingXS) {
                    Text("Fan bank").macFanSectionLabel()
                    if model.snapshot.fans.isEmpty {
                        Text("No live fan reading yet.")
                            .macFanCallout()
                            .foregroundStyle(Color.macFanSecondary)
                    } else {
                        ForEach(model.snapshot.fans) { fan in
                            Button {
                                selectedFanID = fan.id
                                isManualExpanded = true
                            } label: {
                                FanMeter(fan: fan, isSelected: selectedFanID == fan.id)
                                    .padding(MacFanMetrics.cardPaddingS)
                                    .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .overlay {
                                RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous)
                                    .stroke(selectedFanID == fan.id ? Color.macFanAmber.opacity(0.45) : Color.white.opacity(0.06), lineWidth: 1)
                            }
                            .accessibilityIdentifier("fan-select-\(fan.id)")
                            .accessibilityHint("Select this fan for manual tuning")
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

                HStack(spacing: 6) {
                    Button("Clear history", role: .destructive) { showClearHistoryConfirmation = true }
                        .buttonStyle(MacFanPressableStyle(pressedScale: 0.95))
                        .macFanCaption()
                        .foregroundStyle(Color.macFanMuted)
                    Spacer()
                    Text("Local")
                        .macFanCaption()
                        .foregroundStyle(Color.macFanMuted)
                }
                }
                .padding(18)
            }
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: MacFanMetrics.spacingXS) {
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
                    .padding(.horizontal, 9)
                    .frame(height: 32)
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
        .padding(.bottom, 2)
        .background(GrainOverlay(opacity: 0.006, density: 140, dotSize: 0.38).clipShape(RoundedRectangle(cornerRadius: 8)), alignment: .topLeading)
    }

    private var statusCard: some View {
        let cap = model.capability
        let ready = cap.canControl
        let tint: Color = ready ? .macFanMint : .macFanAmberLight
        return VStack(alignment: .leading, spacing: MacFanMetrics.spacingXS) {
            // Keep the title and the safety affordance in separate columns. The
            // old single-line row gave "Control ready" and its badge competing
            // widths, which produced the visible "Control re…" truncation.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                LiveDot(color: tint)
                Text(ready ? "Control ready" : cap.shortReason)
                    .macFanHeadline()
                    .foregroundStyle(Color.macFanPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .accessibilityIdentifier("control-status-title")
                if !cap.monitorLabel.isEmpty {
                    Text(cap.monitorLabel)
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.04), in: Capsule())
                }
                Spacer(minLength: 0)
                if ready {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.macFanMuted)
                        .help("Quitting MacFan or losing its heartbeat immediately returns every fan to Auto.")
                }
            }

            if ready {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.macFanMint)
                    Text("Auto on exit · watchdog protected")
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .padding(.leading, 2)
            }

            // Two readable lines beat a single clipped sentence. The full
            // capability detail remains available through the card's help text.
            Text(cap.canControl ? "Smart Boost, Max, and Expert are ready." : "Monitoring stays active; fan control is unavailable.")
                .macFanBody()
                .foregroundStyle(Color.macFanSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)

            if !ready {
                Text("Why: \(cap.whyMessage)")
                    .macFanSubhead()
                    .foregroundStyle(Color.macFanSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
                HStack(spacing: 6) {
                    Button("Recheck") { model.forceCapabilityRefresh() }
                        .buttonStyle(MacFanPressableStyle(pressedScale: 0.94))
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                    Button("Open Settings") {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                        .buttonStyle(MacFanPressableStyle(pressedScale: 0.94))
                        .macFanCallout()
                        .foregroundStyle(Color.macFanBlue)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MacFanMetrics.cardPaddingS)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous)
                .stroke(Color.white.opacity(0.065), lineWidth: 0.5)
            GrainOverlay(opacity: MacFanMetrics.grainOpacity * 0.5, density: 110, dotSize: 0.42)
                .clipShape(RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous))
        }
        .help([cap.whatItMeans, cap.whyMessage, cap.howToFix]
            .filter { !$0.isEmpty }
            .joined(separator: " "))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("control-status-card")
        .accessibilityLabel(ready ? "Control ready. Auto on exit." : "\(cap.shortReason). Monitoring only.")
    }

    /// Compact, scannable vitals strip. Beautiful micros using DesignSystem (LiveDot, macFanNumber,
    /// 8pt rhythm, capsules). Adds avg fan RPM + richer health for interesting at-a-glance data.
    /// Lightweight: snapshot + ProcessInfo only.
    private var glanceRow: some View {
        let sensorCount = model.snapshot.sensors.count
        let fanCount = model.snapshot.fans.count
        let ready = model.capability.canControl
        let healthTint: Color = ready ? .macFanMint : .macFanAmberLight
        let thermal = model.snapshot.displayTemperature?.celsius
        let band = thermal.map { ThermalPalette.band(for: $0) } ?? .muted
        let avgRPM = model.snapshot.averageActualRPM
        let avgText = avgRPM.map { "\(Int($0))" } ?? "—"

        return HStack(spacing: 5) {
            glanceMetric(icon: ready ? "checkmark.shield.fill" : "lock.slash", value: ready ? "Ready" : "Read-only", tint: healthTint)
            glanceMetric(icon: "sensor.tag.radiowaves.forward", value: "\(sensorCount)s", tint: .macFanIndigo)
            glanceMetric(icon: "fanblades.fill", value: "\(fanCount)f", tint: .macFanViolet)
            if fanCount > 0 { glanceMetric(icon: "gauge.medium", value: avgText, tint: .macFanCyan) }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Circle().fill(band.color.opacity(0.9)).frame(width: 5, height: 5)
                Text(healthLabel(ready: ready, band: band, temp: thermal))
                    .macFanCallout()
                    .foregroundStyle(Color.macFanSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .help("Session uptime: \(uptimeText(ProcessInfo.processInfo.systemUptime))")
        }
        .macFanLabel(tracking: 0.1)
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .background(
            Color.macFanSurfaceHigh.opacity(0.6),
            in: RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous)
        )
        .overlay {
            GrainOverlay(opacity: MacFanMetrics.grainOpacity * 0.55, density: 128, dotSize: 0.4)
                .clipShape(RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous)
                .stroke(Color.macFanStroke.opacity(0.32), lineWidth: 0.5)
        }
    }

    private func glanceMetric(icon: String, value: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .macFanNumber(10, weight: .semibold)
                .foregroundStyle(Color.macFanPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.035), in: Capsule(style: .continuous))
    }

    /// Ultra-compact quick actions using micros. Icon-forward, high-signal, premium feel.
    /// Aligned to DesignSystem: tight capsules, pressables, accents, haptics.
    private var quickActions: some View {
        let canControl = model.capability.canControl
        let hasPending = model.pendingMode != nil
        let burstActive = model.coolBurstUntil != nil

        return HStack(spacing: 5) {
            quickActionButton(
                icon: "moon",
                label: "Auto",
                accent: .macFanBlue,
                disabled: hasPending,
                action: { model.activate(.system); MacFanHaptics.tick() }
            )

            quickActionButton(
                icon: "sparkles",
                label: "Smart",
                accent: .macFanViolet,
                disabled: !canControl || hasPending,
                action: { model.activate(.smartBoost); MacFanHaptics.tick() }
            )

            quickActionButton(
                icon: "bolt.fill",
                label: burstActive ? "Stop" : "Burst",
                accent: .macFanCoral,
                disabled: !canControl || hasPending,
                isActive: burstActive,
                action: {
                    if burstActive { model.activate(.system) } else { model.startCoolBurst() }
                    MacFanHaptics.success()
                }
            )

            // Keep-cool is a full-width action like the other three controls.
            // The previous icon-only button made the four-item row collapse
            // into clipped glyphs at the compact sidebar width.
            let coolOn = model.keepCoolAtLaunch
            quickActionButton(
                icon: "snowflake",
                label: "Cool",
                accent: .macFanCyan,
                disabled: hasPending || (!canControl && !coolOn),
                isActive: coolOn,
                action: {
                    if coolOn { model.stopComfortCooling() } else { model.engageComfortCooling() }
                    MacFanHaptics.tick()
                }
            )
            .help(coolOn ? "Disable keep-cool" : "Keep lap cool (ramps at 80°C)")
        }
        // Four equal columns keep the row legible at the 276pt sidebar width.
        // Each action may shrink its caption slightly, but never ellipsizes it.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quickActionButton(icon: String, label: String, accent: Color, disabled: Bool, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(isActive ? accent : (disabled ? Color.macFanMuted : accent))
                Text(label)
                    .macFanCaption()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .foregroundStyle(isActive ? Color.macFanPrimary : (disabled ? Color.macFanMuted : Color.macFanSecondary))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                isActive ? accent.opacity(0.18) : Color.white.opacity(disabled ? 0.02 : 0.045),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isActive ? accent.opacity(0.35) : Color.white.opacity(0.08), lineWidth: 0.5)
            }
            .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(MacFanPressableStyle(pressedScale: 0.94))
        .macFanHoverLift()
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }

    private func uptimeText(_ interval: TimeInterval) -> String {
        let secs = max(0, Int(interval))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private func healthLabel(ready: Bool, band: ThermalBand, temp: Double?) -> String {
        if !ready { return "Read-only" }
        switch band {
        case .muted, .cool: return "Cool"
        case .indigo: return "Balanced"
        case .violet: return "Warm"
        case .amber: return "Elevated"
        case .hot: return "Hot"
        }
    }

    private var modeExplanation: String {
        switch model.activeMode {
        case .system: "macOS decides fan speeds for balance and quiet."
        case .smartBoost: "Heat-aware: boosts only while needed, then eases."
        case .max: "Full blast on every fan. Highest airflow."
        case .expert: "Per-fan or curve targets. Advanced only."
        }
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
            .padding(10)
            .background(on ? tint.opacity(0.08) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(on ? tint.opacity(0.30) : Color.white.opacity(0.06), lineWidth: on ? 1 : 0.5) }
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
                 : "Control required for Smart Boost.")
                .macFanCallout()
                .lineSpacing(2)
                .foregroundStyle(Color.macFanSecondary)
                .padding(.top, 10)
        }
        .opacity(model.capability.canControl ? 1 : 0.55)
        .padding(MacFanMetrics.cardPaddingS)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 0.5) }
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
                fanSelectionStrip
                expertControls
            }
            .padding(MacFanMetrics.cardPaddingS)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous).stroke(Color.macFanAmber.opacity(0.18), lineWidth: 0.75) }
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
            let fan = model.snapshot.fans.first(where: { $0.id == selectedFanID }) ?? model.snapshot.fans[0]
            fanControlCard(for: fan)
            Text("Apply keeps every other fan at its current safe target.")
                .macFanCaption()
                .foregroundStyle(Color.macFanMuted)
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

    private var fanSelectionStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tune one fan")
                .macFanCaption()
                .foregroundStyle(Color.macFanSecondary)
            HStack(spacing: 5) {
                ForEach(model.snapshot.fans) { fan in
                    let selected = (selectedFanID ?? model.snapshot.fans.first?.id) == fan.id
                    Button {
                        selectedFanID = fan.id
                        MacFanHaptics.tick()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "fanblades.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text(fan.name)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .macFanCaption()
                        .foregroundStyle(selected ? Color.macFanPrimary : Color.macFanSecondary)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(selected ? Color.macFanAmber.opacity(0.16) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(selected ? Color.macFanAmber.opacity(0.42) : Color.white.opacity(0.07), lineWidth: selected ? 1 : 0.5) }
                    }
                    .buttonStyle(MacFanPressableStyle(pressedScale: 0.96))
                    .accessibilityIdentifier("manual-fan-\(fan.id)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder
    private func fanControlCard(for fan: FanReading) -> some View {
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
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(isActive ? Color.white.opacity(0.07) : Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isActive ? accent.opacity(0.28) : Color.white.opacity(0.055), lineWidth: isActive ? 1 : 0.5)
            }
        }
        .buttonStyle(MacFanPressableStyle(pressedScale: 0.98))
        .macFanHoverSpecial()
        .disabled(!isEnabled)
        .opacity(isEnabled || isPending ? 1 : 0.48)
        .accessibilityHint(isEnabled ? mode.subtitle : "Click to attempt control (triggers preflight if needed). Disabled only for expert without unlock, or pending.")
        .help(isEnabled ? mode.subtitle : "Click to try full blast/control. May acquire helper. See status banner for why limited.")
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
