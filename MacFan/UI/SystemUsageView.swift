import SwiftUI

struct SystemUsagePoint: Identifiable, Equatable {
    let timestamp: Date
    let cpu: Double
    let memory: Double
    let gpu: Double?
    var id: Date { timestamp }
}

private struct SystemUsagePresentation: Equatable {
    var usage: SystemUsage?
    var history: [SystemUsagePoint]
    var cpuSpark: [Double]
    var memorySpark: [Double]
    var gpuSpark: [Double]

    static let empty = Self(usage: nil, history: [], cpuSpark: [], memorySpark: [], gpuSpark: [])
}

@MainActor
final class SystemUsageViewModel: ObservableObject {
    @Published private var presentation = SystemUsagePresentation.empty
    private let sampler = SystemUsageSampler()
    private var runGeneration: UInt = 0

    fileprivate var usage: SystemUsage? { presentation.usage }
    fileprivate var history: [SystemUsagePoint] { presentation.history }
    fileprivate var cpuSpark: [Double] { presentation.cpuSpark }
    fileprivate var memorySpark: [Double] { presentation.memorySpark }
    fileprivate var gpuSpark: [Double] { presentation.gpuSpark }

    func run() async {
        // Every visible System page owns the newest generation. A rapid
        // leave/re-enter therefore invalidates the cancelled task without
        // allowing an old `isRunning` flag to strand the new page.
        runGeneration &+= 1
        let generation = runGeneration

        // A 160 ms prime is short enough to feel immediate and avoids a false
        // first frame that says 0% CPU and 0 detected cores.
        let first = await sampler.primedSample()
        guard !Task.isCancelled, generation == runGeneration else { return }
        publish(first)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, generation == runGeneration else { return }
            let next = await sampler.sample()
            guard !Task.isCancelled, generation == runGeneration else { return }
            publish(next)
        }
    }

    private func publish(_ next: SystemUsage) {
        var history = presentation.history
        var cpuSpark = presentation.cpuSpark
        var memorySpark = presentation.memorySpark
        var gpuSpark = presentation.gpuSpark
        let point = SystemUsagePoint(timestamp: .now, cpu: next.cpuTotalPercent, memory: next.memoryPercent, gpu: next.gpuPercent)
        history.append(point)
        if history.count > 90 { history.removeFirst(history.count - 90) }
        cpuSpark.append(next.cpuTotalPercent)
        memorySpark.append(next.memoryPercent)
        if let gpu = next.gpuPercent { gpuSpark.append(gpu) }
        if cpuSpark.count > 90 { cpuSpark.removeFirst(cpuSpark.count - 90) }
        if memorySpark.count > 90 { memorySpark.removeFirst(memorySpark.count - 90) }
        if gpuSpark.count > 90 { gpuSpark.removeFirst(gpuSpark.count - 90) }
        let displayedUsage = presentation.usage.flatMap { presentationEquivalent($0, next) ? $0 : nil } ?? next
        presentation = SystemUsagePresentation(
            usage: displayedUsage,
            history: history,
            cpuSpark: cpuSpark,
            memorySpark: memorySpark,
            gpuSpark: gpuSpark
        )
    }

    private func presentationEquivalent(_ lhs: SystemUsage, _ rhs: SystemUsage) -> Bool {
        func bucket(_ value: Double, step: Double) -> Int { Int((value / step).rounded()) }
        return bucket(lhs.cpuTotalPercent, step: 0.5) == bucket(rhs.cpuTotalPercent, step: 0.5)
            && lhs.perCorePercent.map { bucket($0, step: 1) } == rhs.perCorePercent.map { bucket($0, step: 1) }
            && bucket(lhs.memoryPercent, step: 0.2) == bucket(rhs.memoryPercent, step: 0.2)
            && bucket(lhs.gpuPercent ?? -1, step: 0.5) == bucket(rhs.gpuPercent ?? -1, step: 0.5)
            && lhs.swapUsedBytes / 16_777_216 == rhs.swapUsedBytes / 16_777_216
            && lhs.thermalStateRaw == rhs.thermalStateRaw
            && Int(lhs.batteryPercent ?? -1) == Int(rhs.batteryPercent ?? -1)
            && lhs.batteryCharging == rhs.batteryCharging
            && lhs.diskUsedBytes / 268_435_456 == rhs.diskUsedBytes / 268_435_456
            && bucket(lhs.networkReceivedKBps ?? -1, step: 1) == bucket(rhs.networkReceivedKBps ?? -1, step: 1)
            && bucket(lhs.networkSentKBps ?? -1, step: 1) == bucket(rhs.networkSentKBps ?? -1, step: 1)
            && Int(lhs.uptime / 60) == Int(rhs.uptime / 60)
    }
}

private enum SystemChartMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case gpu = "GPU"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .cpu: .macFanBlue
        case .memory: .macFanCyan
        case .gpu: .macFanVioletLight
        }
    }
}

struct SystemUsageView: View {
    @ObservedObject private var viewModel: SystemUsageViewModel
    let isActive: Bool
    @State private var chartMetric: SystemChartMetric = .cpu
    @State private var showsTechnicalDetails = false

    init(viewModel: SystemUsageViewModel, isActive: Bool = true) {
        self.viewModel = viewModel
        self.isActive = isActive
    }

    private var usage: SystemUsage? { viewModel.usage }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusHeader
            primaryMetrics
            activityCard
            secondaryMetrics
            technicalDetails
            Text("Live host counters from macOS. Sampling stops when this tab closes; nothing leaves this Mac.")
                .macFanCallout()
                .foregroundStyle(Color.macFanMuted)
        }
        .task(id: isActive) {
            guard isActive else { return }
            await viewModel.run()
        }
        .onChange(of: usage?.gpuPercent) { _, next in
            if next == nil && chartMetric == .gpu { chartMetric = .cpu }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: thermalIcon)
                .macFanHeadline()
                .foregroundStyle(thermalColor)
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(usage?.thermalStateRaw == 0 ? "Your Mac is running normally" : "macOS reports thermal pressure")
                    .macFanHeadline()
                    .foregroundStyle(Color.macFanPrimary)
                Text("\(usage?.thermalStateTitle ?? "Sampling") · uptime \(Self.uptimeText(usage?.uptime ?? 0))")
                    .macFanCallout()
                    .foregroundStyle(Color.macFanSecondary)
            }
            Spacer()
            if let usage {
                Text("Load average \(String(format: "%.2f", usage.loadAverage))")
                    .macFanCallout()
                    .monospacedDigit()
                    .foregroundStyle(Color.macFanMuted)
            }
        }
        .padding(13)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.055), lineWidth: 0.5) }
    }

    private var primaryMetrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 340), spacing: 11)], spacing: 11) {
            SystemMetricCard(
                title: "Processor",
                icon: "cpu",
                value: usage.map { "\(Int($0.cpuTotalPercent.rounded()))" } ?? "—",
                unit: "%",
                detail: usage.map { "\($0.perCorePercent.count) cores · load \(String(format: "%.2f", $0.loadAverage))" } ?? "Sampling…",
                fraction: (usage?.cpuTotalPercent ?? 0) / 100,
                color: .macFanBlue,
                sparkValues: viewModel.cpuSpark,
                isSelected: chartMetric == .cpu,
                action: { selectMetric(.cpu) }
            )
            SystemMetricCard(
                title: "Memory",
                icon: "memorychip",
                value: usage.map { "\(Int($0.memoryPercent.rounded()))" } ?? "—",
                unit: "%",
                detail: usage.map { "\(Self.bytes($0.memoryUsedBytes)) of \(Self.bytes($0.memoryTotalBytes))" } ?? "Sampling…",
                fraction: (usage?.memoryPercent ?? 0) / 100,
                color: .macFanCyan,
                sparkValues: viewModel.memorySpark,
                isSelected: chartMetric == .memory,
                action: { selectMetric(.memory) }
            )
            if usage?.gpuPercent != nil {
                SystemMetricCard(
                    title: "Graphics",
                    icon: "rectangle.3.group",
                    value: usage?.gpuPercent.map { "\(Int($0.rounded()))" } ?? "—",
                    unit: "%",
                    detail: "Apple GPU utilization",
                    fraction: (usage?.gpuPercent ?? 0) / 100,
                    color: .macFanVioletLight,
                    sparkValues: viewModel.gpuSpark,
                    isSelected: chartMetric == .gpu,
                    action: { selectMetric(.gpu) }
                )
            }
            ThermalPressureCard(state: usage?.thermalStateRaw ?? 0, title: usage?.thermalStateTitle ?? "Sampling")
        }
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session activity")
                        .macFanHeadline()
                        .foregroundStyle(Color.macFanPrimary)
                    Text("\(chartMetric.rawValue) · timestamped while System is visible")
                        .macFanCallout()
                        .foregroundStyle(Color.macFanMuted)
                }
                Spacer()
                Label("Select a metric card above", systemImage: "cursorarrow.click.2")
                    .macFanCaption()
                    .foregroundStyle(Color.macFanSecondary)
            }
            SystemSessionChart(points: viewModel.history, metric: chartMetric)
                .frame(height: 150)
        }
        .macFanCard(padding: 15, radius: 14, flatten: false)
    }

    private var secondaryMetrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 390), spacing: 11)], spacing: 11) {
            SecondarySystemCard(
                title: "Network",
                icon: "network",
                primary: Self.rate((usage?.networkReceivedKBps ?? 0) + (usage?.networkSentKBps ?? 0)),
                detail: "↓ \(Self.rate(usage?.networkReceivedKBps ?? 0)) · ↑ \(Self.rate(usage?.networkSentKBps ?? 0))",
                color: .macFanBlue
            )
            SecondarySystemCard(
                title: "Battery",
                icon: "battery.75percent",
                primary: usage?.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "Unavailable",
                detail: batteryDetail,
                color: .macFanMint
            )
            SecondarySystemCard(
                title: "Storage",
                icon: "internaldrive",
                primary: usage.map { $0.diskTotalBytes > 0 ? "\(Int($0.diskPercent.rounded()))% used" : "Unavailable" } ?? "Sampling…",
                detail: usage.map { "\(Self.bytes($0.diskUsedBytes)) of \(Self.bytes($0.diskTotalBytes))" } ?? "Reading capacity…",
                color: .macFanIndigo
            )
        }
    }

    private var technicalDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { showsTechnicalDetails.toggle() }
            } label: {
                HStack {
                    Text("Technical details")
                        .macFanSubhead()
                        .foregroundStyle(Color.macFanPrimary)
                    Text("per-core load, swap and exact counters")
                        .macFanCallout()
                        .foregroundStyle(Color.macFanMuted)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .macFanChartTick()
                        .foregroundStyle(Color.macFanMuted)
                        .rotationEffect(.degrees(showsTechnicalDetails ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MacFanPressableStyle())

            if showsTechnicalDetails, let usage {
                Divider().overlay(Color.white.opacity(0.05))
                PerCoreLoadView(values: usage.perCorePercent)
                Divider().overlay(Color.white.opacity(0.05))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], alignment: .leading, spacing: 10) {
                    technicalMetric("Load average", String(format: "%.2f", usage.loadAverage))
                    technicalMetric("Swap used", Self.bytes(usage.swapUsedBytes))
                    technicalMetric("Memory used", Self.bytes(usage.memoryUsedBytes))
                    technicalMetric("Disk used", Self.bytes(usage.diskUsedBytes))
                    technicalMetric("Download", Self.rate(usage.networkReceivedKBps ?? 0))
                    technicalMetric("Upload", Self.rate(usage.networkSentKBps ?? 0))
                    technicalMetric("Uptime", Self.uptimeText(usage.uptime))
                    technicalMetric("Thermal state", usage.thermalStateTitle)
                }
                .transition(.opacity)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.055), lineWidth: 0.5) }
    }

    private func technicalMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).macFanChartTick().foregroundStyle(Color.macFanMuted)
            Text(value).macFanNumber(12).foregroundStyle(Color.macFanPrimary)
        }
    }

    private func selectMetric(_ metric: SystemChartMetric) {
        guard chartMetric != metric else { return }
        chartMetric = metric
        MacFanHaptics.tick()
    }

    private var thermalIcon: String {
        switch usage?.thermalStateRaw ?? 0 {
        case 2...: "exclamationmark.triangle.fill"
        case 1: "thermometer.medium"
        default: "checkmark.circle.fill"
        }
    }

    private var thermalColor: Color {
        switch usage?.thermalStateRaw ?? 0 {
        case 2...: .macFanCoral
        case 1: .macFanAmberLight
        default: .macFanMint
        }
    }

    private var batteryDetail: String {
        guard usage?.batteryPercent != nil else { return "No internal battery reported" }
        if usage?.batteryCharging == true { return "Charging" }
        if let minutes = usage?.batteryMinutesRemaining { return "About \(minutes / 60)h \(minutes % 60)m remaining" }
        return "On battery or fully charged"
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        return formatter
    }()

    static func bytes(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func rate(_ kilobytesPerSecond: Double) -> String {
        if kilobytesPerSecond >= 1_024 { return String(format: "%.1f MB/s", kilobytesPerSecond / 1_024) }
        return "\(Int(max(0, kilobytesPerSecond).rounded())) KB/s"
    }

    static func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }

    static func uptimeText(_ uptime: TimeInterval) -> String {
        let hours = Int(uptime) / 3_600
        return hours >= 24 ? "\(hours / 24)d \(hours % 24)h" : "\(hours)h \((Int(uptime) % 3_600) / 60)m"
    }
}

private struct SystemMetricCard: View {
    let title: String
    let icon: String
    let value: String
    let unit: String
    let detail: String
    let fraction: Double
    let color: Color
    let sparkValues: [Double]
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(title).macFanSubhead().foregroundStyle(Color.macFanSecondary)
                    Spacer()
                    if isSelected {
                        Text("CHART")
                            .macFanLabel(tracking: 0.45)
                            .foregroundStyle(color)
                    }
                    Image(systemName: icon).macFanCallout().foregroundStyle(color)
                }
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(value).macFanHeroNumeric(size: 32).foregroundStyle(Color.macFanPrimary).contentTransition(.numericText())
                    Text(unit).macFanNumber(15, weight: .medium).foregroundStyle(Color.macFanSecondary)
                }
                .padding(.top, 8)
                Text(detail).macFanCallout().foregroundStyle(Color.macFanSecondary).lineLimit(1).padding(.top, 5)
                Sparkline(values: sparkValues, color: color).frame(height: 28).padding(.top, 9)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.055))
                        if fraction > 0 {
                            Capsule().fill(color.opacity(0.85)).frame(width: proxy.size.width * min(max(fraction, 0), 1))
                        }
                    }
                }
                .frame(height: 4)
                .padding(.top, 8)
            }
            .macFanCard(padding: 14, radius: 13, flatten: false)
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(isSelected ? color.opacity(0.45) : .clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(MacFanPressableStyle())
        .accessibilityLabel("\(title), \(value)\(unit), \(detail)")
        .accessibilityHint(isSelected ? "Showing this metric in the session chart" : "Show this metric in the session chart")
    }
}

private struct ThermalPressureCard: View {
    let state: Int
    let title: String
    private var color: Color { state >= 2 ? .macFanCoral : state == 1 ? .macFanAmberLight : .macFanMint }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Thermal pressure").macFanSubhead().foregroundStyle(Color.macFanSecondary)
                Spacer()
                Image(systemName: state == 0 ? "checkmark.circle" : "thermometer.sun")
                    .macFanCallout().foregroundStyle(color)
            }
            Text(title).macFanNumber(28, weight: .semibold).foregroundStyle(color).padding(.top, 10)
            Text(state == 0 ? "No performance limiting reported" : "macOS may be limiting performance")
                .macFanCallout().foregroundStyle(Color.macFanSecondary).padding(.top, 7)
            Spacer(minLength: 15)
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule().fill(index <= state ? color : Color.white.opacity(0.055)).frame(height: 4)
                }
            }
        }
        .macFanCard(padding: 14, radius: 13, flatten: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Thermal pressure \(title)")
    }
}

private struct SecondarySystemCard: View {
    let title: String
    let icon: String
    let primary: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .macFanSubhead()
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).macFanChartTick().foregroundStyle(Color.macFanMuted)
                Text(primary).macFanNumber(15, weight: .semibold).foregroundStyle(Color.macFanPrimary)
                Text(detail).macFanCallout().foregroundStyle(Color.macFanSecondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(13)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.055), lineWidth: 0.5) }
        .accessibilityElement(children: .combine)
    }
}

private struct PerCoreLoadView: View {
    let values: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Per-core load").macFanSubhead().foregroundStyle(Color.macFanPrimary)
                Spacer()
                Text("\(values.count) detected cores").macFanChartTick().foregroundStyle(Color.macFanMuted)
            }
            HStack(alignment: .bottom, spacing: 7) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, percent in
                    VStack(spacing: 4) {
                        GeometryReader { proxy in
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.055))
                                if percent > 0 {
                                    RoundedRectangle(cornerRadius: 3).fill(Color.macFanBlue.opacity(0.9)).frame(height: proxy.size.height * min(percent / 100, 1))
                                }
                            }
                        }
                        .frame(height: 54)
                        Text("\(index)").macFanChartTick().foregroundStyle(Color.macFanMuted)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Core \(index), \(Int(percent.rounded())) percent")
                }
            }
        }
    }
}

private struct SystemChartDatum: Equatable {
    let timestamp: Date
    let value: Double
}

private struct SystemChartPresentation: Equatable {
    let values: [SystemChartDatum]
    let start: Date
    let end: Date
    let gapThreshold: TimeInterval
    let hoverTolerance: TimeInterval

    static func make(points: [SystemUsagePoint], metric: SystemChartMetric) -> Self? {
        let values = points.compactMap { point -> SystemChartDatum? in
            switch metric {
            case .cpu: SystemChartDatum(timestamp: point.timestamp, value: point.cpu)
            case .memory: SystemChartDatum(timestamp: point.timestamp, value: point.memory)
            case .gpu: point.gpu.map { SystemChartDatum(timestamp: point.timestamp, value: $0) }
            }
        }
        guard let first = values.first?.timestamp, let last = values.last?.timestamp else { return nil }
        return Self(
            values: values,
            start: first,
            end: max(last, first.addingTimeInterval(1)),
            gapThreshold: 10,
            hoverTolerance: 4.5
        )
    }
}

private struct SystemSessionChart: View {
    let points: [SystemUsagePoint]
    let metric: SystemChartMetric
    private let data: SystemChartPresentation?
    @State private var inspectedDate: Date?

    init(points: [SystemUsagePoint], metric: SystemChartMetric) {
        self.points = points
        self.metric = metric
        data = .make(points: points, metric: metric)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SystemSessionLines(data: data, color: metric.color)
                .equatable()
            if let data {
                SystemSessionCrosshair(data: data, date: inspectedDate, color: metric.color)
                GeometryReader { proxy in
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .ended:
                                inspectedDate = nil
                            case .active(let point):
                                updateInspection(x: point.x, width: proxy.size.width, data: data)
                            }
                        }
                }
                if let inspectedDate,
                   let value = nearestSystemPoint(to: inspectedDate, in: data.values, tolerance: data.hoverTolerance) {
                    Text("\(value.timestamp.formatted(date: .omitted, time: .shortened)) · \(Int(value.value.rounded()))%")
                        .macFanInspectionPill()
                        .foregroundStyle(Color.macFanPrimary)
                        .padding(7)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(MacFanMetrics.springFast, value: inspectedDate != nil)
        .focusable()
        .focusEffectDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.rawValue) session chart")
        .accessibilityValue(data?.values.last.map { "Current \(Int($0.value.rounded())) percent" } ?? "Collecting")
        .accessibilityAdjustableAction { direction in stepInspection(direction, data: data) }
        .onChange(of: metric) { _, _ in inspectedDate = nil }
    }

    private func updateInspection(x: CGFloat, width: CGFloat, data: SystemChartPresentation) {
        let plotWidth = max(width - 44, 1)
        let fraction = min(max((x - 34) / plotWidth, 0), 1)
        let proposed = data.start.addingTimeInterval(data.end.timeIntervalSince(data.start) * Double(fraction))
        let next = nearestSystemPoint(to: proposed, in: data.values, tolerance: data.hoverTolerance)?.timestamp
        if next != inspectedDate { inspectedDate = next }
    }

    private func stepInspection(_ direction: AccessibilityAdjustmentDirection, data: SystemChartPresentation?) {
        guard let data, !data.values.isEmpty else { return }
        let current = inspectedDate.flatMap { date in
            data.values.indices.min {
                abs(data.values[$0].timestamp.timeIntervalSince(date)) < abs(data.values[$1].timestamp.timeIntervalSince(date))
            }
        } ?? (direction == .increment ? -1 : data.values.count)
        let offset = direction == .increment ? 1 : -1
        inspectedDate = data.values[min(max(current + offset, 0), data.values.count - 1)].timestamp
    }
}

private struct SystemSessionLines: View, Equatable {
    let data: SystemChartPresentation?
    let color: Color

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let plot = CGRect(x: 34, y: 8, width: max(size.width - 44, 1), height: max(size.height - 28, 1))
            for value in [0, 25, 50, 75, 100] {
                let y = plot.maxY - CGFloat(value) / 100 * plot.height
                var grid = Path()
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(grid, with: .color(Color.white.opacity(value == 0 ? 0.085 : 0.04)), lineWidth: 0.5)
                if value == 0 || value == 50 || value == 100 {
                    context.draw(Text("\(value)%").font(.macFanChartTick).foregroundStyle(Color.macFanMuted), at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
                }
            }
            guard let data, data.values.count > 1 else {
                context.draw(Text("Collecting session activity…").font(.macFanChartTick).foregroundStyle(Color.macFanMuted), at: CGPoint(x: plot.midX, y: plot.midY))
                return
            }

            let span = max(data.end.timeIntervalSince(data.start), 1)
            func coordinate(_ datum: SystemChartDatum) -> CGPoint {
                CGPoint(
                    x: plot.minX + CGFloat(datum.timestamp.timeIntervalSince(data.start) / span) * plot.width,
                    y: plot.maxY - CGFloat(min(max(datum.value, 0), 100) / 100) * plot.height
                )
            }

            var segments: [[CGPoint]] = []
            var current: [CGPoint] = []
            var previousTimestamp: Date?
            for datum in data.values {
                if let previousTimestamp, datum.timestamp.timeIntervalSince(previousTimestamp) > data.gapThreshold {
                    if !current.isEmpty { segments.append(current) }
                    current = []
                }
                current.append(coordinate(datum))
                previousTimestamp = datum.timestamp
            }
            if !current.isEmpty { segments.append(current) }

            for segment in segments {
                guard let first = segment.first, let last = segment.last else { continue }
                if segment.count > 1 {
                    var area = Path()
                    area.move(to: CGPoint(x: first.x, y: plot.maxY))
                    for point in segment { area.addLine(to: point) }
                    area.addLine(to: CGPoint(x: last.x, y: plot.maxY))
                    area.closeSubpath()
                    context.fill(
                        area,
                        with: .linearGradient(
                            Gradient(colors: [color.opacity(0.13), color.opacity(0.01)]),
                            startPoint: CGPoint(x: plot.midX, y: plot.minY),
                            endPoint: CGPoint(x: plot.midX, y: plot.maxY)
                        )
                    )
                }
                var path = Path()
                path.move(to: first)
                for point in segment.dropFirst() { path.addLine(to: point) }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }

            context.draw(Text(data.start.formatted(date: .omitted, time: .shortened)).font(.macFanChartTick).foregroundStyle(Color.macFanMuted), at: CGPoint(x: plot.minX, y: plot.maxY + 16), anchor: .leading)
            context.draw(Text("Now").font(.macFanChartTick).foregroundStyle(Color.macFanMuted), at: CGPoint(x: plot.maxX, y: plot.maxY + 16), anchor: .trailing)
        }
    }
}

private struct SystemSessionCrosshair: View {
    let data: SystemChartPresentation
    let date: Date?
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard let date,
                  let datum = nearestSystemPoint(to: date, in: data.values, tolerance: data.hoverTolerance) else { return }
            let plot = CGRect(x: 34, y: 8, width: max(size.width - 44, 1), height: max(size.height - 28, 1))
            let span = max(data.end.timeIntervalSince(data.start), 1)
            let x = plot.minX + CGFloat(datum.timestamp.timeIntervalSince(data.start) / span) * plot.width
            let y = plot.maxY - CGFloat(min(max(datum.value, 0), 100) / 100) * plot.height
            var rule = Path()
            rule.move(to: CGPoint(x: x, y: plot.minY))
            rule.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(rule, with: .color(Color.macFanPrimary.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            context.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)), with: .color(color))
        }
        .allowsHitTesting(false)
    }
}

private func nearestSystemPoint(
    to date: Date,
    in points: [SystemChartDatum],
    tolerance: TimeInterval
) -> SystemChartDatum? {
    guard !points.isEmpty else { return nil }
    var lower = 0
    var upper = points.count
    while lower < upper {
        let middle = (lower + upper) / 2
        if points[middle].timestamp < date { lower = middle + 1 } else { upper = middle }
    }
    let nearest = [lower - 1, lower]
        .filter { points.indices.contains($0) }
        .min { abs(points[$0].timestamp.timeIntervalSince(date)) < abs(points[$1].timestamp.timeIntervalSince(date)) }
        .map { points[$0] }
    return nearest.flatMap { abs($0.timestamp.timeIntervalSince(date)) <= tolerance ? $0 : nil }
}
