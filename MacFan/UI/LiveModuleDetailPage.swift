import SwiftUI

/// Premium dedicated "page" experience for a live sensor/module.
/// Opened from OverviewModules grid (new page, not sidebar/inspector).
/// Features perfect UI/UX, novel Canvas charts, extra depth, micro-interactions.
/// Lightweight, Equatable where possible, reuses DesignSystem + existing patterns.
struct LiveModuleDetailPage: View, Equatable {
    let module: SensorModule
    let snapshot: ThermalSnapshot
    let history: [TelemetrySample]
    let usage: SystemUsage?
    let temperatureUnit: TemperatureUnit
    let onClose: () -> Void
    let onRevealSample: (TelemetrySample?) -> Void

    @State private var inspectedDate: Date? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // For live modules without persistent history we use short derived trails when available.
    // Processor temp benefits most from main history alignment.
    private var relevantHistory: [TelemetrySample] {
        Array(history.suffix(180))
    }

    private var currentValueText: String {
        switch module {
        case .processorLoad:
            guard let u = usage else { return "—" }
            return String(format: "%.1f", u.cpuTotalPercent)
        case .memory:
            guard let u = usage else { return "—" }
            return String(format: "%.1f", u.memoryPercent)
        case .processorTemp:
            guard let c = snapshot.displayTemperature?.celsius else { return "—" }
            return "\(Int(temperatureUnit.convert(c).rounded()))"
        case .network:
            let d = usage?.networkReceivedKBps ?? 0
            let u = usage?.networkSentKBps ?? 0
            let kbps = d + u
            return kbps >= 1024 ? String(format: "%.1f", kbps / 1024) : "\(Int(kbps.rounded()))"
        case .disk:
            guard let u = usage else { return "—" }
            return String(format: "%.1f", u.diskPercent)
        }
    }

    private var unitText: String {
        switch module {
        case .processorLoad, .memory, .disk: "%"
        case .processorTemp: "°"
        case .network: ( (usage?.networkReceivedKBps ?? 0) + (usage?.networkSentKBps ?? 0) ) >= 1024 ? " MB/s" : " kb/s"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MacFanMetrics.spacing) {
            // Premium page header — feels like entering dedicated instrument page
            detailHeader

            // Hero + context (glance that sings)
            heroStrip

            // Session + context stats (tappable for reveal)
            statsGrid

            // Main novel chart experience
            primaryChartSection

            // Module-specific extra depth
            extraContextSection

            // Action footer
            actionFooter
        }
        .padding(.vertical, 4)
        .onChange(of: module) { _, _ in inspectedDate = nil }
    }

    // MARK: - Header (page-like navigation)

    private var detailHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.86)) {
                    onClose()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("Live metrics")
                        .macFanCallout()
                }
                .foregroundStyle(Color.macFanVioletLight)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.04), in: Capsule())
            }
            .buttonStyle(.plain)
            .macFanHoverLift(scale: 1.02)

            Image(systemName: module.icon)
                .macFanHeadline()
                .foregroundStyle(Color.macFanSecondary)
                .frame(width: 28, height: 28)
                .background(Color.macFanViolet.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            Text(module.title)
                .macFanTitle2()
                .foregroundStyle(Color.macFanPrimary)

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .macFanHeadline()
                    .foregroundStyle(Color.macFanMuted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(MacFanPressableStyle())
            .help("Close detail view")
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Hero

    private var heroStrip: some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            Text(currentValueText)
                .macFanHeroNumeric(size: 48)
                .foregroundStyle(Color.macFanPrimary)
                .macFanLiveNumberTransition()

            Text(unitText)
                .macFanNumber(18, weight: .medium)
                .foregroundStyle(Color.macFanSecondary)
                .padding(.bottom, 6)

            Spacer(minLength: 12)

            // Live context badge
            VStack(alignment: .trailing, spacing: 2) {
                Text(liveContextLabel)
                    .macFanSubhead()
                    .foregroundStyle(contextTint)
                Text("live · aligned to thermal history")
                    .macFanChartTick()
                    .foregroundStyle(Color.macFanMuted)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: MacFanMetrics.radiusL, style: .continuous)
                .fill(Color.macFanSurfaceHigh.opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacFanMetrics.radiusL, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var liveContextLabel: String {
        switch module {
        case .processorLoad: usage.map { "\($0.thermalStateTitle) · \(Int($0.cpuTotalPercent))% total" } ?? "Sampling"
        case .memory: "Pressure · \(usage.map { Int($0.memoryPercent) } ?? 0)%"
        case .processorTemp: ThermalPalette.band(for: snapshot.displayTemperature?.celsius).label
        case .network: "All interfaces"
        case .disk: "Root volume"
        }
    }

    private var contextTint: Color {
        switch module {
        case .processorTemp: ThermalPalette.band(for: snapshot.displayTemperature?.celsius).color
        case .processorLoad, .memory: (usage?.thermalStateRaw ?? 0) >= 2 ? .macFanCoral : .macFanMint
        default: .macFanVioletLight
        }
    }

    // MARK: - Stats grid (depth + interaction)

    private var statsGrid: some View {
        let stats = computeSessionStats()
        return HStack(spacing: 10) {
            ForEach(stats, id: \.label) { stat in
                Button {
                    if let ts = stat.timestamp {
                        let nearest = relevantHistory.min { abs($0.timestamp.timeIntervalSince(ts)) < abs($1.timestamp.timeIntervalSince(ts)) }
                        onRevealSample(nearest)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stat.label).macFanLabel(tracking: 0.35).foregroundStyle(Color.macFanMuted)
                        Text(stat.value).macFanNumber(18, weight: .semibold).foregroundStyle(Color.macFanPrimary).macFanLiveNumberTransition()
                        if let note = stat.note {
                            Text(note).macFanChartTick().foregroundStyle(Color.macFanSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.028), in: RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: MacFanMetrics.radius).stroke(Color.white.opacity(0.05), lineWidth: 0.5))
                }
                .buttonStyle(MacFanPressableStyle(pressedScale: 0.985))
                .macFanHoverSpecial()
            }
        }
        .animation(.easeOut(duration: 0.22), value: currentValueText) // ties stats refresh to hero changes for coherence
    }

    private func computeSessionStats() -> [SessionStat] {
        var result: [SessionStat] = []
        let now = Date.now
        switch module {
        case .processorLoad:
            if let u = usage {
                result.append(SessionStat(label: "CURRENT", value: "\(String(format: "%.1f", u.cpuTotalPercent))%", note: "\(u.perCorePercent.count) cores", timestamp: now))
                // Real avg requires longer accumulation; keep honest
                result.append(SessionStat(label: "LOAD", value: "\(Int(u.cpuTotalPercent))%", note: "live total"))
            }
        case .memory:
            if let u = usage {
                result.append(SessionStat(label: "USED", value: "\(SystemUsageView.gigabytes(u.memoryUsedBytes))", note: "of \(SystemUsageView.gigabytes(u.memoryTotalBytes))", timestamp: now))
                result.append(SessionStat(label: "SWAP", value: u.swapUsedBytes > 0 ? "\(Int(u.swapUsedBytes / 1_048_576)) MB" : "0", note: nil, timestamp: now))
            }
        case .processorTemp:
            let samplesWithTemp = relevantHistory.compactMap { sample -> (Double, Date)? in
                guard let c = sample.displayTemperatureCelsius else { return nil }
                return (c, sample.timestamp)
            }
            if let (minC, minTs) = samplesWithTemp.min(by: { $0.0 < $1.0 }) {
                let minT = Int(temperatureUnit.convert(minC).rounded())
                result.append(SessionStat(label: "MIN", value: "\(minT)°", note: nil, timestamp: minTs))
            }
            let avgC = samplesWithTemp.isEmpty ? nil : samplesWithTemp.map(\.0).reduce(0, +) / Double(samplesWithTemp.count)
            if let avgC {
                let avgT = Int(temperatureUnit.convert(avgC).rounded())
                result.append(SessionStat(label: "AVG", value: "\(avgT)°", note: nil))
            }
            if let (maxC, maxTs) = samplesWithTemp.max(by: { $0.0 < $1.0 }) {
                let maxT = Int(temperatureUnit.convert(maxC).rounded())
                result.append(SessionStat(label: "MAX", value: "\(maxT)°", note: "in range", timestamp: maxTs))
            }
        case .network:
            let total = ((usage?.networkReceivedKBps ?? 0) + (usage?.networkSentKBps ?? 0))
            result.append(SessionStat(label: "CURRENT", value: "\(Int(total)) kb/s", note: "↓↑ combined", timestamp: now))
        case .disk:
            if let u = usage, u.diskTotalBytes > 0 {
                result.append(SessionStat(label: "USED", value: "\(SystemUsageView.gigabytes(u.diskUsedBytes))", note: "/ \(SystemUsageView.gigabytes(u.diskTotalBytes))", timestamp: now))
            }
        }
        if result.isEmpty {
            result.append(SessionStat(label: "STATUS", value: "Live", note: "collecting", timestamp: now))
        }
        return result
    }

    // MARK: - Primary novel chart (Canvas + grain + scrub feel)

    private var primaryChartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(primaryChartTitle)
                    .macFanHeadline()
                    .foregroundStyle(Color.macFanPrimary)
                Spacer()
                Text("scrub for concurrent context")
                    .macFanChartTick()
                    .foregroundStyle(Color.macFanMuted)
            }

            ModuleTrendCanvas(
                module: module,
                history: relevantHistory,
                usageTrail: [], // future: timestamped live trails
                temperatureUnit: temperatureUnit,
                inspectedDate: $inspectedDate
            )
            .frame(height: 168)
            .macFanCard(padding: 12, radius: MacFanMetrics.radiusL, flatten: false)

            if let inspectedDate {
                concurrentContextPill(for: inspectedDate)
            }
        }
    }

    private var primaryChartTitle: String {
        switch module {
        case .processorTemp: "Temperature trend + context"
        case .processorLoad: "Load vs thermal context"
        default: "Trend over recent window"
        }
    }

    private func concurrentContextPill(for date: Date) -> some View {
        let nearest = relevantHistory.min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
        let temp = nearest?.displayTemperatureCelsius.map { temperatureUnit.degreesWithUnit($0) } ?? "—"
        let rpm = nearest?.averageActualRPM.map { "\(Int($0.rounded())) RPM" } ?? ""
        let mode = nearest?.mode.uiTitle ?? ""

        return HStack(spacing: 8) {
            Image(systemName: "clock")
            Text(date.formatted(date: .omitted, time: .shortened))
            Text("·")
            Text("Temp \(temp)")
            if !rpm.isEmpty { Text("· \(rpm)") }
            if !mode.isEmpty { Text("· \(mode)") }
            Spacer()
        }
        .macFanChartValue()
        .foregroundStyle(Color.macFanSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.macFanStroke.opacity(0.4), lineWidth: 0.5))
    }

    // MARK: - Extra per-module depth

    private var extraContextSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Additional insight")
                .macFanSectionLabel()

            VStack(alignment: .leading, spacing: 8) {
                switch module {
                case .processorTemp:
                    Text("This sensor drives the primary thermal history and Smart Boost decisions. Peaks here directly influence fan response and thermal bands.")
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                case .processorLoad:
                    Text("High sustained load while temperature is elevated can indicate thermal throttling risk. Per-core distribution is visible in the mini bars above.")
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                    if let cores = usage?.perCorePercent, !cores.isEmpty {
                        Text("Cores: \(cores.map { String(format: "%.0f", $0) }.joined(separator: " / "))%")
                            .macFanNumber(12)
                            .foregroundStyle(Color.macFanMuted)
                    }
                case .memory:
                    let swap = usage?.swapUsedBytes ?? 0
                    Text(swap > 0 ? "Swap activity present — can correlate with sustained high temperature under memory pressure." : "No swap pressure observed in current sample.")
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                case .network:
                    Text("Network bursts rarely drive thermals directly but heavy sustained traffic can keep the machine awake and warm.")
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                case .disk:
                    Text("Disk utilization is capacity-focused. Activity (I/O) is not directly exposed here but can be inferred from other pressure signals.")
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous))
        }
    }

    private var actionFooter: some View {
        HStack {
            Button {
                let nearest = relevantHistory.last
                onRevealSample(nearest)
                onClose()
            } label: {
                HStack {
                    Text("Reveal in main chart")
                    Image(systemName: "arrow.up.right")
                }
                .macFanSubhead()
            }
            .buttonStyle(MacFanPressableStyle())
            .foregroundStyle(Color.macFanVioletLight)

            Spacer()

            Text("Data is live + history-aligned. No extrapolation across gaps.")
                .macFanChartTick()
                .foregroundStyle(Color.macFanMuted)
        }
    }

    static func == (lhs: LiveModuleDetailPage, rhs: LiveModuleDetailPage) -> Bool {
        lhs.module == rhs.module &&
        lhs.snapshot.isVisuallyEquivalent(to: rhs.snapshot) &&
        lhs.history.count == rhs.history.count &&
        lhs.usage == rhs.usage &&
        lhs.temperatureUnit == rhs.temperatureUnit
    }
}

private struct SessionStat: Equatable {
    let label: String
    let value: String
    let note: String?
    var timestamp: Date? = nil
}

// MARK: - Novel lightweight Canvas trend for detail pages (grain + context)

struct ModuleTrendCanvas: View, Equatable {
    let module: SensorModule
    let history: [TelemetrySample]
    let usageTrail: [(Date, Double)] // future: timestamped live for load/net etc.
    let temperatureUnit: TemperatureUnit
    @Binding var inspectedDate: Date?

    var body: some View {
        Canvas { context, size in
            guard size.width > 20, size.height > 20 else { return }
            let margin: CGFloat = 14
            let plot = CGRect(x: margin, y: margin + 8, width: size.width - margin * 2, height: size.height - margin * 2 - 26)

            // Light non-glow grid
            let gridColor = Color.white.opacity(0.055)
            for i in 0...4 {
                let y = plot.minY + plot.height * CGFloat(i) / 4.0
                var p = Path()
                p.move(to: CGPoint(x: plot.minX, y: y))
                p.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(p, with: .color(gridColor), style: StrokeStyle(lineWidth: 0.5))
            }

            // Always use real temperature as the time-base series for context (primary correlation for all modules)
            let tempSamples = history.compactMap { s -> (Double, Date)? in
                guard let c = s.displayTemperatureCelsius else { return nil }
                return (temperatureUnit.convert(c), s.timestamp)
            }
            let tempValues = tempSamples.map(\.0)

            // Module primary series or marker
            let (primaryValues, primaryColor, isRealSeries): ([Double], Color, Bool)
            switch module {
            case .processorTemp:
                primaryValues = tempValues
                primaryColor = .macFanPurple
                isRealSeries = true
            case .processorLoad:
                // Load has no recorded trail yet; the live hero provides its
                // value while this chart retains temperature as context.
                primaryValues = []
                primaryColor = .macFanCyan
                isRealSeries = false
            default:
                primaryValues = []
                primaryColor = .macFanVioletLight
                isRealSeries = false
            }

            guard !tempValues.isEmpty else {
                context.draw(Text("Collecting history…").font(.macFanChartTick), at: CGPoint(x: size.width/2, y: size.height/2))
                return
            }

            let allVals = tempValues + primaryValues
            let minV = (allVals.min() ?? 20) - 2
            let maxV = (allVals.max() ?? 90) + 2
            let span = max(maxV - minV, 1.0)
            let stepX = plot.width / CGFloat(max(tempValues.count - 1, 1))

            // Draw thermal base (faint ribbon for context on every module)
            var tLine = Path()
            for (i, v) in tempValues.enumerated() {
                let x = plot.minX + CGFloat(i) * stepX
                let y = plot.maxY - CGFloat((v - minV) / span) * plot.height
                if i == 0 { tLine.move(to: CGPoint(x: x, y: y)) } else { tLine.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(tLine, with: .color(Color.macFanSky.opacity(0.35)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))

            // Primary series when real (temp)
            if isRealSeries && !primaryValues.isEmpty {
                var pLine = Path()
                var pArea = Path()
                for (i, v) in primaryValues.enumerated() {
                    let x = plot.minX + CGFloat(i) * stepX
                    let y = plot.maxY - CGFloat((v - minV) / span) * plot.height
                    if i == 0 {
                        pLine.move(to: CGPoint(x: x, y: y))
                        pArea.move(to: CGPoint(x: x, y: plot.maxY))
                        pArea.addLine(to: CGPoint(x: x, y: y))
                    } else {
                        pLine.addLine(to: CGPoint(x: x, y: y))
                        pArea.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                pArea.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                pArea.closeSubpath()
                context.fill(pArea, with: .color(primaryColor.opacity(0.10)))
                context.stroke(pLine, with: .color(primaryColor), style: StrokeStyle(lineWidth: 1.9, lineCap: .round))

                // Grain dots inside primary
                context.opacity = 0.28
                for (i, v) in primaryValues.enumerated() where i % 3 == 0 {
                    let x = plot.minX + CGFloat(i) * stepX
                    let y = plot.maxY - CGFloat((v - minV) / span) * plot.height
                    context.fill(Path(ellipseIn: CGRect(x: x-0.85, y: y-0.85, width: 1.7, height: 1.7)), with: .color(.white))
                }
                context.opacity = 1.0
            }

            // Current thermal marker at the right edge.
            if let lastTemp = tempValues.last {
                let x = plot.maxX
                let y = plot.maxY - CGFloat((lastTemp - minV) / span) * plot.height
                context.fill(Path(ellipseIn: CGRect(x: x-2.5, y: y-2.5, width: 5, height: 5)), with: .color(.macFanVioletLight))
            }

            // Live marker emphasis already drawn above for temp; for other modules the hero + scrub HUD provide the value.

            // Simple y labels (left side, lightweight)
            let labelFont = Font.macFanChartTick
            let labels = [minV, (minV + maxV)/2, maxV]
            for lv in labels {
                let y = plot.maxY - CGFloat((lv - minV) / span) * plot.height
                let txt = "\(Int(lv.rounded()))"
                context.draw(Text(txt).font(labelFont).foregroundStyle(Color.macFanMuted.opacity(0.75)), at: CGPoint(x: plot.minX - 2, y: y), anchor: .trailing)
            }
        }
        .overlay(
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            let frac = max(0, min(1, (loc.x - 14) / (geo.size.width - 28)))
                            let count = max(history.count, 1)
                            let idx = Int(frac * Double(count - 1))
                            if idx >= 0 && idx < history.count { inspectedDate = history[idx].timestamp }
                        case .ended: break
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let frac = max(0, min(1, (v.location.x - 14) / (geo.size.width - 28)))
                        let count = max(history.count, 1)
                        let idx = Int(frac * Double(count - 1))
                        if idx >= 0 && idx < history.count { inspectedDate = history[idx].timestamp }
                    })
            }
        )
        .accessibilityLabel("\(module.title) trend with thermal context. Scrub to inspect.")
    }

    static func == (lhs: ModuleTrendCanvas, rhs: ModuleTrendCanvas) -> Bool {
        lhs.module == rhs.module && lhs.history.count == rhs.history.count && lhs.temperatureUnit == rhs.temperatureUnit
    }
}
