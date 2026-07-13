import SwiftUI

/// The design's "Live sensors" modular grid: six Usage-style metric cards
/// mixing host counters with thermal data, each with a compact visualization.
/// Owns its sampler, so nothing polls while the Overview tab is hidden.
struct OverviewModules: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var usage: SystemUsage?
    /// Recent (received, sent) rates for the network mirror bars.
    @State private var networkTrail: [(down: Double, up: Double)] = []
    private let sampler = SystemUsageSampler()

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 13)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .macFanSubhead()
                    .foregroundStyle(Color.macFanSecondary)
                Text("Live sensors")
                    .macFanHeadline()
                    .foregroundStyle(Color.macFanPrimary)
                Text("6 active")
                    .macFanChartTick()
                    .foregroundStyle(Color.macFanMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.055), lineWidth: 1) }
                Spacer()
            }
            .padding(.top, 8)

            LazyVGrid(columns: columns, spacing: 13) {
                processorModule
                memoryModule
                temperatureModule
                batteryModule
                networkModule
                diskModule
            }
        }
        .task {
            _ = await sampler.sample()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                let next = await sampler.sample()
                if next != usage {
                    usage = next
                    if let down = next.networkReceivedKBps, let up = next.networkSentKBps {
                        networkTrail.append((down, up))
                        if networkTrail.count > 12 { networkTrail.removeFirst(networkTrail.count - 12) }
                    }
                }
            }
        }
    }

    // MARK: Modules

    private var processorModule: some View {
        MetricModuleCard(
            icon: "cpu",
            iconTint: .macFanSecondary,
            label: "Processor Load",
            value: usage.map { String(format: "%.1f", $0.cpuTotalPercent) } ?? "—",
            unit: "%",
            sub: usage.map { "\($0.perCorePercent.count) cores active" } ?? "Sampling…",
            badge: usage.map { $0.thermalStateRaw == 0 ? "Nominal" : $0.thermalStateTitle } ?? "…",
            badgeTone: (usage?.thermalStateRaw ?? 0) >= 2 ? .warn : .ok
        ) {
            MiniBars(values: (usage?.perCorePercent ?? []).prefix(12).map { $0 / 100 })
        }
    }

    private var memoryModule: some View {
        let swap = usage?.swapUsedBytes ?? 0
        return MetricModuleCard(
            icon: "memorychip",
            iconTint: .macFanSecondary,
            label: "Memory",
            value: usage.map { String(format: "%.1f", $0.memoryPercent) } ?? "—",
            unit: "%",
            sub: usage.map { "\(SystemUsageView.gigabytes($0.memoryUsedBytes)) / \(SystemUsageView.gigabytes($0.memoryTotalBytes)) GB" } ?? "Sampling…",
            badge: swap > 0 ? "\(Int(Double(swap) / 1_048_576)) MB swap" : "No swap",
            badgeTone: swap > 0 ? .warn : .ok
        ) {
            ArcGauge(fraction: (usage?.memoryPercent ?? 0) / 100, from: .macFanBlue, to: .macFanCyan)
        }
    }

    private var temperatureModule: some View {
        let celsius = model.snapshot.displayTemperature?.celsius
        let temps = model.history.suffix(12).compactMap(\.displayTemperatureCelsius)
        let trend: String
        if let celsius, temps.count > 3 {
            let average = temps.reduce(0, +) / Double(temps.count)
            trend = celsius - average > 1.5 ? "Trending up" : average - celsius > 1.5 ? "Trending down" : "Trending steady"
        } else {
            trend = "Waiting for sensor"
        }
        let band = ThermalPalette.band(for: celsius)
        return MetricModuleCard(
            icon: "thermometer.medium",
            iconTint: band.color,
            label: "Processor Temp",
            value: celsius.map { "\(Int(settings.temperatureUnit.convert($0).rounded()))" } ?? "—",
            unit: "°",
            sub: trend,
            badge: band.label,
            badgeTone: band == .amber || band == .hot ? .warn : .ok
        ) {
            if temps.count > 1 {
                Sparkline(values: temps, color: .macFanPurple)
                    .frame(width: 76, height: 42)
            } else {
                Color.clear.frame(width: 76, height: 42)
            }
        }
    }

    private var batteryModule: some View {
        let percent = usage?.batteryPercent
        let charging = usage?.batteryCharging == true
        let sub: String
        if percent == nil {
            sub = "No internal battery"
        } else if let minutes = usage?.batteryMinutesRemaining {
            sub = "\(charging ? "Charging" : "On battery") · \(minutes / 60)h \(minutes % 60)m"
        } else {
            sub = charging ? "Charging" : "On battery or full"
        }
        let batterySensor = model.snapshot.sensors.first { $0.name.localizedCaseInsensitiveContains("battery") }
        return MetricModuleCard(
            icon: "battery.75percent",
            iconTint: .macFanSecondary,
            label: "Battery",
            value: percent.map { "\(Int($0.rounded()))" } ?? "—",
            unit: percent != nil ? "%" : "",
            sub: sub,
            badge: batterySensor.map { settings.temperatureUnit.degreesWithUnit($0.celsius) } ?? (percent != nil ? "Internal battery" : "Desktop Mac"),
            badgeTone: .purple
        ) {
            SegmentedDial(fraction: (percent ?? 0) / 100, tint: .macFanVioletLight)
        }
    }

    private var networkModule: some View {
        let down = usage?.networkReceivedKBps
        let up = usage?.networkSentKBps
        let total = (down ?? 0) + (up ?? 0)
        return MetricModuleCard(
            icon: "network",
            iconTint: .macFanSecondary,
            label: "Network Activity",
            value: down == nil ? "—" : formatRate(total),
            unit: down == nil ? "" : " kb/s",
            sub: down == nil ? "measuring…" : "↓ \(formatRate(down ?? 0)) · ↑ \(formatRate(up ?? 0)) kb/s",
            badge: "All interfaces",
            badgeTone: .neutral
        ) {
            MirrorBars(pairs: networkTrail)
        }
    }

    private var diskModule: some View {
        let total = usage?.diskTotalBytes ?? 0
        return MetricModuleCard(
            icon: "internaldrive",
            iconTint: .macFanSecondary,
            label: "Disk",
            value: usage.map { total > 0 ? String(format: "%.1f", $0.diskPercent) : "—" } ?? "—",
            unit: total > 0 ? "%" : "",
            sub: usage.flatMap { total > 0 ? "\(SystemUsageView.gigabytes($0.diskUsedBytes)) / \(SystemUsageView.gigabytes(total)) GB" : nil } ?? "capacity unavailable",
            badge: FileManager.default.displayName(atPath: "/"),
            badgeTone: .neutral
        ) {
            ArcGauge(fraction: (usage?.diskPercent ?? 0) / 100, from: .macFanViolet, to: .macFanVioletLight)
        }
    }

    private func formatRate(_ kbps: Double) -> String {
        kbps >= 1_024 ? String(format: "%.1f M", kbps / 1_024) : "\(Int(kbps.rounded()))"
    }
}

// MARK: - Module card shell

enum ModuleBadgeTone {
    case ok, warn, purple, neutral

    var color: Color {
        switch self {
        case .ok: .macFanMint
        case .warn: .macFanAmberLight
        case .purple: .macFanVioletLight
        case .neutral: .macFanSecondary
        }
    }
}

struct MetricModuleCard<Viz: View>: View {
    let icon: String
    let iconTint: Color
    let label: String
    let value: String
    let unit: String
    let sub: String
    let badge: String
    let badgeTone: ModuleBadgeTone
    @ViewBuilder let visualization: () -> Viz

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .macFanCallout()
                    .foregroundStyle(iconTint)
                Text(label)
                    .macFanLabel(tracking: 0.4)
                    .foregroundStyle(Color.macFanSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .lastTextBaseline, spacing: 1) {
                        Text(value)
                            .macFanNumber(27, weight: .semibold)
                            .foregroundStyle(Color.macFanPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .contentTransition(.numericText())
                        Text(unit)
                            .macFanNumber(14, weight: .medium)
                            .foregroundStyle(Color.macFanSecondary)
                    }
                    Text(sub)
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                        .lineLimit(1)
                        .padding(.top, 7)
                    Text(badge)
                        .macFanChartValue()
                        .monospacedDigit()
                        .foregroundStyle(badgeTone.color)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(badgeTone.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(badgeTone.color.opacity(0.18), lineWidth: 1) }
                        .padding(.top, 11)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                visualization()
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
        .padding(EdgeInsets(top: 15, leading: 16, bottom: 15, trailing: 16))
        .background(Color.white.opacity(0.032), in: RoundedRectangle(cornerRadius: MacFanMetrics.radiusL, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: MacFanMetrics.radiusL, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue("\(value)\(unit), \(sub), \(badge)")
    }
}

// MARK: - Mini visualizations (pure Canvas, no chart framework)

struct MiniBars: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let gap: CGFloat = 2.4
            let barWidth = (size.width - CGFloat(values.count - 1) * gap) / CGFloat(values.count)
            for (index, raw) in values.enumerated() {
                let value = min(max(raw, 0), 1)
                let height = max(2.5, CGFloat(value) * size.height)
                let rect = CGRect(x: CGFloat(index) * (barWidth + gap), y: size.height - height, width: barWidth, height: height)
                context.opacity = 0.5 + value * 0.5
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1.5),
                    with: .linearGradient(
                        Gradient(colors: [.macFanBlue, .macFanCyan]),
                        startPoint: CGPoint(x: rect.midX, y: size.height),
                        endPoint: CGPoint(x: rect.midX, y: 0)
                    )
                )
            }
            context.opacity = 1
        }
        .frame(width: 76, height: 42)
        .accessibilityHidden(true)
    }
}

/// 280° arc gauge with a centered percentage, as in the design's memory/disk
/// modules.
struct ArcGauge: View {
    let fraction: Double
    let from: Color
    let to: Color
    var size: CGFloat = 58

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.78)
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(126))
            Circle()
                .trim(from: 0, to: 0.78 * clamped)
                .stroke(
                    LinearGradient(colors: [from, to], startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(126))
            Text("\(Int((clamped * 100).rounded()))%")
                .macFanNumber(12.5, weight: .semibold)
                .foregroundStyle(Color.macFanPrimary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Segmented tick dial (battery-health look from the design).
struct SegmentedDial: View {
    let fraction: Double
    let tint: Color
    var size: CGFloat = 58

    var body: some View {
        Canvas { context, canvasSize in
            let segments = 40
            let centerX: Double = canvasSize.width / 2
            let centerY: Double = canvasSize.height / 2
            let outer: Double = centerX - 3
            let inner: Double = centerX - 9
            let lit: Double = min(max(fraction, 0), 1) * Double(segments)
            for index in 0..<segments {
                let progress: Double = Double(index) / Double(segments)
                let angle: Double = (progress * 360 - 90) * Double.pi / 180
                let cosine: Double = cos(angle)
                let sine: Double = sin(angle)
                let startPoint = CGPoint(x: centerX + cosine * inner, y: centerY + sine * inner)
                let endPoint = CGPoint(x: centerX + cosine * outer, y: centerY + sine * outer)
                var tick = Path()
                tick.move(to: startPoint)
                tick.addLine(to: endPoint)
                let litColor: Color = tint.opacity(0.5 + 0.5 * progress)
                let color: Color = Double(index) < lit ? litColor : Color.white.opacity(0.09)
                context.stroke(tick, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .overlay {
            Text("\(Int((min(max(fraction, 0), 1) * 100).rounded()))%")
                .macFanNumber(12.5, weight: .semibold)
                .foregroundStyle(Color.macFanPrimary)
        }
        .accessibilityHidden(true)
    }
}

/// Mirrored up/down bars for network activity (download above the midline,
/// upload below).
struct MirrorBars: View {
    let pairs: [(down: Double, up: Double)]

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            var midline = Path()
            midline.move(to: CGPoint(x: 0, y: mid))
            midline.addLine(to: CGPoint(x: size.width, y: mid))
            context.stroke(midline, with: .color(Color.white.opacity(0.08)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

            guard !pairs.isEmpty else { return }
            let rates: [Double] = pairs.map { max($0.down, $0.up) }
            let peak: Double = max(rates.max() ?? 1, 1)
            let gap: CGFloat = 2.4
            let count = 12
            let barWidth: CGFloat = (size.width - CGFloat(count - 1) * gap) / CGFloat(count)
            let start = count - pairs.count
            for (offset, pair) in pairs.enumerated() {
                let x: CGFloat = CGFloat(start + offset) * (barWidth + gap)
                let downFraction: CGFloat = CGFloat(pair.down / peak)
                let upFraction: CGFloat = CGFloat(pair.up / peak)
                let downHeight: CGFloat = max(1.5, downFraction * (mid - 1))
                let upHeight: CGFloat = max(1.5, upFraction * (mid - 1))
                let downRect = CGRect(x: x, y: mid - downHeight, width: barWidth, height: downHeight)
                let upRect = CGRect(x: x, y: mid + 1, width: barWidth, height: upHeight)
                context.fill(Path(roundedRect: downRect, cornerRadius: 1), with: .color(Color.macFanCyan.opacity(0.85)))
                context.fill(Path(roundedRect: upRect, cornerRadius: 1), with: .color(Color.macFanBlue.opacity(0.6)))
            }
        }
        .frame(width: 76, height: 44)
        .accessibilityHidden(true)
    }
}
