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
    private let router = DashboardRouter()

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

    func show(tab: DashboardTab? = nil) {
        if let tab { router.selectedTab = tab }
        if !isContentAttached {
            window.contentView = NSHostingView(rootView: DashboardView(router: router).environmentObject(model).environmentObject(settings))
            isContentAttached = true
        }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        model.surfaceDidShow(.dashboard)
    }

    func windowWillClose(_ notification: Notification) {
        window.contentView = nil
        isContentAttached = false
        model.surfaceDidHide(.dashboard)
    }
}

@MainActor
final class DashboardRouter: ObservableObject {
    @Published var selectedTab: DashboardTab = .overview
    /// Kept by the router but intentionally not published through it. Only the
    /// visible System/Battery page observes this session, so a CPU sample does
    /// not invalidate the dashboard header, sidebar, and unrelated charts.
    let systemSession = SystemUsageViewModel()
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
        case .battery: "Charge level, health, power flow, and visible-session history"
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showExpertConfirmation = false
    @State private var showClearHistoryConfirmation = false
    @ObservedObject private var router: DashboardRouter
    @State private var isSidebarVisible = true
    @Namespace private var pillNamespace
    @Namespace private var tabNamespace
    @State private var selectedSample: TelemetrySample? = nil
    @State private var selectedDetail: DashboardDetail? = nil
    @State private var selectedInsight: Insight? = nil
    @State private var selectedLiveModule: SensorModule? = nil

    init(router: DashboardRouter) {
        self.router = router
    }

    private var selectedTab: DashboardTab { router.selectedTab }
    private var systemSession: SystemUsageViewModel { router.systemSession }

    var body: some View {
        ZStack {
            MacFanBackdrop()
            HStack(spacing: 0) {
                if isSidebarVisible {
                    DashboardSidebar(
                        selectedTab: $router.selectedTab,
                        showExpertConfirmation: $showExpertConfirmation,
                        showClearHistoryConfirmation: $showClearHistoryConfirmation
                    )
                    // The sidebar carries status, quick actions, four modes,
                    // fan telemetry and manual tuning. 276pt was too narrow
                    // for that information density; 328pt keeps it compact
                    // while restoring comfortable Apple-style text measure.
                    .frame(width: 328)
                    .background(Color.macFanSurface.opacity(0.94))
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
            ZStack {
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
        }
        .onChange(of: router.selectedTab) { _, _ in
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
                        router.selectedTab = .overview
                        // The inspector otherwise remains over the chart when
                        // the user reveals evidence from an Overview card.
                        // Dismiss it so the selected point is immediately
                        // visible and the action feels complete.
                        selectedDetail = nil
                        selectedInsight = nil
                    },
                    onClose: {
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
                            isActive: model.isDashboardVisible,
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
                    .transition(reduceMotion ? .identity : .opacity)
                } else {
                    OverviewModules(isActive: model.isDashboardVisible, onSelectModule: { module in
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
            SystemUsageView(
                viewModel: systemSession,
                isActive: model.isDashboardVisible,
                onShowBattery: { router.selectedTab = .battery }
            )
        case .battery:
            BatteryInsightsTab(viewModel: systemSession, isActive: model.isDashboardVisible)
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
                // Changing a 328pt column width in an animation forces every
                // visible chart to relayout on each frame. Commit the layout
                // once; the button's press feedback still acknowledges input.
                isSidebarVisible.toggle()
                MacFanHaptics.tick()
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
            if !isSidebarVisible {
                ViewThatFits(in: .horizontal) {
                    dashboardTabBar(showsTitles: true)
                    dashboardTabBar(showsTitles: false)
                }
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

    private func dashboardTabBar(showsTitles: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(DashboardTab.allCases) { tab in
                Button {
                    guard selectedTab != tab else { return }
                    router.selectedTab = tab
                    MacFanHaptics.tick()
                } label: {
                    HStack(spacing: showsTitles ? 6 : 0) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .medium))
                        if showsTitles {
                            Text(tab.rawValue)
                                .macFanSubhead()
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .foregroundStyle(selectedTab == tab ? Color.macFanPrimary : Color.macFanSecondary)
                    .padding(.horizontal, showsTitles ? 11 : 9)
                    .frame(height: 30)
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: MacFanMetrics.radiusS, style: .continuous)
                                .fill(Color.white.opacity(0.095))
                                .matchedGeometryEffect(id: "dashboard-tab-\(showsTitles)", in: tabNamespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(MacFanPressableStyle(pressedScale: 0.97))
                .help(tab.rawValue)
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
        .animation(reduceMotion ? nil : MacFanMetrics.springSelection, value: selectedTab)
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
    let onClose: () -> Void

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
        .onExitCommand(perform: onClose)
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
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .macFanCaption()
                    .foregroundStyle(Color.macFanSecondary)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(MacFanPressableStyle(pressedScale: 0.97))
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close details")
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

private struct BatteryPresentation: Equatable {
    let percent: Double
    let flowState: BatteryFlowState
    let onExternalPower: Bool?
    let sampledAt: Date?
    let minutesRemaining: Int?
    let watts: Double?
    let signedWatts: Double?
    let healthPercent: Double?
    let cycleCount: Int?
    let adapterWatts: Double?
    let temperatureCelsius: Double?
    let currentMilliamps: Double?
    let voltageMillivolts: Double?

    init?(usage: SystemUsage?) {
        guard let usage, let percent = usage.batteryPercent else { return nil }
        self.percent = min(max(percent, 0), 100)
        flowState = usage.batteryFlowState
        onExternalPower = usage.batteryOnExternalPower
        sampledAt = usage.batterySampledAt
        minutesRemaining = usage.batteryMinutesRemaining
        watts = usage.batteryWatts
        signedWatts = usage.batterySignedWatts
        healthPercent = usage.batteryHealthPercent
        cycleCount = usage.batteryCycleCount
        adapterWatts = usage.batteryAdapterWatts
        temperatureCelsius = usage.batteryTempC
        currentMilliamps = usage.batteryCurrentMA
        voltageMillivolts = usage.batteryVoltageMV
    }
}

private struct BatteryInsightsTab: View {
    @ObservedObject var viewModel: SystemUsageViewModel
    let isActive: Bool

    var body: some View {
        Group {
            if let battery = BatteryPresentation(usage: viewModel.usage) {
                BatteryWorkspace(battery: battery, history: viewModel.batteryHistory, isActive: isActive)
                    .equatable()
            } else {
                BatteryEmptyState()
            }
        }
        // The dashboard owns the only vertical ScrollView. This task is
        // cancelled on tab change, so hidden Battery UI performs no work.
        .task(id: isActive) {
            guard isActive else { return }
            await viewModel.run(pollEvery: .seconds(5))
        }
    }
}

private enum BatteryDetail: String, Hashable {
    case time
    case power
    case health
    case temperature

    var title: String {
        switch self {
        case .time: "Visible-session history"
        case .power: "Power flow"
        case .health: "Battery health"
        case .temperature: "Temperature"
        }
    }

    var icon: String {
        switch self {
        case .time: "chart.xyaxis.line"
        case .power: "bolt.horizontal.fill"
        case .health: "heart.text.square"
        case .temperature: "thermometer.medium"
        }
    }
}

private enum BatteryFocus: Hashable {
    case metric(BatteryDetail)
    case detail(BatteryDetail)
}

private struct BatteryWorkspace: View, Equatable {
    let battery: BatteryPresentation
    let history: [BatterySessionPoint]
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detail: BatteryDetail?
    @AccessibilityFocusState private var accessibilityFocus: BatteryFocus?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.battery == rhs.battery && lhs.history == rhs.history && lhs.isActive == rhs.isActive
    }

    private var displayPercent: Int { Int(battery.percent.rounded()) }
    private var isCharging: Bool { battery.flowState == .charging }
    private var batterySymbol: String {
        switch battery.percent {
        case ..<25: return "battery.25"
        case ..<50: return "battery.50"
        case ..<75: return "battery.75"
        default: return "battery.100"
        }
    }
    private var accent: Color {
        if isCharging { return .macFanMint }
        if battery.percent <= 15 { return .macFanCoral }
        if battery.percent <= 30 { return .macFanAmberLight }
        return .macFanIndigo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MacFanMetrics.spacing) {
            hero
            if let detail {
                depthPanel(detail)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            Text("Measured locally from macOS. Battery sampling and charging motion stop when this page closes.")
                .macFanCaption()
                .foregroundStyle(Color.macFanMuted)
                .padding(.horizontal, 2)
        }
        .onExitCommand { closeDetail() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 9) {
                Image(systemName: batterySymbol)
                    .macFanHeadline()
                    .foregroundStyle(accent)
                Text("Battery").macFanHeadline().foregroundStyle(Color.macFanPrimary)
                Text(battery.flowState.title)
                    .macFanCaption()
                    .foregroundStyle(accent)
                    .padding(.horizontal, 8)
                    .frame(height: 23)
                    .background(accent.opacity(0.12), in: Capsule())
                Spacer()
                LiveDot(color: accent)
                Text("Live · 5 sec").macFanCaption().foregroundStyle(Color.macFanSecondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 28) { batteryGraphic; primaryReading }
                VStack(alignment: .leading, spacing: 14) { batteryGraphic; primaryReading }
            }

            Divider().overlay(Color.white.opacity(0.07))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                metric(.time, title: "Remaining", value: remainingText, detail: remainingDetail, tint: .macFanBlue)
                metric(.power, title: "Battery flow", value: signedWattsText, detail: flowDetail, tint: isCharging ? .macFanMint : .macFanVioletLight)
                metric(.health, title: "Health", value: healthText, detail: healthDetail, tint: healthTint)
                metric(.temperature, title: "Temperature", value: temperatureText, detail: temperatureDetail, tint: temperatureTint)
            }
        }
        .padding(18)
        .macFanCard(padding: 0, radius: 18, flatten: true)
        .overlay(alignment: .top) {
            LinearGradient(colors: [accent.opacity(0.11), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .allowsHitTesting(false)
        }
    }

    private var batteryGraphic: some View {
        BatteryLevelGraphic(
            percent: battery.percent,
            tint: accent,
            isCharging: isCharging,
            isActive: isActive,
            reduceMotion: reduceMotion
        )
        .frame(minWidth: 220, idealWidth: 290, maxWidth: 330, minHeight: 116, idealHeight: 130, maxHeight: 132)
        .accessibilityLabel("Battery charge \(displayPercent) percent, \(battery.flowState.title)")
    }

    private var primaryReading: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text("\(displayPercent)")
                    .macFanNumber(50, weight: .semibold)
                    .foregroundStyle(Color.macFanPrimary)
                    .macFanLiveNumberTransition()
                Text("%").macFanNumber(18, weight: .medium).foregroundStyle(Color.macFanSecondary)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: displayPercent)
            Text(battery.flowState.title).macFanTitle2().foregroundStyle(accent)
            Text(stateDetail).macFanCallout().foregroundStyle(Color.macFanSecondary)
            if history.count > 1 {
                BatteryLevelTrail(values: history.map(\.percent), tint: accent)
                    .frame(width: 300, height: 38)
            }
        }
        .frame(minWidth: 230, maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ kind: BatteryDetail, title: String, value: String, detail subtitle: String, tint: Color) -> some View {
        Button {
            let isClosing = detail == kind
            if reduceMotion { detail = isClosing ? nil : kind }
            else {
                withAnimation(.easeOut(duration: 0.16)) { detail = isClosing ? nil : kind }
            }
            accessibilityFocus = isClosing ? .metric(kind) : .detail(kind)
            MacFanHaptics.tick()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title).macFanCaption().foregroundStyle(Color.macFanMuted)
                    Spacer()
                    Image(systemName: detail == kind ? "chevron.up" : "chevron.right")
                        .macFanChartTick().foregroundStyle(detail == kind ? tint : Color.macFanMuted)
                }
                Text(value).macFanNumber(18, weight: .semibold).foregroundStyle(tint).macFanLiveNumberTransition()
                Text(subtitle).macFanCaption().foregroundStyle(Color.macFanSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .padding(11)
            .background(Color.white.opacity(detail == kind ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(detail == kind ? tint.opacity(0.35) : Color.white.opacity(0.05), lineWidth: 0.75)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MacFanPressableStyle())
        .accessibilityIdentifier("battery-metric-\(kind.rawValue)")
        .accessibilityValue(detail == kind ? "Expanded" : "Collapsed")
        .accessibilityFocused($accessibilityFocus, equals: .metric(kind))
    }

    private func depthPanel(_ selected: BatteryDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: selected.icon)
                    .macFanHeadline().foregroundStyle(accent)
                    .frame(width: 32, height: 32)
                    .background(accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.title).macFanHeadline().foregroundStyle(Color.macFanPrimary)
                    Text(detailSubtitle(selected)).macFanCallout().foregroundStyle(Color.macFanSecondary)
                }
                Spacer()
                Button("Done", action: closeDetail)
                    .buttonStyle(MacFanPressableStyle(pressedScale: 0.97))
                    .macFanSubhead().foregroundStyle(Color.macFanBlue)
                    .padding(.horizontal, 11).frame(height: 28)
                    .background(Color.macFanBlue.opacity(0.10), in: Capsule())
                    .keyboardShortcut(.cancelAction)
            }
            Divider().overlay(Color.white.opacity(0.06))
            detailContent(selected)
        }
        .padding(16)
        .macFanCard(padding: 0, radius: 15, flatten: true)
        .accessibilityIdentifier("battery-detail-\(selected.rawValue)")
        .accessibilityFocused($accessibilityFocus, equals: .detail(selected))
    }

    @ViewBuilder
    private func detailContent(_ selected: BatteryDetail) -> some View {
        switch selected {
        case .time:
            BatterySessionChart(points: history, tint: accent)
                .frame(height: 142)
            HStack {
                BatteryTechnicalMetric(title: "Observed", value: observedDuration)
                BatteryTechnicalMetric(title: "Samples", value: "\(history.count)")
                BatteryTechnicalMetric(title: "Session change", value: sessionChange)
                BatteryTechnicalMetric(title: "Estimated rate", value: sessionRate)
            }
        case .power:
            HStack {
                BatteryTechnicalMetric(title: "Battery flow", value: signedWattsText)
                BatteryTechnicalMetric(title: "Current magnitude", value: currentText)
                BatteryTechnicalMetric(title: "Cell voltage", value: voltageText)
                BatteryTechnicalMetric(title: "Adapter rating", value: adapterText)
            }
            Text("Battery flow is the cell-side estimate current × voltage. Adapter rating is hardware capability, not live wall consumption.")
                .macFanCaption().foregroundStyle(Color.macFanMuted)
        case .health:
            HStack {
                BatteryTechnicalMetric(title: "Capacity health", value: healthText)
                BatteryTechnicalMetric(title: "Cycle count", value: battery.cycleCount.map(String.init) ?? "Not reported")
                BatteryTechnicalMetric(title: "Charge level", value: "\(displayPercent)%")
                BatteryTechnicalMetric(title: "Source", value: battery.healthPercent == nil ? "Not reported" : "Capacity vs design")
            }
            Text("MacFan never substitutes charge level for battery health. If macOS does not expose capacity data, health remains unreported.")
                .macFanCaption().foregroundStyle(Color.macFanMuted)
        case .temperature:
            HStack {
                BatteryTechnicalMetric(title: "Current", value: temperatureText)
                BatteryTechnicalMetric(title: "Session low", value: sessionMinimumTemperature)
                BatteryTechnicalMetric(title: "Session high", value: sessionMaximumTemperature)
                BatteryTechnicalMetric(title: "Assessment", value: temperatureDetail)
            }
            Text("Battery temperature is separate from CPU temperature and comes from AppleSmartBattery when available.")
                .macFanCaption().foregroundStyle(Color.macFanMuted)
        }
    }

    private func closeDetail() {
        guard let closingDetail = detail else { return }
        if reduceMotion { detail = nil }
        else { withAnimation(.easeOut(duration: 0.14)) { detail = nil } }
        accessibilityFocus = .metric(closingDetail)
    }

    private func detailSubtitle(_ selected: BatteryDetail) -> String {
        switch selected {
        case .time: "Timestamped samples from this visible session"
        case .power: "Direction, current, voltage, and adapter context"
        case .health: "Capacity-backed information only"
        case .temperature: "Current reading and visible-session range"
        }
    }

    private var stateDetail: String {
        if let minutes = battery.minutesRemaining, minutes > 0 {
            return isCharging ? "About \(durationText(minutes)) until full" : "About \(durationText(minutes)) remaining"
        }
        switch battery.flowState {
        case .charging: return "Energy is flowing into the battery cell"
        case .discharging: return "Running from the internal battery"
        case .connectedIdle: return "Adapter connected; battery is not charging"
        case .unknown: return "Waiting for macOS power-source state"
        }
    }

    private var remainingText: String { battery.minutesRemaining.map(durationText) ?? "—" }
    private var remainingDetail: String { battery.minutesRemaining == nil ? "macOS has no estimate" : (isCharging ? "Until full" : "Estimated") }
    private var signedWattsText: String {
        guard let watts = battery.signedWatts else { return "—" }
        if abs(watts) < 0.05 { return "0.0 W" }
        return String(format: "%@%.1f W", watts > 0 ? "+" : "−", abs(watts))
    }
    private var flowDetail: String {
        switch battery.flowState {
        case .charging: "Into battery"
        case .discharging: "From battery"
        case .connectedIdle: "Adapter connected"
        case .unknown: "Direction unavailable"
        }
    }
    private var healthText: String { battery.healthPercent.map { "\(Int($0.rounded()))%" } ?? "—" }
    private var healthDetail: String { battery.healthPercent == nil ? "Not reported" : "Capacity vs design" }
    private var healthTint: Color {
        guard let health = battery.healthPercent else { return .macFanMuted }
        return health < 80 ? .macFanAmberLight : .macFanMint
    }
    private var temperatureText: String { battery.temperatureCelsius.map { "\(Int($0.rounded()))°C" } ?? "—" }
    private var temperatureDetail: String {
        guard let temp = battery.temperatureCelsius else { return "Not reported" }
        if temp < 10 { return "Cold" }
        if temp < 35 { return "Normal" }
        if temp < 40 { return "Warm" }
        return "Hot"
    }
    private var temperatureTint: Color {
        guard let temp = battery.temperatureCelsius else { return .macFanMuted }
        if temp >= 40 { return .macFanCoral }
        if temp >= 35 { return .macFanAmberLight }
        return .macFanCyan
    }
    private var currentText: String { battery.currentMilliamps.map { String(format: "%.0f mA", abs($0)) } ?? "—" }
    private var voltageText: String { battery.voltageMillivolts.map { String(format: "%.2f V", $0 / 1_000) } ?? "—" }
    private var adapterText: String {
        if let watts = battery.adapterWatts { return "\(Int(watts.rounded())) W rating" }
        switch battery.onExternalPower {
        case true?: return "Connected"
        case false?: return "Not connected"
        case nil: return "Not reported"
        }
    }
    private var observedDuration: String {
        guard let first = history.first?.timestamp, let last = history.last?.timestamp else { return "Collecting" }
        return durationText(max(0, Int(last.timeIntervalSince(first) / 60)))
    }
    private var sessionChange: String {
        guard let first = history.first?.percent, let last = history.last?.percent else { return "—" }
        return String(format: "%+.1f%%", last - first)
    }
    private var sessionRate: String {
        guard let first = history.first, let last = history.last else { return "Stabilizing" }
        let elapsed = last.timestamp.timeIntervalSince(first.timestamp)
        guard elapsed >= 600 else { return "Stabilizing" }
        return String(format: "%+.1f%%/h", (last.percent - first.percent) / elapsed * 3_600)
    }
    private var sessionMinimumTemperature: String { history.compactMap(\.temperatureCelsius).min().map { "\(Int($0.rounded()))°C" } ?? "—" }
    private var sessionMaximumTemperature: String { history.compactMap(\.temperatureCelsius).max().map { "\(Int($0.rounded()))°C" } ?? "—" }

    private func durationText(_ minutes: Int) -> String {
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return minutes > 0 ? "\(minutes)m" : "<1m"
    }
}

private struct BatteryLevelGraphic: View {
    let percent: Double
    let tint: Color
    let isCharging: Bool
    let isActive: Bool
    let reduceMotion: Bool
    @State private var displayedPercent: Double = 0

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                let fraction = min(max(displayedPercent / 100, 0), 1)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                    if fraction > 0 {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: isCharging ? [.macFanCyan, .macFanMint] : [tint, .macFanVioletLight],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(8, (proxy.size.width - 8) * fraction), height: proxy.size.height - 8)
                            .padding(4)
                            .overlay {
                                if isCharging && isActive && !reduceMotion {
                                    BatteryChargingRibbon()
                                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                                        .frame(width: max(8, (proxy.size.width - 8) * fraction), height: proxy.size.height - 8)
                                        .padding(4)
                                }
                            }
                    }
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.20), lineWidth: 1)
                }
            }
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white.opacity(0.34))
                .frame(width: 8, height: 36)
        }
        .padding(.vertical, 7)
        .onAppear { displayedPercent = percent }
        .onChange(of: percent) { _, next in
            if reduceMotion { displayedPercent = next }
            else { withAnimation(.easeOut(duration: 0.34)) { displayedPercent = next } }
        }
    }
}

private struct BatteryChargingRibbon: View {
    @State private var travels = false

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [.clear, .white.opacity(0.34), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 52)
                .offset(x: travels ? proxy.size.width + 20 : -72)
                .onAppear {
                    travels = false
                    withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) { travels = true }
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct BatteryLevelTrail: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            guard values.count > 1 else { return }
            let low = max(0, (values.min() ?? 0) - 1)
            let high = min(100, (values.max() ?? 100) + 1)
            let span = max(2, high - low)
            var path = Path()
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                let y = size.height * CGFloat(1 - (value - low) / span)
                index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
            }
            context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct BatterySessionChart: View {
    let points: [BatterySessionPoint]
    let tint: Color

    private var minimumPercent: Double { points.map(\.percent).min() ?? 0 }
    private var maximumPercent: Double { points.map(\.percent).max() ?? 0 }
    private var startLabel: String { points.first?.timestamp.formatted(date: .omitted, time: .shortened) ?? "—" }
    private var endLabel: String { points.last?.timestamp.formatted(date: .omitted, time: .shortened) ?? "—" }
    private var accessibilitySummary: String {
        guard let first = points.first, let last = points.last else { return "Collecting samples" }
        let change = last.percent - first.percent
        let chargeSummary = String(
            format: "From %.0f to %.0f percent, low %.0f, high %.0f, change %+.1f percent",
            first.percent, last.percent, minimumPercent, maximumPercent, change
        )
        let duration = max(0, last.timestamp.timeIntervalSince(first.timestamp))
        let durationSummary = duration < 60
            ? "\(Int(duration.rounded())) seconds observed"
            : "\(Int((duration / 60).rounded())) minutes observed"
        let powerValues = points.compactMap(\.signedWatts)
        guard let latestPower = powerValues.last,
              let minimumPower = powerValues.min(),
              let maximumPower = powerValues.max() else {
            return "\(chargeSummary), \(durationSummary), battery power unavailable"
        }
        return "\(chargeSummary), \(durationSummary), latest power \(powerDescription(latestPower)), range \(powerDescription(minimumPower)) to \(powerDescription(maximumPower))"
    }

    private func powerDescription(_ watts: Double) -> String {
        if abs(watts) < 0.05 { return "0 watts" }
        return String(format: "%.1f watts %@", abs(watts), watts > 0 ? "into the battery" : "out of the battery")
    }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            guard points.count > 1, let first = points.first, let last = points.last else { return }
            let elapsed = max(last.timestamp.timeIntervalSince(first.timestamp), 1)
            let low = max(0, minimumPercent - 1)
            let high = min(100, maximumPercent + 1)
            let span = max(2, high - low)
            let chargeHeight = size.height * 0.68
            var line = Path()
            for (index, point) in points.enumerated() {
                let x = size.width * CGFloat(point.timestamp.timeIntervalSince(first.timestamp) / elapsed)
                let y = chargeHeight * CGFloat(1 - (point.percent - low) / span)
                index == 0 ? line.move(to: CGPoint(x: x, y: y)) : line.addLine(to: CGPoint(x: x, y: y))
            }
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            let baseline = size.height * 0.84
            var axis = Path(); axis.move(to: CGPoint(x: 0, y: baseline)); axis.addLine(to: CGPoint(x: size.width, y: baseline))
            context.stroke(axis, with: .color(.white.opacity(0.09)), lineWidth: 0.5)
            let maxPower = max(points.compactMap { $0.signedWatts.map(abs) }.max() ?? 1, 1)
            for point in points {
                guard let watts = point.signedWatts else { continue }
                let x = size.width * CGFloat(point.timestamp.timeIntervalSince(first.timestamp) / elapsed)
                let height = CGFloat(min(abs(watts) / maxPower, 1)) * size.height * 0.13
                let rect = CGRect(x: x - 1, y: watts >= 0 ? baseline - height : baseline, width: 2, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(watts >= 0 ? .macFanMint : .macFanVioletLight))
            }
        }
        .overlay(alignment: .topLeading) {
            HStack {
                Text("Charge level")
                Spacer()
                Text("\(Int(minimumPercent.rounded(.down)))–\(Int(maximumPercent.rounded(.up)))%")
            }
            .macFanChartTick()
            .foregroundStyle(Color.macFanMuted)
        }
        .overlay(alignment: .bottomLeading) {
            HStack {
                Text("Battery flow  + in / − out")
                Spacer()
                Text("\(startLabel)–\(endLabel)")
            }
            .macFanChartTick()
            .foregroundStyle(Color.macFanMuted)
        }
        .accessibilityLabel("Visible-session battery charge and power flow chart")
        .accessibilityValue(accessibilitySummary)
    }
}

private struct BatteryTechnicalMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).macFanCaption().foregroundStyle(Color.macFanMuted)
            Text(value).macFanNumber(15, weight: .medium).foregroundStyle(Color.macFanPrimary).macFanLiveNumberTransition()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BatteryEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "battery.100").font(.system(size: 44, weight: .medium)).foregroundStyle(Color.macFanMuted)
            Text("No battery data yet").macFanTitle2().foregroundStyle(Color.macFanPrimary)
            Text("MacFan will show this workspace automatically when macOS reports internal-battery telemetry.")
                .macFanCallout().foregroundStyle(Color.macFanSecondary)
        }
        .padding(22)
        .macFanCard(padding: 0, radius: 16)
    }
}
