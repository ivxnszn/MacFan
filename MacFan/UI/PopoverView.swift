import SwiftUI

/// The menu-bar surface is deliberately a quiet instrument: one thermal
/// story, immediate cooling actions, and optional engineering detail.
struct PopoverView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onShowDashboard: () -> Void
    let onShowSettings: () -> Void
    let onQuit: () -> Void

    @Namespace private var modeSelection
    @State private var showsFanDetails = false
    // Host load is sampled only while the popover is on screen — the .task
    // below is cancelled the moment it closes, so nothing polls in the menu bar.
    @State private var usage: SystemUsage?
    private let usageSampler = SystemUsageSampler()

    private var temperature: Double? { model.snapshot.displayTemperature?.celsius }
    private var band: ThermalBand { ThermalPalette.band(for: temperature) }
    private var averageFanRPM: Double? {
        guard !model.snapshot.fans.isEmpty else { return nil }
        return model.snapshot.fans.map(\.actualRPM).reduce(0, +) / Double(model.snapshot.fans.count)
    }
    private var fansAreIdle: Bool {
        !model.snapshot.fans.isEmpty && model.snapshot.fans.allSatisfy { $0.actualRPM < 1 }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.macFanCanvas
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                Divider().overlay(Color.white.opacity(0.055))

                // The primary two-fan layout fits without scrolling. When the
                // owner expands engineering details, a visible indicator makes
                // the additional scrollable content explicit.
                ScrollView(showsIndicators: showsFanDetails) {
                    VStack(spacing: 8) {
                        thermalHero
                        systemPulse
                        if !model.capability.canControl { capabilityBanner }
                        modeSelector
                        if model.capability.canControl { boostBar }
                        if settings.showPopoverFanBank { fanSummary }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }

                Divider().overlay(Color.white.opacity(0.055))
                footer
                    .padding(.horizontal, 12)
                    .frame(height: 44)
            }

            if let toast = model.toast {
                Text(toast)
                    .macFanCallout()
                    // raw weight cleaned per plan (no chaining on tokens)
                    .foregroundStyle(Color.macFanPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(Color.macFanRaised, in: Capsule())
                    .overlay { Capsule().stroke(Color.macFanStroke, lineWidth: 0.5) }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 52)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: 388, height: 520)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.17), value: model.toast)
        .task {
            // Prime with a real CPU delta (~160 ms) so the pulse settles in a
            // beat after the temp hero, reading as "vitals coming online".
            let first = await usageSampler.primedSample()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { usage = first }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                let next = await usageSampler.sample()
                if next != usage { usage = next }
            }
        }
    }

    // MARK: - System pulse (is my Mac healthy / burning power right now?)

    /// The whole card shifts mint → sky → amber → coral as the machine heats and
    /// loads up, so the glance answer to "healthy? burning power?" is the color
    /// itself. Quiet by default; color only ever means something.
    private enum PowerVerdict: Equatable {
        case cool, steady, hard, pressure

        static func evaluate(usage: SystemUsage, band: ThermalBand) -> PowerVerdict {
            if usage.thermalStateRaw >= 2 || band == .hot { return .pressure }
            let load = max(usage.cpuTotalPercent, usage.gpuPercent ?? 0)
            if load >= 65 || band == .amber { return .hard }
            if load >= 25 { return .steady }
            return .cool
        }
        var label: String {
            switch self {
            case .cool: "Running cool"
            case .steady: "Working steadily"
            case .hard: "Working hard"
            case .pressure: "Under thermal pressure"
            }
        }
        var detail: String {
            switch self {
            case .cool: "Light load, temps in check"
            case .steady: "Moderate load, good headroom"
            case .hard: "Heavy load — fans are working"
            case .pressure: "macOS is throttling to cool"
            }
        }
        var color: Color {
            switch self {
            case .cool: .macFanMint
            case .steady: .macFanSky
            case .hard: .macFanAmberLight
            case .pressure: .macFanCoral
            }
        }
        var icon: String {
            switch self {
            case .cool: "leaf.fill"
            case .steady: "waveform.path.ecg"
            case .hard: "gauge.high"
            case .pressure: "flame.fill"
            }
        }
    }

    @ViewBuilder
    private var systemPulse: some View {
        if let usage {
            let v = PowerVerdict.evaluate(usage: usage, band: band)
            HStack(spacing: 11) {
                Image(systemName: v.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(v.color)
                    .frame(width: 30, height: 30)
                    .background(v.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .symbolEffect(.bounce, options: .nonRepeating, value: v)
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.label)
                        .macFanSubhead()
                        .foregroundStyle(Color.macFanPrimary)
                    Text(v.detail)
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    loadBar("CPU", usage.cpuTotalPercent, tint: .macFanBlue)
                    if let gpu = usage.gpuPercent {
                        loadBar("GPU", gpu, tint: .macFanCyan)
                    } else {
                        loadBar("MEM", usage.memoryPercent, tint: .macFanIndigo)
                    }
                }
                .frame(width: 94)
            }
            .padding(.horizontal, 11)
            .frame(minHeight: 50)
            .background(v.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(v.color.opacity(0.18), lineWidth: 0.5) }
            .animation(reduceMotion ? nil : MacFanMetrics.springFast, value: v)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(v.label). CPU \(Int(usage.cpuTotalPercent.rounded())) percent.")
        }
    }

    private func loadBar(_ label: String, _ value: Double, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Color.macFanMuted)
                .frame(width: 22, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07)).frame(width: 36, height: 3)
                Capsule().fill(tint).frame(width: 36 * min(max(value / 100, 0), 1), height: 3)
            }
            Text("\(Int(value.rounded()))")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.macFanSecondary)
                .frame(width: 18, alignment: .trailing)
                .macFanLiveNumberTransition()
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: value)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "fanblades.fill")
                .macFanCallout()
                .foregroundStyle(.white)
                .frame(width: 27, height: 27)
                .background(Color.macFanViolet, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text("MacFan")
                    .macFanHeadline()
                    .foregroundStyle(Color.macFanPrimary)
                Text("\(model.activeMode.uiTitle) · \(model.activeMode.uiSubtitle)")
                    .macFanCallout()
                    .foregroundStyle(Color.macFanMuted)
            }
            Spacer()

            if model.capability.canControl {
                Label("Protected", systemImage: "checkmark.shield.fill")
                    .macFanLabel(tracking: 0.3)
                    .foregroundStyle(Color.macFanMint)
                    .help("Fan control active. Automatic safety restore on quit or loss of heartbeat. Tap settings for details.")
            } else {
                Button(action: onShowSettings) {
                    HStack(spacing: 4) {
                        Image(systemName: model.capability.statusIcon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(model.capability.monitorLabel)
                    }
                    .macFanLabel(tracking: 0.3)
                    .foregroundStyle(model.capability == .monitoring ? Color.macFanSecondary : Color.macFanAmberLight)
                }
                .buttonStyle(MacFanPressableStyle(thermalBand: band))
                .help("Monitor-only: \(model.capability.whyMessage). \(model.capability.whatItMeans) \(model.capability.howToFix) Open Settings to fix.")
            }
        }
    }

    private var thermalHero: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU temperature")
                    .macFanLabel(tracking: 0.4)
                    .foregroundStyle(Color.macFanSecondary)
                Spacer()
                Text(fanSummaryText)
                    .macFanCallout()
                    .monospacedDigit()
                    .foregroundStyle(Color.macFanSecondary)
                    .contentTransition(.numericText())
            }

            HStack(alignment: .lastTextBaseline, spacing: 7) {
                Text(temperature.map { "\(Int(settings.temperatureUnit.convert($0).rounded()))" } ?? "—")
                    .macFanDisplayNumber(44)
                    .foregroundStyle(Color.macFanPrimary)
                    .macFanLiveNumberTransition()
                Text(settings.temperatureUnit == .celsius ? "°C" : "°F")
                    .macFanNumber(14, weight: .medium)
                    .foregroundStyle(Color.macFanSecondary)
                Text(band.label)
                    .macFanCaption()
                    .foregroundStyle(band.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(band.color.opacity(0.10), in: Capsule())
                    .overlay { Capsule().stroke(band.color.opacity(0.18), lineWidth: 1) }
                Spacer()
                // Mode is shown in the header subtitle and the live selector
                // pill below — a third copy here was redundant, so the hero row
                // stays calm and lets the 44pt number breathe.
            }

            if settings.showPopoverTimeline {
                PopoverThermalChart(
                    samples: model.thermalTrail,
                    liveTemperature: temperature,
                    unit: settings.temperatureUnit
                )
                .frame(height: 44)
            }
        }
        .macFanCard(padding: 11, radius: 14, flatten: false)
    }

    private var capabilityBanner: some View {
        Button(action: onShowSettings) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: model.capability.statusIcon)
                        .macFanCaption()
                        .foregroundStyle(capabilityColor)
                        .frame(width: 20, height: 20)
                        .background(capabilityColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Text(capabilityTitle)
                        .macFanLabel(tracking: 0.3)
                        .foregroundStyle(Color.macFanPrimary)
                    Spacer()
                    Text(model.capability.actionLabel)
                        .macFanLabel(tracking: 0.25)
                        .foregroundStyle(Color.macFanBlue)
                    Image(systemName: "chevron.right")
                        .macFanCaption()
                        .foregroundStyle(Color.macFanMuted)
                }
                Text(model.capability.whyMessage)
                    .macFanCaption()
                    .foregroundStyle(Color.macFanSecondary)
                    .lineLimit(1)
                if !model.capability.howToFix.isEmpty {
                    Text("Fix: \(model.capability.howToFix)")
                        .macFanCaption()
                        .foregroundStyle(Color.macFanSecondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(minHeight: 58)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 0.5) }
        }
        .buttonStyle(MacFanPressableStyle())
        .help("Monitor only: \(model.capability.whyMessage). \(model.capability.whatItMeans). \(model.capability.howToFix)")
        .accessibilityLabel("Monitor only. \(model.capability.whyMessage). Fix: \(model.capability.howToFix)")
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Cooling")
                    .macFanLabel(tracking: 0.4)
                    .foregroundStyle(Color.macFanSecondary)
                Spacer()
                if let pending = model.pendingMode {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Applying \(pending.uiTitle)…")
                    }
                    .macFanLabel(tracking: 0.3)
                    .foregroundStyle(Color.macFanSecondary)
                } else if model.activeMode != .system {
                    Label("Auto on exit", systemImage: "checkmark.shield")
                        .macFanLabel(tracking: 0.2)
                        .foregroundStyle(Color.macFanMint)
                }
            }

            HStack(spacing: 3) {
                ForEach([FanMode.system, .smartBoost, .max, .expert]) { mode in
                    Button {
                        if mode != .system && !model.capability.canControl {
                            model.forceCapabilityRefresh()
                        }
                        activate(mode)
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                if isSelected(mode) {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(mode.uiAccent.opacity(0.16))
                                        .matchedGeometryEffect(id: "popover-mode-selection", in: modeSelection)
                                }
                                Image(systemName: modeIcon(mode))
                                    .macFanCaption() // weight via token; SF Symbol tuned size ok with comment if needed
                                    .foregroundStyle(isSelected(mode) ? mode.uiAccent : Color.macFanSecondary)
                                    .symbolEffect(.bounce, options: .nonRepeating, value: isSelected(mode) && !reduceMotion)
                            }
                            .frame(width: 28, height: 24)
                            .macFanEngagePulse(isActive: isSelected(mode), accent: mode.uiAccent, cornerRadius: 8, maxScale: 1.7)
                            Text(mode.uiTitle)
                                .macFanCaption()
                                // fontWeight removed; rely on macFan* token weights
                                .foregroundStyle(isSelected(mode) ? Color.macFanPrimary : Color.macFanSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MacFanPressableStyle(thermalBand: band))
                    .scaleEffect(isSelected(mode) ? 1.02 : 1.0)
                    .animation(MacFanMetrics.springFast, value: isSelected(mode))
                    .disabled(mode != .system && model.pendingMode != nil && mode != .max && mode != .smartBoost)
                    .accessibilityHint(mode == .system || model.capability.canControl || mode == .max || mode == .smartBoost ? mode.subtitle : "Click to attempt. Monitor-only: \(model.capability.whyMessage). \(model.capability.howToFix)")
                    .accessibilityIdentifier("popover-mode-\(mode.rawValue)")
                }
            }
            .padding(3)
            .background(Color.white.opacity(0.028), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 0.5) }
            // Scoped: the selection pill glides when the mode is confirmed,
            // exactly when the arrival haptic lands.
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: model.activeMode)
        }
    }

    /// One-tap thermal boost: a 10-minute Cool Burst promoted out of the
    /// overflow menu into a first-class action. While running it shows a live
    /// draining ring so the boost feels like an event you can watch, not a
    /// setting you flipped.
    @ViewBuilder
    private var boostBar: some View {
        if let until = model.coolBurstUntil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, until.timeIntervalSince(context.date))
                let fraction = model.coolBurstFractionRemaining ?? 0
                let minutes = Int(remaining) / 60
                let seconds = Int(remaining) % 60
                Button { model.activate(.system) } label: {
                    HStack(spacing: 11) {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.10), lineWidth: 3)
                            Circle()
                                .trim(from: 0, to: fraction)
                                .stroke(
                                    LinearGradient(colors: [.macFanCoral, .macFanAmberLight], startPoint: .top, endPoint: .bottom),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.macFanCoral)
                        }
                        .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Cool Burst active")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Color.macFanPrimary)
                            Text("Fans held at Max")
                                .macFanCallout()
                                .foregroundStyle(Color.macFanSecondary)
                        }
                        Spacer()
                        Text(String(format: "%d:%02d", minutes, seconds))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.macFanAmberLight)
                            .macFanLiveNumberTransition()
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.macFanSecondary)
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(0.06), in: Circle())
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 50)
                    .background(
                        LinearGradient(colors: [.macFanCoral.opacity(0.10), .macFanCoral.opacity(0.03)], startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.macFanCoral.opacity(0.28), lineWidth: 0.5) }
                }
                .buttonStyle(MacFanPressableStyle(pressedScale: 0.98))
                .help("Stop Cool Burst and return to Auto")
                .accessibilityLabel("Cool Burst active, \(minutes) minutes \(seconds) seconds remaining. Tap to stop.")
            }
            .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
        } else {
            Button { model.startCoolBurst() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.macFanCoral)
                        .frame(width: 30, height: 30)
                        .background(Color.macFanCoral.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Cool Burst")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color.macFanPrimary)
                        Text("10 minutes at Max, then back to Auto")
                            .macFanCallout()
                            .foregroundStyle(Color.macFanSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("Boost")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.macFanCoral)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background(Color.macFanCoral.opacity(0.12), in: Capsule())
                        .overlay { Capsule().stroke(Color.macFanCoral.opacity(0.26), lineWidth: 1) }
                }
                .padding(.horizontal, 11)
                .frame(minHeight: 50)
                .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 0.5) }
            }
            .buttonStyle(MacFanPressableStyle(pressedScale: 0.98))
            .disabled(model.pendingMode != nil)
            .accessibilityLabel("Start a 10-minute Cool Burst")
        }
    }

    private var fanSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if reduceMotion { showsFanDetails.toggle() }
                else { withAnimation(.easeOut(duration: 0.16)) { showsFanDetails.toggle() } }
            } label: {
                HStack {
                    Text("Fans")
                        .macFanSubhead()
                        // raw weight cleaned per plan (no chaining on tokens)
                        .foregroundStyle(Color.macFanPrimary)
                    Spacer()
                    Text(fanBankStatus)
                        .macFanLabel(tracking: 0.3)
                        .foregroundStyle(Color.macFanSecondary)
                    Image(systemName: "chevron.down")
                        .macFanCaption() // weight via token; SF Symbol tuned size ok with comment if needed
                        .foregroundStyle(Color.macFanMuted)
                        .rotationEffect(.degrees(showsFanDetails ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MacFanPressableStyle(thermalBand: band))

            if model.snapshot.fans.isEmpty {
                Text("Waiting for fan telemetry")
                    .macFanCallout()
                    .foregroundStyle(Color.macFanSecondary)
            } else {
                ForEach(model.snapshot.fans) { fan in
                    PopoverFanRow(fan: fan, showsDetails: showsFanDetails)
                    if fan.id != model.snapshot.fans.last?.id {
                        Divider().overlay(Color.white.opacity(0.05))
                    }
                }
                if fansAreIdle {
                    Text("The fans may stop while your Mac is cool.")
                        .macFanChartTick()
                        .foregroundStyle(Color.macFanMuted)
                }
            }
        }
        .macFanCard(padding: 11, radius: 13, flatten: false)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: thermalTrendIcon)
                .macFanCaption() // weight via token; SF Symbol tuned size ok with comment if needed
                .foregroundStyle(thermalTrendColor)
            Text(thermalTrendText)
                .macFanCallout()
                .foregroundStyle(Color.macFanSecondary)
                .lineLimit(1)
            Spacer()
            Button(action: onShowDashboard) {
                Label("Dashboard", systemImage: "rectangle.grid.2x2")
                    .macFanLabel(tracking: 0.3)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(MacFanPressableStyle(thermalBand: band))
            .foregroundStyle(Color.macFanPrimary)

            Button(action: onShowSettings) {
                Image(systemName: "gearshape")
                    .macFanLabel(tracking: 0.3)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(MacFanPressableStyle(thermalBand: band))
            .foregroundStyle(Color.macFanSecondary)
            .accessibilityLabel("Open MacFan settings")

            Menu {
                Toggle("Show heat curve", isOn: $settings.showPopoverTimeline)
                Toggle("Show fan details", isOn: $settings.showPopoverFanBank)
                Divider()
                Button(role: .destructive, action: onQuit) {
                    Label("Quit MacFan", systemImage: "power")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .macFanCaption() // weight via token; SF Symbol tuned size ok with comment if needed
                    .frame(width: 26, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(Color.macFanSecondary)
            .accessibilityLabel("More MacFan actions")
        }
    }

    private var fanSummaryText: String {
        guard let averageFanRPM else { return "Fans —" }
        return averageFanRPM < 1 ? "Fans idle" : "\(Int(averageFanRPM.rounded())) RPM"
    }

    private var fanBankStatus: String {
        guard !model.snapshot.fans.isEmpty else { return "Waiting" }
        let suffix = model.activeMode == .system ? "Automatic" : model.activeMode.uiTitle
        return "\(model.snapshot.fans.count) · \(suffix)"
    }


    private var trailDuration: TimeInterval {
        guard let first = model.thermalTrail.first?.timestamp else { return 0 }
        let last = model.thermalTrail.last?.timestamp ?? .now
        return min(max(last.timeIntervalSince(first), 0), 90 * 60)
    }

    private var thermalDelta: Double? {
        guard let current = temperature,
              let previous = model.thermalTrail.first?.displayTemperatureCelsius else { return nil }
        return current - previous
    }

    private var thermalTrendText: String {
        guard let delta = thermalDelta, trailDuration >= 60 else { return "Collecting trend" }
        let minutes = max(1, Int((trailDuration / 60).rounded()))
        if abs(delta) < 1.5 { return "Steady · \(minutes) min" }
        return "\(Int(abs(delta).rounded()))° \(delta > 0 ? "warmer" : "cooler") · \(minutes) min"
    }

    private var thermalTrendColor: Color {
        guard let delta = thermalDelta else { return .macFanMuted }
        return delta >= 3 ? .macFanAmberLight : delta <= -3 ? .macFanSky : .macFanSecondary
    }

    private var thermalTrendIcon: String {
        guard let delta = thermalDelta else { return "ellipsis" }
        return delta >= 1.5 ? "arrow.up.right" : delta <= -1.5 ? "arrow.down.right" : "equal"
    }

    private var capabilityTitle: String {
        let c = model.capability
        if c == .monitoring { return "Checking fan control…" }
        return "\(c.title) — \(c.shortReason)"
    }

    private var capabilityColor: Color {
        model.capability == .monitoring ? .macFanSecondary : .macFanAmberLight
    }

    private func modeIcon(_ mode: FanMode) -> String {
        guard mode != .system, !model.capability.canControl else { return mode.uiIcon }
        return "lock.fill"
    }

    private func isSelected(_ mode: FanMode) -> Bool {
        model.activeMode == mode && (mode == .system || model.capability.canControl)
    }

    private func activate(_ mode: FanMode) {
        if mode == .expert, !model.isExpertUnlocked { onShowDashboard() }
        else { model.activate(mode) }
    }
}

private struct PopoverFanRow: View {
    @EnvironmentObject private var model: AppModel
    let fan: FanReading
    let showsDetails: Bool

    private var isStopped: Bool { fan.actualRPM < 1 }
    private var isStarting: Bool { model.pendingMode != nil && isStopped }

    var body: some View {
        VStack(alignment: .leading, spacing: showsDetails ? 6 : 2) {
            HStack(spacing: 8) {
                SpinningFanBlades(rpm: fan.actualRPM, color: .macFanSecondary)
                    .frame(width: 20, height: 20)
                Text(fan.name)
                    .macFanLabel(tracking: 0.2)
                    .foregroundStyle(Color.macFanPrimary)
                Spacer()
                if isStarting {
                    ProgressView().controlSize(.mini)
                    Text("Starting")
                } else {
                    Text(isStopped ? (model.activeMode == .max ? "Targeting max" : "Idle") : "\(Int(fan.actualRPM.rounded())) RPM")
                        .macFanLiveNumberTransition()
                }
            }
            .macFanLabel(tracking: 0.3)
            .foregroundStyle(isStarting ? Color.macFanAmberLight : Color.macFanSecondary)

            if showsDetails {
                HStack {
                    Text("Range \(Int(fan.minimumRPM))–\(Int(fan.maximumRPM)) RPM")
                    Spacer()
                    Text(fan.firmwareTargetRPM.map { "Firmware marker \(Int($0.rounded()))" } ?? "Firmware automatic")
                }
                .macFanChartTick()
                .monospacedDigit()
                .foregroundStyle(Color.macFanMuted)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.06))
                        if fan.normalizedActual > 0 {
                            Capsule().fill(Color.macFanViolet).frame(width: proxy.size.width * fan.normalizedActual)
                        }
                        if let target = fan.normalizedFirmwareTarget {
                            Rectangle().fill(Color.macFanSecondary).frame(width: 1, height: 7)
                                .offset(x: max(0, proxy.size.width * target - 0.5))
                        }
                    }
                }
                .frame(height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(fan.name) fan")
        .accessibilityValue(isStopped ? (model.activeMode == .max ? "Idle but targeting max (full blast)" : "Idle under macOS control") : "\(Int(fan.actualRPM.rounded())) RPM")
    }
}

private struct PopoverTrailEntry: Equatable {
    let timestamp: Date
    let temperature: Double
}

private struct PopoverTrailPresentation: Equatable {
    let entries: [PopoverTrailEntry]
    let minimum: Double
    let maximum: Double
    let start: Date
    let end: Date
    let gapThreshold: TimeInterval
    let hoverTolerance: TimeInterval

    static func make(samples: [TelemetrySample], liveTemperature: Double?, capturedAt: Date) -> Self {
        var entries = samples.compactMap { sample in
            sample.displayTemperatureCelsius.map { PopoverTrailEntry(timestamp: sample.timestamp, temperature: $0) }
        }.sorted { $0.timestamp < $1.timestamp }
        // A synthetic live point is only needed before the first trail sample.
        // Capture its timestamp once at view construction so pointer movement
        // cannot mutate the chart's time domain.
        if entries.isEmpty, let liveTemperature {
            entries.append(PopoverTrailEntry(timestamp: capturedAt, temperature: liveTemperature))
        }
        let values = entries.map(\.temperature)
        let low = values.min() ?? 30
        let high = values.max() ?? 70
        let padding = max(4, (high - low) * 0.18)
        let first = entries.first?.timestamp ?? capturedAt
        let last = entries.last?.timestamp ?? first
        let gapThreshold: TimeInterval = 5 * 60
        let intervals = zip(entries, entries.dropFirst()).compactMap { previous, next -> TimeInterval? in
            let interval = next.timestamp.timeIntervalSince(previous.timestamp)
            return interval > 0 && interval <= gapThreshold ? interval : nil
        }.sorted()
        let medianInterval = intervals.isEmpty ? 5 : intervals[intervals.count / 2]
        return Self(
            entries: entries,
            minimum: max(15, low - padding),
            maximum: max(low + 10, high + padding),
            start: first,
            end: max(last, first.addingTimeInterval(1)),
            gapThreshold: gapThreshold,
            hoverTolerance: min(45, max(8, medianInterval * 2.5))
        )
    }
}

private struct PopoverThermalChart: View {
    let samples: [TelemetrySample]
    let liveTemperature: Double?
    let unit: TemperatureUnit
    private let presentation: PopoverTrailPresentation
    @State private var inspectedDate: Date?

    init(samples: [TelemetrySample], liveTemperature: Double?, unit: TemperatureUnit) {
        self.samples = samples
        self.liveTemperature = liveTemperature
        self.unit = unit
        presentation = .make(samples: samples, liveTemperature: liveTemperature, capturedAt: .now)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PopoverTrailCanvas(data: presentation)
                .equatable()
            PopoverTrailCrosshair(data: presentation, date: inspectedDate)
            GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .ended:
                            inspectedDate = nil
                        case .active(let point):
                            updateInspection(x: point.x, width: proxy.size.width)
                        }
                    }
            }
            if let inspectedDate,
               let entry = nearestPopoverEntry(to: inspectedDate, in: presentation.entries, tolerance: presentation.hoverTolerance) {
                Text("\(entry.timestamp.formatted(date: .omitted, time: .shortened)) · \(unit.degreesWithUnit(entry.temperature))")
                    .macFanInspectionPill()
                    .padding(5)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color.black.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(MacFanMetrics.springFast, value: inspectedDate != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU temperature trend")
        .accessibilityValue(presentation.entries.isEmpty ? "No samples yet" : "\(presentation.entries.count) timestamped samples")
    }

    private func updateInspection(x: CGFloat, width: CGFloat) {
        guard !presentation.entries.isEmpty else {
            inspectedDate = nil
            return
        }
        let plotWidth = max(width - 8, 1)
        let fraction = min(max((x - 4) / plotWidth, 0), 1)
        let proposed = presentation.start.addingTimeInterval(presentation.end.timeIntervalSince(presentation.start) * Double(fraction))
        let next = nearestPopoverEntry(
            to: proposed,
            in: presentation.entries,
            tolerance: presentation.hoverTolerance
        )?.timestamp
        if next != inspectedDate { inspectedDate = next }
    }
}

private struct PopoverTrailCanvas: View, Equatable {
    let data: PopoverTrailPresentation

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            guard !data.entries.isEmpty else {
                let txt = Text("Collecting history")
                    .font(.macFanChartTick) // canvas draw requires Text + .font (not View modifier chain)
                    .foregroundStyle(Color.macFanMuted)
                context.draw(txt, at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let plot = CGRect(x: 4, y: 5, width: max(size.width - 8, 1), height: max(size.height - 10, 1))
            for fraction in [0.33, 0.66] {
                let y = plot.minY + plot.height * fraction
                var line = Path(); line.move(to: CGPoint(x: plot.minX, y: y)); line.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(line, with: .color(Color.white.opacity(0.045)), lineWidth: 0.5)
            }
            let span = max(data.end.timeIntervalSince(data.start), 1)
            let domain = max(data.maximum - data.minimum, 1)
            func point(_ entry: PopoverTrailEntry) -> CGPoint {
                CGPoint(
                    x: plot.minX + CGFloat(entry.timestamp.timeIntervalSince(data.start) / span) * plot.width,
                    y: plot.maxY - CGFloat((entry.temperature - data.minimum) / domain) * plot.height
                )
            }

            var runs: [[PopoverTrailEntry]] = []
            var current: [PopoverTrailEntry] = []
            var previousTimestamp: Date?
            for entry in data.entries {
                if let previousTimestamp, entry.timestamp.timeIntervalSince(previousTimestamp) > data.gapThreshold {
                    if !current.isEmpty { runs.append(current) }
                    current = []
                }
                current.append(entry)
                previousTimestamp = entry.timestamp
            }
            if !current.isEmpty { runs.append(current) }

            for run in runs {
                if run.count > 1, let first = run.first, let last = run.last {
                    var area = Path()
                    area.move(to: CGPoint(x: point(first).x, y: plot.maxY))
                    for entry in run { area.addLine(to: point(entry)) }
                    area.addLine(to: CGPoint(x: point(last).x, y: plot.maxY))
                    area.closeSubpath()
                    context.fill(area, with: .linearGradient(
                        Gradient(colors: [Color.macFanViolet.opacity(0.11), Color.macFanViolet.opacity(0)]),
                        startPoint: CGPoint(x: plot.midX, y: plot.minY),
                        endPoint: CGPoint(x: plot.midX, y: plot.maxY)
                    ))
                }
                for pair in zip(run, run.dropFirst()) {
                    var segment = Path()
                    segment.move(to: point(pair.0))
                    segment.addLine(to: point(pair.1))
                    let color = ThermalPalette.band(for: max(pair.0.temperature, pair.1.temperature)).color
                    context.stroke(segment, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                }
            }
            if let lastEntry = data.entries.last {
                let p = point(lastEntry)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(ThermalPalette.band(for: lastEntry.temperature).color))
            }
        }
    }
}

private struct PopoverTrailCrosshair: View {
    let data: PopoverTrailPresentation
    let date: Date?

    var body: some View {
        Canvas { context, size in
            guard let date,
                  let entry = nearestPopoverEntry(to: date, in: data.entries, tolerance: data.hoverTolerance) else { return }
            let plot = CGRect(x: 4, y: 5, width: max(size.width - 8, 1), height: max(size.height - 10, 1))
            let span = max(data.end.timeIntervalSince(data.start), 1)
            let domain = max(data.maximum - data.minimum, 1)
            let x = plot.minX + CGFloat(entry.timestamp.timeIntervalSince(data.start) / span) * plot.width
            let y = plot.maxY - CGFloat((entry.temperature - data.minimum) / domain) * plot.height
            var rule = Path()
            rule.move(to: CGPoint(x: x, y: plot.minY))
            rule.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(rule, with: .color(Color.macFanPrimary.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            context.fill(
                Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)),
                with: .color(ThermalPalette.band(for: entry.temperature).color)
            )
        }
        .allowsHitTesting(false)
    }
}

private func nearestPopoverEntry(
    to date: Date,
    in entries: [PopoverTrailEntry],
    tolerance: TimeInterval
) -> PopoverTrailEntry? {
    guard !entries.isEmpty else { return nil }
    var lower = 0
    var upper = entries.count
    while lower < upper {
        let middle = (lower + upper) / 2
        if entries[middle].timestamp < date { lower = middle + 1 } else { upper = middle }
    }
    let nearest = [lower - 1, lower]
        .filter { entries.indices.contains($0) }
        .min { abs(entries[$0].timestamp.timeIntervalSince(date)) < abs(entries[$1].timestamp.timeIntervalSince(date)) }
        .map { entries[$0] }
    return nearest.flatMap { abs($0.timestamp.timeIntervalSince(date)) <= tolerance ? $0 : nil }
}
