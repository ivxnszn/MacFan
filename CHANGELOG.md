# Changelog

All notable changes to MacFan are documented here.

## [0.1.1] — 2026-07-14

This patch restores the dedicated battery workspace from the premium MacFan design pass and keeps battery information useful without adding generic dashboard noise.

### What changed

- **Restored the Battery tab** with a large live charge graphic, percentage, battery state, remaining time, cell power, health, and temperature at a glance.
- **Added progressive battery detail** for current, voltage, cycle count, and a discharge-history chart without overwhelming the compact view.
- **Clarified power semantics**: MacFan labels cell-side power as an estimate from current × voltage and does not present the adapter rating as battery consumption.
- **Moved battery analysis out of the generic metric grid** so the Overview stays focused on thermal and fan behavior while the Battery tab gets the space it needs.
- **Added accessible Battery controls** with stable identifiers and spoken labels for charge, electrical details, and history disclosures.
- **Refined release metadata** to version 0.1.1 and removed internal terminology from the Battery tab subtitle.

### Validation

- arm64 Debug and Release builds pass.
- 103 unit tests pass.
- Battery tab, electrical disclosure, and discharge-history interaction verified on the target Mac.

## [0.1.0] — 2026-07-13

This is the first complete public release of MacFan: a local-first thermal monitor with carefully guarded, experimental fan control for Apple Silicon Macs.

### What’s new

- **A focused dashboard** with Overview, Insights, Sensors, and System areas instead of generic system-monitor clutter.
- **CPU temperature as the headline signal**, with a live trend, peak temperature, thermal state, and plain-language explanations.
- **Compact menu-bar popover** with fast Auto, Smart, Max, and Manual actions, live fan status, and a route to the full dashboard.
- **Per-fan controls** that let you select a discovered fan and tune its target when hardware control is available.
- **Smart Boost and Max modes** with clear control-state feedback, bounded targets, and automatic return to macOS control when safety conditions require it.
- **Thermal history and insights** with linked temperature/RPM charts, selectable ranges, peak annotations, thermal episodes, and evidence-based summaries.
- **Sensor investigation tools** with search, categories, sensor comparison, technical details, and per-sensor statistics.
- **System information** for CPU cores, memory, GPU, battery, disk, network activity, and hardware identity—shown progressively so the app stays compact.
- **A refined dark indigo interface** with consistent typography, calmer cards, accessible labels, responsive controls, and reduced redraw work while scrolling or sampling.
- **Local-only operation** with no account, cloud service, analytics, or telemetry upload.
- **A guarded helper architecture** that accepts semantic fan operations only, validates callers and limits, requires a heartbeat, and restores System control on app/helper failure, sleep/wake, invalid telemetry, or expiry.

### Reliability and quality

- 103 deterministic unit tests covering fan limits, Smart Boost hysteresis, expert curves, history retention, rollups, sensor statistics, insights, and safety behavior.
- UI coverage for dashboard launch, progressive disclosure, every main tab, compact popover controls, and both-fan visibility.
- arm64-native Release build validated on macOS.
- No personal paths, credentials, telemetry databases, signing identities, or machine-specific configuration included in the repository.

### Important limitations

Fan writes use private Apple Silicon interfaces and are not supported by Apple. Monitoring and history work without the helper; direct control is enabled only after the local helper verifies that the hardware responds. Another fan controller or a future macOS/firmware update may limit or reject control requests.
