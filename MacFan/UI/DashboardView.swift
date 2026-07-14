import AppKit
import SwiftUI

@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: AppModel
    private let settings: AppSettings
    // NSWindow always vends a default contentView, so nil-checking it cannot
    // tell us whether the SwiftUI hierarchy is attached.
    private var isContentAttached = false

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_440, height: 940),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacFan — Thermal History"
        // Preserve enough room for the denser control rail and the analytical
        // canvas. Below this width both surfaces begin competing for text and
        // chart space, which makes the app feel like a miniature utility.
        window.minSize = NSSize(width: 1_100, height: 680)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init()
        window.delegate = self
    }

    func show() {
        // Always re-attach the SwiftUI view on show() to ensure the latest code
        // and state (including new Overview features) are used. This prevents
        // stale/black content from previous launches or debug builds.
        window.contentView = NSHostingView(rootView: DashboardView().environmentObject(model).environmentObject(settings))
        isContentAttached = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.surfaceDidShow(.dashboard)
    }

    func windowWillClose(_ notification: Notification) {
        window.contentView = nil
        isContentAttached = false
        model.surfaceDidHide(.dashboard)
    }
}

enum DashboardTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case insights = "Insights"
    case sensors = "Sensors"
    case system = "System"
    case battery = "Battery"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .insights: "sparkles"
        case .sensors: "thermometer.medium"
        case .system: "cpu"
        case .battery: "battery.100"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: ""
        case .insights: "Derived from your recorded history"
        case .sensors: "Live SMC readings with session statistics"
        case .system: "Host usage · sampled only while visible"
        case .battery: "Charge level, health, power, and discharge history"
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showExpertConfirmation = false
    @State private var showClearHistoryConfirmation = false
    @State private var selectedTab: DashboardTab = .overview
    @State private var isSidebarVisible = true
    @Namespace private var pillNamespace
    @Namespace private var tabNamespace
    @State private var selectedSample: TelemetrySample? = nil
    @State private var selectedDetail: DashboardDetail? = nil
    @State private var selectedInsight: Insight? = nil
    @State private var selectedLiveModule: SensorModule? = nil
    @StateObject private var systemSession = SystemUsageViewModel()

    var body: some View {
        ZStack {
            MacFanBackdrop()
            HStack(spacing: 0) {
                if isSidebarVisible {
                    DashboardSidebar(
                        selectedTab: $selectedTab,
                        showExpertConfirmation: $showExpertConfirmation,
                        showClearHistoryConfirmation: $showClearHistoryConfirmation
                    )
                    // The sidebar carries status, quick actions, four modes,
                    // fan telemetry and manual tuning. 276pt was too narrow
                    // for that information density; 328pt keeps it compact
                    // while restoring comfortable Apple-style text measure.
                    .frame(width: 328)
                    .background(Color.macFanSurface.opacity(0.94))
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                    Divider().overlay(Color.white.opacity(0.05))
                }
                VStack(spacing: 0) {
                    header
                        .padding(.horizontal, MacFanMetrics.spacingL)
                        .frame(height: 72)
                    Divider().overlay(Color.white.opacity(0.05))
                    mainCanvas
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.macFanCanvas)  // solid to ensure content area is visible and not pure black if children are small
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        // Mode changes made from the sidebar deserve the same confirmation the
        // popover gives: a quiet capsule that floats up from the bottom.
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .macFanSubhead()
                    .foregroundStyle(Color.macFanPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay { Capsule().stroke(Color.macFanStroke, lineWidth: 1) }
                    .padding(.bottom, 18)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : MacFanMetrics.springStandard, value: model.toast)
        .onChange(of: selectedTab) { _, _ in
            selectedDetail = nil
            selectedInsight = nil
            selectedLiveModule = nil
        }
        .inspector(isPresented: Binding(
            get: { selectedDetail != nil },
            set: { if !$0 { selectedDetail = nil; selectedInsight = nil } }
        )) {
            if let detail = selectedDetail {
                DashboardInspector(
                    detail: detail,
                    insight: selectedInsight,
                    history: model.history,
                    snapshot: model.snapshot,
                    mode: model.activeMode,
                    range: model.selectedRange,
                    temperatureUnit: settings.temperatureUnit,
                    evidenceSample: selectedSample,
                    onRevealInChart: { sample in
                        selectedSample = sample
                        selectedTab = .overview
                        // The inspector otherwise remains over the chart when
                        // the user reveals evidence from an Overview card.
                        // Dismiss it so the selected point is immediately
                        // visible and the action feels complete.
                        selectedDetail = nil
                        selectedInsight = nil
                    }
                )
                .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
            }
        }
        .confirmationDialog(
            "Unlock Expert controls?",
            isPresented: $showExpertConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unlock Expert", role: .destructive) { model.unlockExpert() }
            Button("Keep protected", role: .cancel) { }
        } message: {
            Text("Expert controls can replace macOS fan behavior. MacFan still clamps every target to the fan’s discovered hardware limits and requires a maximum-RPM top point.")
        }
        .confirmationDialog(
            "Clear all local history?",
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) { model.clearHistory() }
            Button("Keep history", role: .cancel) { }
        } message: {
            Text("This permanently removes MacFan’s local SQLite samples and rollups from this Mac.")
        }
    }

    private var mainCanvas: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: MacFanMetrics.spacing) {
                activePage
                    // Explicit identity prevents SwiftUI's lazy/accessibility
                    // cache from retaining hidden tabs and invalidating them on
                    // every telemetry update. Session models live above this
                    // boundary, so useful accumulated data still survives.
                    .id(selectedTab)
            }
            .padding(.horizontal, MacFanMetrics.spacingL)
            .padding(.top, MacFanMetrics.spacing)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // .drawingGroup removed temporarily to diagnose black screen; can be re-added for perf once stable.
    }

    @ViewBuilder
    private var activePage: some View {
        switch selectedTab {
        case .overview:
            // GLANCE ZONE — always visible, read top to bottom:
            // health headline → live power → what changed → heat over time.
            // NEW: Premium context strip for "hack the data" — specs + health + sensors count at a glance.
            OverviewContextStrip(
                snapshot: model.snapshot,
                usage: systemSession.usage,
                rangeTitle: model.selectedRange.title
            )
            .equatable()
            .padding(.bottom, MacFanMetrics.spacingS)

            if selectedLiveModule == nil {
                OverviewStatRow(
                    history: model.history,
                    displayTemperature: model.snapshot.displayTemperature,
                    fans: model.snapshot.fans,
                    mode: model.activeMode,
                    rangeTitle: model.selectedRange.title,
                    temperatureUnit: settings.temperatureUnit,
                    thresholdCelsius: model.smartBoostPolicy.triggerCelsius,
                    onSelect: revealDetail
                )
                .equatable()
            }

            if settings.showDashboardLiveModules {
                if let module = selectedLiveModule {
                    // Dedicated page feel: stronger visual container + hide competing glance elements while open
                    VStack(alignment: .leading, spacing: MacFanMetrics.spacing) {
                        LiveModuleDetailPage(
                            module: module,
                            snapshot: model.snapshot,
                            history: model.history,
                            usage: systemSession.usage,
                            temperatureUnit: settings.temperatureUnit,
                            onClose: { selectedLiveModule = nil },
                            onRevealSample: { sample in
                                selectedSample = sample
                                selectedLiveModule = nil
                            }
                        )
                    }
                    .padding(12)
                    .background(Color.macFanSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: MacFanMetrics.radiusL, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: MacFanMetrics.radiusL).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    OverviewModules(onSelectModule: { module in
                        selectedLiveModule = module
                        MacFanHaptics.tick()
                    })
                }
            }

            if settings.showDashboardInlineInsights && selectedLiveModule == nil {
                InlineOverviewInsights(
                    history: model.history,
                    thresholdCelsius: model.smartBoostPolicy.triggerCelsius,
                    hardwareMaximumRPM: model.snapshot.fans.map(\.maximumRPM).max() ?? 0,
                    temperatureUnit: settings.temperatureUnit,
                    onSelect: { selectedSample = $0 }
                )
            }

            DashboardHistoryCharts(
                history: model.history,
                range: model.selectedRange,
                hardwareMaximumRPM: model.snapshot.fans.map(\.maximumRPM).max() ?? 0,
                temperatureUnit: settings.temperatureUnit,
                smartBoostThresholdCelsius: model.smartBoostPolicy.triggerCelsius,
                showsRPMChart: settings.showDashboardRPMChart,
                thermalChartStyle: settings.thermalChartStyle,
                onSelectStyle: { settings.thermalChartStyle = $0 },
                inspectedSample: $selectedSample
            )
            .equatable()

            // ANALYSIS ZONE — the deeper cut, one Menu toggle away.
            if settings.showDashboardSupportingAnalytics {
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 1)
                    .padding(.top, 12)
                Text("ANALYSIS").macFanSectionLabel()
                SupportingAnalyticsRow(history: model.history, range: model.selectedRange)
                    .equatable()
            }
        case .insights:
            InsightsView { insight, sample in
                selectedInsight = insight
                selectedDetail = .insight(insight.id)
                if let sample { selectedSample = sample }
            }
        case .sensors:
            SensorsView(session: model.sensorSession)
        case .system:
            SystemUsageView(viewModel: systemSession, isActive: model.isDashboardVisible)
        case .battery:
            BatteryInsightsTab(viewModel: systemSession)
        }
    }

    private func revealDetail(_ detail: DashboardDetail) {
        selectedInsight = nil
        selectedDetail = detail
        guard case .peak(let timestamp) = detail else { return }
        selectedSample = model.history.min {
            abs($0.timestamp.timeIntervalSince(timestamp)) < abs($1.timestamp.timeIntervalSince(timestamp))
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                if reduceMotion {
                    isSidebarVisible.toggle()
                } else {
                    withAnimation(.easeInOut(duration: MacFanMetrics.animationFast)) { isSidebarVisible.toggle() }
                }
            } label: {
                Image(systemName: "sidebar.leading")
                    .macFanHeadline()
                    .foregroundStyle(Color.macFanSecondary)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .macFanHoverLift(scale: 1.08)
            .accessibilityLabel(isSidebarVisible ? "Hide the control sidebar" : "Show the control sidebar")
            .padding(.trailing, 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(selectedTab.rawValue)
                    .macFanTitle1()
                    .foregroundStyle(Color.macFanPrimary)
                    .accessibilityIdentifier("dashboard-title")
                HStack(spacing: MacFanMetrics.spacingS) {
                    LiveDot()
                    Text(selectedTab == .overview ? model.snapshot.sourceStatus : selectedTab.subtitle)
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                }
            }
            Spacer(minLength: 12)
            // Original top tab bar (reverted to before)
            HStack(spacing: 2) {
                ForEach(DashboardTab.allCases) { tab in
                    Button {
                        guard selectedTab != tab else { return }
                        if reduceMotion {
                            selectedTab = tab
                        } else {
                            withAnimation(MacFanMetrics.springSelection) { selectedTab = tab }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11, weight: .medium))
                            Text(tab.rawValue)
                                .macFanSubhead()
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundStyle(selectedTab == tab ? Color.macFanPrimary : Color.macFanSecondary)
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background {
                            if selectedTab == tab {
                                RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous)
                                    .fill(Color.white.opacity(0.095))
                                    .matchedGeometryEffect(id: "dashboard-tab", in: tabNamespace)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MacFanPressableStyle(pressedScale: 0.97))
                    .accessibilityIdentifier("dashboard-tab-\(tab.rawValue)")
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            }
            Spacer()
            if selectedTab == .overview {
                Menu {
                    Toggle("Live sensors", isOn: $settings.showDashboardLiveModules)
                    Toggle("Inline insights", isOn: $settings.showDashboardInlineInsights)
                    Toggle("Fan response chart", isOn: $settings.showDashboardRPMChart)
                    Toggle("Supporting analytics", isOn: $settings.showDashboardSupportingAnalytics)
                    Divider()
                    Button("Reset dashboard") {
                        settings.showDashboardLiveModules = true
                        settings.showDashboardRPMChart = true
                        settings.showDashboardInlineInsights = true
                        settings.showDashboardSupportingAnalytics = true
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .macFanCallout()
                        .foregroundStyle(Color.macFanSecondary)
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Customize dashboard")
                .accessibilityLabel("Customize dashboard")

                HStack(spacing: 3) {
                    ForEach(HistoryRange.allCases) { range in
                        Button(range.title) {
                            guard model.selectedRange != range else { return }
                            // Loading a new history window replaces thousands
                            // of chart points. Keep the control's press motion,
                            // but do not animate the entire chart hierarchy.
                            model.selectedRange = range
                        }
                            .buttonStyle(MacFanPressableStyle())
                            .macFanSubhead()
                            .foregroundStyle(model.selectedRange == range ? Color.macFanPrimary : Color.macFanSecondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background {
                                if model.selectedRange == range {
                                    RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous)
                                        .fill(Color.white.opacity(0.10))
                                        .matchedGeometryEffect(id: "range-pill", in: pillNamespace)
                                }
                            }
                            .accessibilityIdentifier("history-range-\(range.rawValue)")
                    }
                }
                .padding(3)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: MacFanMetrics.radius, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1) }
                // Scoped to this segmented control only: the pill glides on a
                // spring while the chart trees still swap instantly outside
                // this animation's subtree.
                .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: model.selectedRange)
                .padding(.leading, 8)
            }
        }
    }
}

private struct DashboardInspector: View {
    let detail: DashboardDetail
    let insight: Insight?
    let history: [TelemetrySample]
    let snapshot: ThermalSnapshot
    let mode: FanMode
    let range: HistoryRange
    let temperatureUnit: TemperatureUnit
    let evidenceSample: TelemetrySample?
    let onRevealInChart: (TelemetrySample) -> Void

    private var peakSample: TelemetrySample? {
        history.max {
            ($0.displayMaximumTemperatureCelsius ?? -.infinity) < ($1.displayMaximumTemperatureCelsius ?? -.infinity)
        }
    }

    private var detailSample: TelemetrySample? {
        switch detail {
        case .peak(let timestamp):
            history.min {
                abs($0.timestamp.timeIntervalSince(timestamp)) < abs($1.timestamp.timeIntervalSince(timestamp))
            }
        case .insight:
            evidenceSample
        default:
            nil
        }
    }

    private var temperatures: [Double] { history.compactMap(\.displayTemperatureCelsius) }
    private var minimumTemperature: Double? { history.compactMap(\.displayMinimumTemperatureCelsius).min() }
    private var maximumTemperature: Double? { history.compactMap(\.displayMaximumTemperatureCelsius).max() }
    private var averageTemperature: Double? {
        let values = history.compactMap { sample -> (Double, Double)? in
            guard let value = sample.displayTemperatureCelsius else { return nil }
            return (value, max(sample.recordedCoverageSeconds ?? 1, 0.001))
        }
        let weight = values.reduce(0) { $0 + $1.1 }
        guard weight > 0 else { return nil }
        return values.reduce(0) { $0 + $1.0 * $1.1 } / weight
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                inspectorHeader
                switch detail {
                case .cpu:
                    temperatureDetail
                case .peak:
                    sampleEvidence(detailSample ?? peakSample)
                case .fans:
                    fanDetail
                case .mode:
                    modeDetail
                case .insight:
                    insightDetail
                }
            }
            .padding(18)
        }
        .background(Color.macFanCanvas)
    }

    private var inspectorHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: headerIcon)
                .macFanHeadline()
                .foregroundStyle(headerTint)
                .frame(width: 34, height: 34)
                .background(headerTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle).macFanTitle2().foregroundStyle(Color.macFanPrimary)
                Text(headerSubtitle).macFanCallout().foregroundStyle(Color.macFanSecondary)
            }
        }
    }

    @ViewBuilder private var temperatureDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSectionTitle("Recorded range", detail: range.title)
            HStack(spacing: 8) {
                InspectorMetric(label: "Minimum", value: minimumTemperature.map(temperatureUnit.degreesWithUnit) ?? "—", tint: .macFanSky)
                InspectorMetric(label: "Average", value: averageTemperature.map(temperatureUnit.degreesWithUnit) ?? "—", tint: .macFanVioletLight)
                InspectorMetric(label: "Maximum", value: maximumTemperature.map(temperatureUnit.degreesWithUnit) ?? "—", tint: maximumTemperature.map { ThermalPalette.band(for: $0).color } ?? .macFanMuted)
            }
            if temperatures.count > 1 {
                Sparkline(values: temperatures, color: ThermalPalette.band(for: temperatures.last).color, lineWidth: 1.8, minimumSpan: 5)
                    .frame(height: 62)
                    .padding(12)
                    .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text("The line uses CPU temperature. Long-range minimum and maximum preserve brief CPU excursions inside each rollup bucket.")
                .macFanCallout()
                .foregroundStyle(Color.macFanSecondary)
        }
        .macFanCard(padding: 14, radius: 14)

        if let peakSample { revealButton(sample: peakSample, title: "Reveal highest point") }
    }

    @ViewBuilder private func sampleEvidence(_ sample: TelemetrySample?) -> some View {
        if let sample {
            let temperature = sample.displayMaximumTemperatureCelsius
            VStack(alignment: .leading, spacing: 12) {
                InspectorSectionTitle("Observed evidence", detail: sample.timestamp.formatted(date: .abbreviated, time: .shortened))
                InspectorEvidenceRow(label: "CPU peak", value: temperature.map(temperatureUnit.degreesWithUnit) ?? "Unavailable", tint: temperature.map { ThermalPalette.band(for: $0).color } ?? .macFanMuted)
                InspectorEvidenceRow(label: "Average fan speed", value: sample.averageActualRPM.map { "\(Int($0.rounded())) RPM" } ?? "Unavailable", tint: .macFanVioletLight)
                InspectorEvidenceRow(label: "Cooling mode", value: sample.mode.uiTitle, tint: sample.mode.uiAccent)
                InspectorEvidenceRow(label: "Control state", value: sample.capability.title, tint: sample.capability.canControl ? .macFanMint : .macFanAmberLight)
            }
            .macFanCard(padding: 14, radius: 14)
            revealButton(sample: sample, title: "Reveal on thermal chart")
        } else {
            Text("This observation is no longer inside the selected history range.")
                .macFanCallout()
                .foregroundStyle(Color.macFanSecondary)
                .macFanCard(padding: 14, radius: 14)
        }
    }

    private var fanDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSectionTitle("Live fan bank", detail: mode.uiTitle)
            if snapshot.fans.isEmpty {
                Text("Waiting for fan telemetry").macFanCallout().foregroundStyle(Color.macFanSecondary)
            } else {
                ForEach(snapshot.fans) { fan in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(fan.name).macFanHeadline().foregroundStyle(Color.macFanPrimary)
                            Spacer()
                            Text(fan.actualRPM < 1 ? (mode == .max ? "Targeting max" : "Stopped") : "\(Int(fan.actualRPM.rounded())) RPM")
                                .macFanNumber(14, weight: .semibold)
                                .foregroundStyle(Color.macFanPrimary)
                        }
                        ProgressView(value: fan.normalizedActual)
                            .tint(Color.macFanVioletLight)
                        Text("Reported range \(Int(fan.minimumRPM))–\(Int(fan.maximumRPM)) RPM · SMC target \(fan.displayFirmwareTarget)")
                            .macFanCallout()
                            .foregroundStyle(Color.macFanSecondary)
                    }
                    if fan.id != snapshot.fans.last?.id { Divider().overlay(Color.white.opacity(0.06)) }
                }
            }
            Text("MacFan reports requested and actual RPM separately. Electrical fan wattage is not exposed reliably by Apple SMC.")
                .macFanCallout()
                .foregroundStyle(Color.macFanMuted)
        }
        .macFanCard(padding: 14, radius: 14)
    }

    private var modeDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSectionTitle("Current cooling behavior", detail: mode.uiTitle)
            InspectorEvidenceRow(label: "Mode", value: mode.uiTitle, tint: mode.uiAccent)
            InspectorEvidenceRow(label: "Behavior", value: mode.uiSubtitle, tint: Color.macFanSecondary)
            InspectorEvidenceRow(label: "Watchdog", value: mode == .system ? "macOS owns the fans" : "Restores Auto if MacFan exits", tint: .macFanMint)
            Text("The helper only accepts validated fan targets and reverts control when its heartbeat expires.")
                .macFanCallout()
                .foregroundStyle(Color.macFanSecondary)
        }
        .macFanCard(padding: 14, radius: 14)
    }

    @ViewBuilder private var insightDetail: some View {
        if let insight {
            VStack(alignment: .leading, spacing: 10) {
                InspectorSectionTitle("Why this appears", detail: "Recorded evidence")
                Text(insight.detail).macFanBody().foregroundStyle(Color.macFanPrimary)
                Text("MacFan does not extrapolate across sleep or missing telemetry. Coverage and duration summaries use only observed intervals.")
                    .macFanCallout()
                    .foregroundStyle(Color.macFanSecondary)
            }
            .macFanCard(padding: 14, radius: 14)
        }
        sampleEvidence(detailSample)
    }

    private func revealButton(sample: TelemetrySample, title: String) -> some View {
        Button { onRevealInChart(sample) } label: {
            HStack {
                Text(title).macFanHeadline()
                Spacer()
                Image(systemName: "arrow.up.right")
            }
            .foregroundStyle(Color.macFanPrimary)
            .padding(.horizontal, 13)
            .frame(height: 42)
            .background(Color.macFanViolet.opacity(0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.macFanViolet.opacity(0.32), lineWidth: 0.5) }
        }
        .buttonStyle(MacFanPressableStyle())
    }

    private var headerTitle: String {
        switch detail {
        case .cpu: "CPU temperature"
        case .peak: "Highest recorded"
        case .fans: "Cooling response"
        case .mode: "Control mode"
        case .insight: insight?.title ?? "Finding"
        }
    }

    private var headerSubtitle: String {
        switch detail {
        case .cpu: "Range statistics and preserved extrema"
        case .peak: "The sample behind the headline"
        case .fans: "Actual speed, limits, and SMC target"
        case .mode: "Behavior and fail-safe ownership"
        case .insight: "Evidence, not an estimate"
        }
    }

    private var headerIcon: String {
        switch detail {
        case .cpu: "thermometer.medium"
        case .peak: "chart.line.uptrend.xyaxis"
        case .fans: "fanblades.fill"
        case .mode: mode.uiIcon
        case .insight: insight?.icon ?? "sparkles"
        }
    }

    private var headerTint: Color {
        switch detail {
        case .cpu: return ThermalPalette.band(for: snapshot.displayTemperature?.celsius).color
        case .peak: return ThermalPalette.band(for: detailSample?.displayMaximumTemperatureCelsius).color
        case .fans: return Color.macFanVioletLight
        case .mode: return mode.uiAccent
        case .insight:
            guard let insight else { return .macFanVioletLight }
            switch insight.severity {
            case .info: return Color.macFanBlue
            case .notice: return Color.macFanAmber
            case .warning: return Color.macFanCoral
            }
        }
    }
}

private struct InspectorSectionTitle: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).macFanHeadline().foregroundStyle(Color.macFanPrimary)
                Spacer(minLength: 8)
                Text(detail).macFanCallout().foregroundStyle(Color.macFanMuted)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).macFanHeadline().foregroundStyle(Color.macFanPrimary)
                Text(detail).macFanCallout().foregroundStyle(Color.macFanMuted)
            }
        }
    }
}

private struct InspectorMetric: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).macFanSectionLabel()
            Text(value).macFanNumber(15, weight: .semibold).foregroundStyle(tint).macFanLiveNumberTransition()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeOut(duration: 0.18), value: value)
    }
}

private struct InspectorEvidenceRow: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).macFanCallout().foregroundStyle(Color.macFanSecondary)
            Spacer(minLength: 10)
            Text(value)
                .macFanNumber(13, weight: .medium)
                .lineLimit(2)
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
                .macFanLiveNumberTransition()
        }
        .animation(.easeOut(duration: 0.18), value: value)
    }
}

// MARK: - Battery
// A glance-first battery surface: one strong state signal, then progressive
// disclosure for the electrical details. Adapter wattage is never presented as
// live consumption; the live number is the cell-side estimate (I × V).
private struct BatteryInsightsTab: View {
    @ObservedObject var viewModel: SystemUsageViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsElectricalDetails = false
    @State private var showsCycleAnalysis = false

    private var usage: SystemUsage? { viewModel.usage }
    private var percent: Double { min(max(usage?.batteryPercent ?? 0, 0), 100) }
    private var displayPercent: Int { Int(percent.rounded()) }
    private var isCharging: Bool { usage?.batteryCharging == true && percent < 99.9 }
    private var accent: Color {
        if isCharging { return .macFanMint }
        if percent <= 15 { return .macFanCoral }
        if percent <= 30 { return .macFanAmberLight }
        return .macFanIndigo
    }
    private var stateTitle: String {
        if isCharging { return "Charging" }
        if percent <= 15 { return "Low battery" }
        if percent >= 99.5 { return "Fully charged" }
        return "On battery"
    }
    private var stateDetail: String {
        if let minutes = usage?.batteryMinutesRemaining, minutes > 0 {
            return isCharging ? "About \(durationText(minutes)) until full" : "About \(durationText(minutes)) remaining"
        }
        return isCharging ? "Power is flowing into the battery" : "Live battery estimate"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if usage?.batteryPercent != nil {
                    batteryHero
                    electricalDetails
                    dischargeAnalysis
                    chargingPower
                    Text("Measured locally from macOS. Battery sampling pauses when this window is hidden.")
                        .macFanCaption()
                        .foregroundStyle(Color.macFanMuted)
                        .padding(.horizontal, 2)
                } else {
                    emptyBatteryState
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .task {
            await viewModel.run()
        }
    }

    private var batteryHero: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("Battery", systemImage: "battery.100")
                    .macFanHeadline()
                    .foregroundStyle(Color.macFanPrimary)
                Text(stateTitle.uppercased())
                    .macFanCaption()
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(accent.opacity(0.12), in: Capsule())
                Spacer()
                Circle().fill(accent).frame(width: 7, height: 7)
                Text("Live").macFanCaption().foregroundStyle(Color.macFanSecondary)
            }

            HStack(alignment: .center, spacing: 22) {
                BatteryLevelGraphic(percent: percent, tint: accent)
                    .frame(width: 280, height: 132)
                    .accessibilityLabel("Battery charge \(displayPercent) percent, \(stateTitle)")

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .lastTextBaseline, spacing: 5) {
                        Text("\(displayPercent)")
                            .macFanNumber(46, weight: .semibold)
                            .foregroundStyle(Color.macFanPrimary)
                            .contentTransition(.numericText())
                        Text("%").macFanNumber(18, weight: .medium).foregroundStyle(Color.macFanSecondary)
                    }
                    Text(stateTitle).macFanTitle2().foregroundStyle(accent)
                    Text(stateDetail).macFanCallout().foregroundStyle(Color.macFanSecondary)
                    if viewModel.batterySpark.count > 1 {
                        BatteryLevelTrail(values: viewModel.batterySpark, tint: accent)
                            .frame(height: 38)
                            .frame(maxWidth: 360)
                    }
                }
                Spacer(minLength: 0)
            }

            Divider().overlay(Color.white.opacity(0.08))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    BatteryInsightMetric(title: "REMAINING", value: remainingText, detail: remainingDetail, tint: .macFanBlue)
                    BatteryInsightMetric(title: "CELL POWER", value: wattsText, detail: isCharging ? "Live estimate" : "Current draw", tint: isCharging ? .macFanMint : .macFanVioletLight)
                    BatteryInsightMetric(title: "HEALTH", value: healthText, detail: healthDetail, tint: .macFanMint)
                    BatteryInsightMetric(title: "TEMPERATURE", value: temperatureText, detail: temperatureDetail, tint: .macFanAmberLight)
                }
                VStack(alignment: .leading, spacing: 10) {
                    BatteryInsightMetric(title: "REMAINING", value: remainingText, detail: remainingDetail, tint: .macFanBlue)
                    BatteryInsightMetric(title: "CELL POWER", value: wattsText, detail: isCharging ? "Live estimate" : "Current draw", tint: isCharging ? .macFanMint : .macFanVioletLight)
                    BatteryInsightMetric(title: "HEALTH", value: healthText, detail: healthDetail, tint: .macFanMint)
                    BatteryInsightMetric(title: "TEMPERATURE", value: temperatureText, detail: temperatureDetail, tint: .macFanAmberLight)
                }
            }
        }
        .padding(18)
        .macFanCard(padding: 0, radius: 18, flatten: true)
        .overlay(alignment: .top) {
            LinearGradient(colors: [accent.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .allowsHitTesting(false)
        }
    }

    private var electricalDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showsElectricalDetails.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg").foregroundStyle(accent)
                    Text("Electrical details").macFanSubhead().foregroundStyle(Color.macFanPrimary)
                    Spacer()
                    Text(showsElectricalDetails ? "Hide" : "Current, voltage, cycles")
                        .macFanCaption().foregroundStyle(Color.macFanMuted)
                    Image(systemName: showsElectricalDetails ? "chevron.up" : "chevron.down")
                        .macFanCaption().foregroundStyle(Color.macFanMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("battery-electrical-details")
            if showsElectricalDetails {
                HStack(spacing: 0) {
                    BatteryTechnicalMetric(title: "Cell current", value: currentText)
                    BatteryTechnicalMetric(title: "Cell voltage", value: voltageText)
                    BatteryTechnicalMetric(title: "Cell power", value: wattsText)
                    BatteryTechnicalMetric(title: "Cycle count", value: usage?.batteryCycleCount.map(String.init) ?? "—")
                }
                .padding(.top, 13)
                .padding(.bottom, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("battery-electrical-content")
            }
        }
        .padding(15)
        .macFanCard(padding: 0, radius: 14, flatten: true)
    }

    private var dischargeAnalysis: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showsCycleAnalysis.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "chart.xyaxis.line").foregroundStyle(Color.macFanCyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last discharge analysis").macFanSubhead().foregroundStyle(Color.macFanPrimary)
                        Text(dischargeSummary).macFanCaption().foregroundStyle(Color.macFanSecondary)
                    }
                    Spacer()
                    Text(showsCycleAnalysis ? "Hide" : "Show history").macFanCaption().foregroundStyle(Color.macFanBlue)
                    Image(systemName: showsCycleAnalysis ? "chevron.up" : "chevron.down").macFanCaption().foregroundStyle(Color.macFanMuted)
                }
                if showsCycleAnalysis {
                    BatteryLevelTrail(values: viewModel.batterySpark, tint: .macFanCyan)
                        .frame(height: 58)
                        .padding(.top, 5)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Battery charge history")
                        .accessibilityIdentifier("battery-cycle-content")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("battery-cycle-analysis")
        .padding(15)
        .macFanCard(padding: 0, radius: 14, flatten: true)
    }

    private var chargingPower: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "bolt.fill").foregroundStyle(isCharging ? Color.macFanMint : Color.macFanMuted)
                Text("Charging power").macFanSubhead().foregroundStyle(Color.macFanPrimary)
                Text(isCharging ? "LIVE" : "READY").macFanCaption().foregroundStyle(isCharging ? .macFanMint : Color.macFanMuted)
                    .padding(.horizontal, 6).padding(.vertical, 2).background((isCharging ? Color.macFanMint : Color.white).opacity(0.08), in: Capsule())
            }
            if isCharging, let watts = usage?.batteryWatts {
                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text(String(format: "%.1f", watts)).macFanNumber(28, weight: .semibold).foregroundStyle(Color.macFanMint)
                    Text("W to battery cell").macFanCallout().foregroundStyle(Color.macFanSecondary)
                }
                Text("Measured from battery current × voltage. Adapter rating is shown only as hardware context.")
                    .macFanCaption().foregroundStyle(Color.macFanMuted)
            } else {
                Text("Connect a charger to observe cell-side charging power.")
                    .macFanCallout().foregroundStyle(Color.macFanSecondary)
            }
        }
        .padding(15)
        .macFanCard(padding: 0, radius: 14, flatten: true)
    }

    private var emptyBatteryState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "battery.100").font(.system(size: 44, weight: .medium)).foregroundStyle(Color.macFanMuted)
            Text("No battery data yet").macFanTitle2().foregroundStyle(Color.macFanPrimary)
            Text("MacFan will show this surface automatically on a portable Mac once macOS reports battery telemetry.")
                .macFanCallout().foregroundStyle(Color.macFanSecondary)
        }
        .padding(22)
        .macFanCard(padding: 0, radius: 16)
    }

    private var remainingText: String {
        guard let minutes = usage?.batteryMinutesRemaining, minutes > 0 else { return "—" }
        return durationText(minutes)
    }
    private var remainingDetail: String { isCharging ? "Until full" : "Estimated" }
    private var wattsText: String { usage?.batteryWatts.map { String(format: "%.1f W", $0) } ?? "—" }
    private var healthText: String { usage?.batteryHealthPercent.map { "\(Int($0.rounded()))%" } ?? "—" }
    private var healthDetail: String { usage?.batteryHealthPercent == nil ? "Not reported" : "Battery condition" }
    private var temperatureText: String { usage?.batteryTempC.map { "\(Int($0.rounded()))°C" } ?? "—" }
    private var temperatureDetail: String {
        guard let temp = usage?.batteryTempC else { return "Not reported" }
        return temp >= 38 ? "Warm" : "Moderate"
    }
    private var currentText: String { usage?.batteryCurrentMA.map { String(format: "%.0f mA", abs($0)) } ?? "—" }
    private var voltageText: String { usage?.batteryVoltageMV.map { String(format: "%.2f V", $0 / 1000) } ?? "—" }
    private var dischargeSummary: String {
        if viewModel.batterySpark.count < 2 { return "Collecting charge history" }
        let values = viewModel.batterySpark
        let drop = max(0, (values.first ?? percent) - (values.last ?? percent))
        return String(format: "%.0f%% used over the latest observations", drop)
    }

    private func durationText(_ minutes: Int) -> String {
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

private struct BatteryLevelGraphic: View {
    let percent: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            GeometryReader { proxy in
                let fraction = min(max(percent / 100, 0), 1)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.26))
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: max(9, proxy.size.width * fraction))
                        .padding(4)
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                }
            }
            .frame(height: 110)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white.opacity(0.35))
                .frame(width: 7, height: 34)
        }
        .padding(.vertical, 7)
    }
}

private struct BatteryLevelTrail: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            guard values.count > 1 else { return }
            let minValue = max(0, (values.min() ?? 0) - 2)
            let maxValue = min(100, (values.max() ?? 100) + 2)
            let span = max(1, maxValue - minValue)
            var path = Path()
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                let y = size.height * CGFloat(1 - (value - minValue) / span)
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct BatteryInsightMetric: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).macFanSectionLabel().foregroundStyle(Color.macFanMuted)
            Text(value).macFanNumber(17, weight: .semibold).foregroundStyle(tint).contentTransition(.numericText())
            Text(detail).macFanCaption().foregroundStyle(Color.macFanSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }
}

private struct BatteryTechnicalMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).macFanCaption().foregroundStyle(Color.macFanMuted)
            Text(value).macFanNumber(14, weight: .medium).foregroundStyle(Color.macFanPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
