import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SensorTrailPoint: Identifiable, Equatable, Sendable {
    let timestamp: Date
    let celsius: Double
    var id: Date { timestamp }
}

struct SensorTrail: Equatable, Sendable {
    private(set) var points: [SensorTrailPoint] = []
    static let capacity = 180

    var values: [Double] { points.map(\.celsius) }
    var delta: Double? {
        guard points.count > 3, let first = points.first, let last = points.last else { return nil }
        return last.celsius - first.celsius
    }
    var duration: TimeInterval {
        guard let first = points.first, let last = points.last else { return 0 }
        return max(0, last.timestamp.timeIntervalSince(first.timestamp))
    }

    mutating func append(_ value: Double, at timestamp: Date) {
        guard value.isFinite else { return }
        if points.last?.timestamp == timestamp {
            points[points.count - 1] = SensorTrailPoint(timestamp: timestamp, celsius: value)
        } else {
            points.append(SensorTrailPoint(timestamp: timestamp, celsius: value))
        }
        if points.count > Self.capacity { points.removeFirst(points.count - Self.capacity) }
    }
}

/// Owned by AppModel so session min/avg/max and timestamped trails survive tab
/// switches and dashboard closes. Data remains in memory and resets only when
/// the MacFan process quits.
@MainActor
final class SensorSessionModel: ObservableObject {
    struct Presentation: Equatable {
        var readings: [SensorReading] = []
        var stats: [String: SensorSessionStats] = [:]
        var trails: [String: SensorTrail] = [:]
        var timestamp: Date?
    }

    @Published private(set) var presentation = Presentation()
    private var lastObservedTimestamp: Date?

    var readings: [SensorReading] { presentation.readings }
    var stats: [String: SensorSessionStats] { presentation.stats }
    var trails: [String: SensorTrail] { presentation.trails }
    var timestamp: Date? { presentation.timestamp }

    func observe(_ sensors: [SensorReading], at timestamp: Date) {
        // A SwiftUI surface reopening can present the current snapshot again.
        // Only telemetry ticks with a newer timestamp contribute to statistics.
        guard lastObservedTimestamp.map({ timestamp > $0 }) ?? true else { return }
        lastObservedTimestamp = timestamp
        var nextStats = presentation.stats
        var nextTrails = presentation.trails
        for sensor in sensors {
            if var stat = nextStats[sensor.key] {
                stat.observe(sensor.celsius)
                nextStats[sensor.key] = stat
            } else {
                nextStats[sensor.key] = SensorSessionStats(first: sensor.celsius)
            }
            var trail = nextTrails[sensor.key] ?? SensorTrail()
            trail.append(sensor.celsius, at: timestamp)
            nextTrails[sensor.key] = trail
        }
        let next = Presentation(
            readings: sensors.sorted { $0.key < $1.key },
            stats: nextStats,
            trails: nextTrails,
            timestamp: timestamp
        )
        if next != presentation { presentation = next }
    }
}

enum SensorSort: String, CaseIterable, Identifiable {
    case hottest = "Hottest first"
    case name = "Name"
    case trend = "Biggest change"
    var id: String { rawValue }
}

struct SensorsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var session: SensorSessionModel

    @State private var query = ""
    @State private var category: SensorCategory = .all
    @State private var sort: SensorSort = .hottest
    @State private var selectedKey: String?
    @State private var showsTechnicalDetails = false
    @Namespace private var categorySelection

    private var sensors: [SensorReading] { session.readings }
    private var filtered: [SensorReading] {
        var result = sensors.filter {
            category.matches($0) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.key.localizedCaseInsensitiveContains(query))
        }
        switch sort {
        case .hottest: result.sort { $0.celsius > $1.celsius }
        case .name: result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .trend: result.sort { abs(session.trails[$0.key]?.delta ?? 0) > abs(session.trails[$1.key]?.delta ?? 0) }
        }
        return result
    }
    private var selectedSensor: SensorReading? {
        if let selectedKey, let selected = filtered.first(where: { $0.key == selectedKey }) { return selected }
        return filtered.first
    }
    private var chartSensors: [SensorReading] {
        guard let primary = selectedSensor else { return [] }
        var result = [primary]
        // Comparisons are always explicit. Keep them visible even when the
        // browsing filter changes, and sort by SMC key so a sensor's visual
        // identity never depends on the current grid ordering.
        let pinned = sensors
            .filter { settings.pinnedSensorKeys.contains($0.key) && $0.key != primary.key }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        result.append(contentsOf: pinned.prefix(2))
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if sensors.isEmpty {
                emptyState
            } else {
                toolbar
                summaryStrip

                if let selectedSensor {
                    SensorFocusCard(
                        primary: selectedSensor,
                        seriesSensors: chartSensors,
                        trails: session.trails,
                        stats: session.stats[selectedSensor.key],
                        unit: settings.temperatureUnit,
                        showsTechnicalDetails: $showsTechnicalDetails,
                        onCopyReading: { copyReading(selectedSensor) }
                    )
                }

                HStack {
                    Text(filtered.count == sensors.count ? "All sensors" : "Sensors · \(filtered.count)")
                        .macFanLabel(tracking: 0.3)
                        .foregroundStyle(Color.macFanPrimary)
                    Spacer()
                    Text("Select a sensor to inspect · add up to two comparisons")
                        .macFanCallout()
                        .foregroundStyle(Color.macFanMuted)
                }

                if filtered.isEmpty {
                    Text("No sensors match your filters.")
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    sensorGrid
                }

                Text("Session statistics persist across tabs and reset when MacFan quits. CSV exports raw Celsius values.")
                    .macFanCallout()
                    .foregroundStyle(Color.macFanMuted)
            }
        }
        .onChange(of: category) { _, _ in keepSelectionVisible() }
        .onChange(of: query) { _, _ in keepSelectionVisible() }
        .onChange(of: sensors.map(\.key)) { _, _ in keepSelectionVisible() }
        .onAppear(perform: keepSelectionVisible)
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            wideToolbar
            compactToolbar
        }
    }

    private var wideToolbar: some View {
        HStack(spacing: 10) {
            sensorSearch(width: 220)
            categoryPicker(id: "wide")

            Spacer()
            sortMenu
            exportButton
        }
    }

    /// At the dashboard's supported minimum width the complete category strip
    /// belongs on its own row. Nothing truncates, and search/sort/export keep
    /// the same leading/trailing alignment as the wide toolbar.
    private var compactToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                sensorSearch(width: nil)
                    .frame(maxWidth: .infinity)
                sortMenu
                exportButton
            }
            categoryPicker(id: "compact")
        }
    }

    private func sensorSearch(width: CGFloat?) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .macFanCaption()
                .foregroundStyle(Color.macFanMuted)
            TextField("Search sensors or SMC keys", text: $query)
                .textFieldStyle(.plain)
                .macFanCallout()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.macFanMuted)
                    .accessibilityLabel("Clear sensor search")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 30)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.065), lineWidth: 0.5) }
    }

    private func categoryPicker(id: String) -> some View {
        HStack(spacing: 2) {
            ForEach(SensorCategory.allCases) { item in
                Button(item.rawValue) {
                    guard category != item else { return }
                    if reduceMotion { category = item }
                    else { withAnimation(.easeOut(duration: 0.16)) { category = item } }
                }
                .buttonStyle(MacFanPressableStyle())
                .macFanCaption()
                .foregroundStyle(category == item ? Color.macFanPrimary : Color.macFanSecondary)
                .macFanHoverSpecial(scale: 1.02)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background {
                    if category == item {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .matchedGeometryEffect(id: "sensor-category-\(id)", in: categorySelection)
                    }
                }
            }
        }
        .padding(2)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.055), lineWidth: 0.5) }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SensorSort.allCases) { option in
                Button { sort = option } label: {
                    if sort == option { Label(option.rawValue, systemImage: "checkmark") }
                    else { Text(option.rawValue) }
                }
            }
        } label: {
            Label(sort.rawValue, systemImage: "arrow.up.arrow.down")
                .macFanCaption()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(Color.macFanSecondary)
    }

    private var exportButton: some View {
        Button(action: exportCSV) {
            Image(systemName: "square.and.arrow.up")
                .macFanCallout()
                .frame(width: 28, height: 28)
        }
        .buttonStyle(MacFanPressableStyle())
        .foregroundStyle(Color.macFanSecondary)
        .help("Export sensor session as CSV")
    }

    private var summaryStrip: some View {
        let hottest = sensors.max { $0.celsius < $1.celsius }
        let cpu = sensors.filter { SensorCategory.classify($0) == .cpu }.max { $0.celsius < $1.celsius }
        let gpu = sensors.filter { SensorCategory.classify($0) == .gpu }.max { $0.celsius < $1.celsius }
        return HStack(spacing: 1) {
            SensorSummaryMetric(title: "CPU", value: cpu.map { settings.temperatureUnit.degrees($0.celsius) } ?? "—", detail: cpu?.name ?? "Unavailable")
            Divider().frame(height: 36).overlay(Color.white.opacity(0.055))
            SensorSummaryMetric(title: "GPU", value: gpu.map { settings.temperatureUnit.degrees($0.celsius) } ?? "—", detail: gpu?.name ?? "Unavailable")
            Divider().frame(height: 36).overlay(Color.white.opacity(0.055))
            SensorSummaryMetric(title: "Hottest", value: hottest.map { settings.temperatureUnit.degrees($0.celsius) } ?? "—", detail: hottest?.name ?? "Unavailable", color: hottest.map { ThermalPalette.band(for: $0.celsius).color } ?? .macFanSecondary)
            Divider().frame(height: 36).overlay(Color.white.opacity(0.055))
            SensorSummaryMetric(title: "Live sensors", value: "\(sensors.count)", detail: "Updated \(relativeFreshness)")
        }
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.055), lineWidth: 0.5) }
    }

    private var sensorGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 310), spacing: 10, alignment: .top)], spacing: 10) {
            ForEach(filtered) { sensor in
                SensorTile(
                    sensor: sensor,
                    stats: session.stats[sensor.key],
                    trail: session.trails[sensor.key] ?? SensorTrail(),
                    unit: settings.temperatureUnit,
                    isSelected: selectedSensor?.key == sensor.key,
                    isPinned: settings.pinnedSensorKeys.contains(sensor.key),
                    canPin: settings.pinnedSensorKeys.contains(sensor.key) || settings.pinnedSensorKeys.count < 2,
                    onSelect: { selectedKey = sensor.key },
                    onPin: {
                        settings.togglePinned(sensor.key)
                        MacFanHaptics.tick()
                    }
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "sensor.tag.radiowaves.forward")
                .macFanTitle2()
                .foregroundStyle(Color.macFanMuted)
            Text("Waiting for temperature sensors")
                .macFanHeadline()
                .foregroundStyle(Color.macFanPrimary)
            Text("MacFan will populate this page as soon as Apple SMC telemetry is available.")
                .macFanCallout()
                .foregroundStyle(Color.macFanSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var relativeFreshness: String {
        let seconds = max(0, Int(Date.now.timeIntervalSince(model.snapshot.timestamp)))
        return seconds < 2 ? "now" : "\(seconds)s ago"
    }

    private func keepSelectionVisible() {
        if selectedKey == nil || !filtered.contains(where: { $0.key == selectedKey }) {
            selectedKey = filtered.first?.key
        }
    }

    private func copyReading(_ sensor: SensorReading) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(sensor.name) (\(sensor.key)): \(settings.temperatureUnit.degreesWithUnit(sensor.celsius))", forType: .string)
        MacFanHaptics.success()
    }

    private func exportCSV() {
        let csv = SensorExport.csv(sensors: sensors, stats: session.stats)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "MacFan-sensors.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // A silent write leaves the user unsure it worked; give a haptic
            // and a toast receipt (and an honest one on failure).
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                MacFanHaptics.success()
                model.presentToast("Sensor CSV saved")
            } catch {
                model.presentToast("Export failed")
            }
        }
    }
}

private struct SensorSummaryMetric: View {
    let title: String
    let value: String
    let detail: String
    var color: Color = .macFanPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).macFanLabel(tracking: 0.35).foregroundStyle(Color.macFanMuted)
            Text(value).macFanNumber(18, weight: .semibold).foregroundStyle(color)
            Text(detail).macFanChartTick().foregroundStyle(Color.macFanSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
    }
}

private struct SensorTile: View {
    let sensor: SensorReading
    let stats: SensorSessionStats?
    let trail: SensorTrail
    let unit: TemperatureUnit
    let isSelected: Bool
    let isPinned: Bool
    let canPin: Bool
    let onSelect: () -> Void
    let onPin: () -> Void

    private var category: SensorCategory { SensorCategory.classify(sensor) }
    private var tint: Color { sensorCategoryColor(category) }
    private var icon: String {
        switch category {
        case .cpu: "cpu"
        case .gpu: "rectangle.3.group"
        case .battery: "battery.75percent"
        default: "sensor.tag.radiowaves.forward"
        }
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold)) // SF Symbol tuned for the compact tile.
                        .foregroundStyle(tint)
                    Text(sensor.name)
                        .macFanLabel(tracking: 0.25)
                        .foregroundStyle(Color.macFanPrimary)
                        .lineLimit(1)
                    Spacer()
                    // Reserve the comparison control's hit target without
                    // nesting a Button inside this keyboard-selectable tile.
                    Color.clear.frame(width: 24, height: 22)
                }
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("\(Int(unit.convert(sensor.celsius).rounded()))")
                        .macFanNumber(28, weight: .semibold)
                        .foregroundStyle(Color.macFanPrimary)
                        .contentTransition(.numericText())
                    Text("°").macFanNumber(15, weight: .medium).foregroundStyle(Color.macFanSecondary)
                    if let delta = trail.delta, abs(delta) >= 1 {
                        Image(systemName: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 9, weight: .semibold)) // SF Symbol tuned for the compact tile.
                            .foregroundStyle(delta > 0 ? Color.macFanAmberLight : Color.macFanSky)
                    }
                    Spacer()
                    Sparkline(values: trail.values, color: tint)
                        .frame(width: 72, height: 26)
                }
                HStack {
                    Text(sensor.key)
                        .macFanChartTick()
                        .foregroundStyle(Color.macFanMuted)
                    Spacer()
                    Text(stats.map { "peak \(unit.degrees($0.maximum))" } ?? category.rawValue)
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                }
            }
            .padding(12)
            .background(isSelected ? Color.white.opacity(0.06) : Color.white.opacity(0.026), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? tint.opacity(0.55) : Color.white.opacity(0.055), lineWidth: isSelected ? 1 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MacFanPressableStyle())
        .overlay(alignment: .topTrailing) {
            Button(action: onPin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10, weight: .semibold)) // SF Symbol tuned for the compact tile.
                    .foregroundStyle(isPinned ? Color.macFanAmberLight : canPin ? Color.macFanMuted : Color.macFanMuted.opacity(0.45))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, options: .nonRepeating, value: isPinned)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(MacFanPressableStyle(pressedScale: 0.88))
            .disabled(!canPin)
            .padding(10)
            .accessibilityLabel(isPinned ? "Remove \(sensor.name) comparison" : canPin ? "Compare \(sensor.name)" : "Comparison limit reached")
            .help(isPinned ? "Remove from comparison chart" : canPin ? "Add to comparison chart" : "Remove one of the two comparisons first")
        }
        .accessibilityLabel("\(sensor.name), \(unit.degreesWithUnit(sensor.celsius))")
        .accessibilityHint("Show this sensor in the detailed chart")
        .contextMenu {
            Button("Inspect \(sensor.name)", action: onSelect)
            Button(isPinned ? "Unpin comparison" : "Pin for comparison", action: onPin)
                .disabled(!canPin)
        }
    }
}

private struct SensorFocusCard: View {
    let primary: SensorReading
    let seriesSensors: [SensorReading]
    let trails: [String: SensorTrail]
    let stats: SensorSessionStats?
    let unit: TemperatureUnit
    @Binding var showsTechnicalDetails: Bool
    let onCopyReading: () -> Void

    private var series: [SensorChartSeries] {
        seriesSensors.compactMap { sensor in
            guard let trail = trails[sensor.key], !trail.points.isEmpty else { return nil }
            let style = sensorSeriesStyle(for: sensor.key, isPrimary: sensor.key == primary.key)
            return SensorChartSeries(
                key: sensor.key,
                name: sensor.name,
                color: style.color,
                dash: style.dash,
                isPrimary: sensor.key == primary.key,
                points: trail.points
            )
        }
    }

    private var primaryTrail: SensorTrail { trails[primary.key] ?? SensorTrail() }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(primary.name).macFanSubhead().foregroundStyle(Color.macFanPrimary) // weight from token
                    Text("Focused sensor · \(primary.key)")
                        .macFanChartTick()
                        .foregroundStyle(Color.macFanMuted)
                }
                Spacer()
                Text(unit.degreesWithUnit(primary.celsius))
                    .macFanHeroNumeric(size: 24)
                    .foregroundStyle(ThermalPalette.band(for: primary.celsius).color)
            }

            SensorComparisonChart(series: series, unit: unit, primaryKey: primary.key)
                .frame(height: 190)

            HStack(spacing: 14) {
                ForEach(series) { item in
                    HStack(spacing: 5) {
                        SensorSeriesSwatch(color: item.color, dash: item.dash)
                        Text(item.name).macFanChartTick().foregroundStyle(Color.macFanSecondary).lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { showsTechnicalDetails.toggle() }
                } label: {
                    Label(showsTechnicalDetails ? "Less detail" : "Technical details", systemImage: "info.circle")
                        .macFanCaption()
                }
                .buttonStyle(MacFanPressableStyle())
                .foregroundStyle(Color.macFanSecondary)
            }

            Divider().overlay(Color.white.opacity(0.05))
            HStack(spacing: 0) {
                detailMetric("Minimum", stats.map { unit.degreesWithUnit($0.minimum) } ?? "—")
                detailMetric("Average", stats.map { unit.degreesWithUnit($0.average) } ?? "—")
                detailMetric("Maximum", stats.map { unit.degreesWithUnit($0.maximum) } ?? "—")
                detailMetric("Change", primaryTrail.delta.map { signedDegrees($0) } ?? "—")
                detailMetric("Duration", durationText(primaryTrail.duration))
            }

            if showsTechnicalDetails {
                Divider().overlay(Color.white.opacity(0.05))
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Current").macFanChartTick().foregroundStyle(Color.macFanMuted)
                        Text(unit.degreesWithUnit(primary.celsius)).macFanNumber(12, weight: .medium).foregroundStyle(Color.macFanPrimary)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Samples").macFanChartTick().foregroundStyle(Color.macFanMuted)
                        Text(stats.map { "\($0.count)" } ?? "0").macFanNumber(12, weight: .medium).foregroundStyle(Color.macFanPrimary)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SMC key").macFanChartTick().foregroundStyle(Color.macFanMuted)
                        Text(primary.key).macFanNumber(12, weight: .medium).foregroundStyle(Color.macFanPrimary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Button(action: onCopyReading) { Label("Copy", systemImage: "doc.on.doc") }
                            .buttonStyle(MacFanPressableStyle())
                            .macFanCaption()
                            .foregroundStyle(Color.macFanBlue)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .transition(.opacity)
            }
        }
        .macFanCard(padding: 15, radius: 14, flatten: false)
    }

    private func detailMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).macFanChartTick().foregroundStyle(Color.macFanMuted)
            Text(value).macFanNumber(11.5, weight: .medium).foregroundStyle(Color.macFanPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func signedDegrees(_ celsiusDelta: Double) -> String {
        let convertedDelta = unit == .celsius ? celsiusDelta : celsiusDelta * 9 / 5
        let rounded = Int(convertedDelta.rounded())
        return "\(rounded > 0 ? "+" : "")\(rounded)°"
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

private struct SensorChartSeries: Identifiable, Equatable {
    let key: String
    let name: String
    let color: Color
    let dash: [CGFloat]
    let isPrimary: Bool
    let points: [SensorTrailPoint]
    var id: String { key }
}

private struct SensorSeriesSwatch: View {
    let color: Color
    let dash: [CGFloat]

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, dash: dash))
        }
        .frame(width: 14, height: 6)
        .accessibilityHidden(true)
    }
}

private func sensorSeriesStyle(for key: String, isPrimary: Bool) -> (color: Color, dash: [CGFloat]) {
    // FNV-1a is deterministic across launches (unlike Swift's randomized
    // Hashable seed), so a physical sensor keeps the same chart color.
    let hash = key.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    let palette: [Color] = [.macFanBlue, .macFanVioletLight, .macFanCyan, .macFanIndigo, .macFanSky]
    let color = palette[Int(hash % UInt32(palette.count))]
    guard !isPrimary else { return (color, []) }
    let dashes: [[CGFloat]] = [[6, 4], [2, 3], [9, 3, 2, 3]]
    return (color, dashes[Int((hash / UInt32(palette.count)) % UInt32(dashes.count))])
}

private struct SensorChartPresentation: Equatable {
    let series: [SensorChartSeries]
    let start: Date
    let end: Date
    let minimumCelsius: Double
    let maximumCelsius: Double
    let hoverTolerance: TimeInterval
    let gapThreshold: TimeInterval

    static func make(series: [SensorChartSeries]) -> Self? {
        let allPoints = series.flatMap(\.points)
        guard let first = allPoints.map(\.timestamp).min(), let last = allPoints.map(\.timestamp).max() else { return nil }
        let values = allPoints.map(\.celsius)
        let low = values.min() ?? 20
        let high = values.max() ?? 80
        let floor = Foundation.floor((low - 4) / 5) * 5
        let ceiling = max(floor + 15, Foundation.ceil((high + 4) / 5) * 5)
        let intervals = series.flatMap { item in
            zip(item.points, item.points.dropFirst()).compactMap { previous, next -> TimeInterval? in
                let interval = next.timestamp.timeIntervalSince(previous.timestamp)
                return interval > 0 && interval <= 20 ? interval : nil
            }
        }.sorted()
        let medianInterval = intervals.isEmpty ? 5 : intervals[intervals.count / 2]
        return Self(
            series: series,
            start: first,
            end: max(last, first.addingTimeInterval(1)),
            minimumCelsius: floor,
            maximumCelsius: ceiling,
            hoverTolerance: min(10, max(4, medianInterval * 2)),
            gapThreshold: 20
        )
    }
}

private struct SensorComparisonChart: View {
    let series: [SensorChartSeries]
    let unit: TemperatureUnit
    let primaryKey: String
    private let data: SensorChartPresentation?
    @State private var inspectedDate: Date?

    init(series: [SensorChartSeries], unit: TemperatureUnit, primaryKey: String) {
        self.series = series
        self.unit = unit
        self.primaryKey = primaryKey
        data = .make(series: series)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let data {
                SensorLinesCanvas(data: data, unit: unit).equatable()
                SensorCrosshairOverlay(data: data, date: inspectedDate, unit: unit)
                GeometryReader { proxy in
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .ended: inspectedDate = nil
                            case .active(let point): updateInspection(point.x, width: proxy.size.width, data: data)
                            }
                        }
                }
                if let inspectedDate {
                    sensorInspector(data: data, at: inspectedDate)
                        .padding(7)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            } else {
                Text("Collecting a timestamped sensor trail…")
                    .macFanCallout()
                    .foregroundStyle(Color.macFanMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(MacFanMetrics.springFast, value: inspectedDate != nil)
        .focusable()
        .focusEffectDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sensor temperature comparison")
        .accessibilityValue(accessibilitySummary)
        .accessibilityAdjustableAction { direction in stepInspection(direction: direction) }
    }

    private func sensorInspector(data: SensorChartPresentation, at date: Date) -> some View {
        HStack(spacing: 9) {
            Text(date.formatted(date: .omitted, time: .shortened))
            ForEach(data.series) { item in
                if let point = nearestPoint(to: date, in: item.points, tolerance: data.hoverTolerance) {
                    HStack(spacing: 4) {
                        SensorSeriesSwatch(color: item.color, dash: item.dash)
                        Text(unit.degrees(point.celsius))
                    }
                }
            }
        }
        .macFanInspectionPill()
        .foregroundStyle(Color.macFanPrimary)
    }

    private var accessibilitySummary: String {
        series.map { item in
            let value = item.points.last.map { unit.degreesWithUnit($0.celsius) } ?? "unavailable"
            return "\(item.name) \(value)"
        }.joined(separator: ", ")
    }

    private func updateInspection(_ x: CGFloat, width: CGFloat, data: SensorChartPresentation) {
        let plotWidth = max(width - 54, 1)
        let fraction = min(max((x - 38) / plotWidth, 0), 1)
        let proposed = data.start.addingTimeInterval(data.end.timeIntervalSince(data.start) * Double(fraction))
        let primary = data.series.first(where: { $0.key == primaryKey }) ?? data.series.first
        let next = primary.flatMap { nearestPoint(to: proposed, in: $0.points, tolerance: data.hoverTolerance)?.timestamp }
        if next != inspectedDate { inspectedDate = next }
    }

    private func stepInspection(direction: AccessibilityAdjustmentDirection) {
        guard let data, let primary = data.series.first(where: { $0.key == primaryKey }) ?? data.series.first, !primary.points.isEmpty else { return }
        let current = inspectedDate.flatMap { date in primary.points.indices.min { abs(primary.points[$0].timestamp.timeIntervalSince(date)) < abs(primary.points[$1].timestamp.timeIntervalSince(date)) } }
            ?? (direction == .increment ? -1 : primary.points.count)
        let offset = direction == .increment ? 1 : -1
        inspectedDate = primary.points[min(max(current + offset, 0), primary.points.count - 1)].timestamp
    }
}

private struct SensorLinesCanvas: View, Equatable {
    let data: SensorChartPresentation
    let unit: TemperatureUnit

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let plot = CGRect(x: 38, y: 10, width: max(size.width - 50, 1), height: max(size.height - 34, 1))
            let domain = max(data.maximumCelsius - data.minimumCelsius, 1)
            let timeSpan = max(data.end.timeIntervalSince(data.start), 1)
            func x(_ date: Date) -> CGFloat { plot.minX + CGFloat(date.timeIntervalSince(data.start) / timeSpan) * plot.width }
            func y(_ value: Double) -> CGFloat { plot.maxY - CGFloat((value - data.minimumCelsius) / domain) * plot.height }

            for index in 0...3 {
                let fraction = Double(index) / 3
                let value = data.minimumCelsius + domain * fraction
                let yy = y(value)
                var grid = Path(); grid.move(to: CGPoint(x: plot.minX, y: yy)); grid.addLine(to: CGPoint(x: plot.maxX, y: yy))
                context.stroke(grid, with: .color(Color.white.opacity(index == 0 ? 0.09 : 0.045)), lineWidth: 0.5)
                context.draw(Text(unit.degrees(value)).font(.macFanChartTick).foregroundStyle(Color.macFanMuted), at: CGPoint(x: plot.minX - 7, y: yy), anchor: .trailing)
            }

            context.draw(Text(data.start.formatted(date: .omitted, time: .shortened)).font(.macFanChartTick).foregroundStyle(Color.macFanMuted), at: CGPoint(x: plot.minX, y: plot.maxY + 17), anchor: .leading)
            context.draw(Text("Now").font(.macFanChartTick).foregroundStyle(Color.macFanMuted), at: CGPoint(x: plot.maxX, y: plot.maxY + 17), anchor: .trailing)

            for item in data.series {
                var path = Path()
                var previous: SensorTrailPoint?
                for point in item.points {
                    let coordinate = CGPoint(x: x(point.timestamp), y: y(point.celsius))
                    if let previous, point.timestamp.timeIntervalSince(previous.timestamp) <= data.gapThreshold {
                        path.addLine(to: coordinate)
                    } else {
                        path.move(to: coordinate)
                    }
                    previous = point
                }
                context.stroke(
                    path,
                    with: .color(item.color.opacity(item.isPrimary ? 0.98 : 0.82)),
                    style: StrokeStyle(
                        lineWidth: item.isPrimary ? 2 : 1.4,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: item.dash
                    )
                )
                if let last = item.points.last {
                    let p = CGPoint(x: x(last.timestamp), y: y(last.celsius))
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(item.color))
                }
            }
        }
    }
}

private struct SensorCrosshairOverlay: View {
    let data: SensorChartPresentation
    let date: Date?
    let unit: TemperatureUnit

    var body: some View {
        Canvas { context, size in
            guard let date else { return }
            let plot = CGRect(x: 38, y: 10, width: max(size.width - 50, 1), height: max(size.height - 34, 1))
            let timeSpan = max(data.end.timeIntervalSince(data.start), 1)
            let xx = plot.minX + CGFloat(date.timeIntervalSince(data.start) / timeSpan) * plot.width
            var rule = Path(); rule.move(to: CGPoint(x: xx, y: plot.minY)); rule.addLine(to: CGPoint(x: xx, y: plot.maxY))
            context.stroke(rule, with: .color(Color.macFanPrimary.opacity(0.32)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            let domain = max(data.maximumCelsius - data.minimumCelsius, 1)
            for item in data.series {
                guard let point = nearestPoint(to: date, in: item.points, tolerance: data.hoverTolerance) else { continue }
                let yy = plot.maxY - CGFloat((point.celsius - data.minimumCelsius) / domain) * plot.height
                context.fill(Path(ellipseIn: CGRect(x: xx - 3.5, y: yy - 3.5, width: 7, height: 7)), with: .color(item.color))
            }
        }
        .allowsHitTesting(false)
    }
}

private func nearestPoint(to date: Date, in points: [SensorTrailPoint], tolerance: TimeInterval? = nil) -> SensorTrailPoint? {
    guard !points.isEmpty else { return nil }
    var lower = 0
    var upper = points.count
    while lower < upper {
        let middle = (lower + upper) / 2
        if points[middle].timestamp < date { lower = middle + 1 } else { upper = middle }
    }
    let nearest = [lower - 1, lower].filter { points.indices.contains($0) }.min {
        abs(points[$0].timestamp.timeIntervalSince(date)) < abs(points[$1].timestamp.timeIntervalSince(date))
    }.map { points[$0] }
    guard let tolerance else { return nearest }
    return nearest.flatMap { abs($0.timestamp.timeIntervalSince(date)) <= tolerance ? $0 : nil }
}

private func sensorCategoryColor(_ category: SensorCategory) -> Color {
    switch category {
    case .cpu: .macFanBlue
    case .gpu: .macFanVioletLight
    case .battery: .macFanMint
    case .other, .all: .macFanCyan
    }
}
