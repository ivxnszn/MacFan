# MacFan UX & Performance Pass

Last updated: 2026-07-15

## Goal

Make MacFan feel compact, alive, and immediately understandable while preserving truthful telemetry and safe fan control. Interactions should feel responsive on a high-refresh-rate display, with deeper information available on demand and an obvious way back.

## Current workstream

- [x] Audit SwiftUI invalidation, drawing, scrolling, polling, and page-switch costs.
- [x] Audit navigation, typography, spacing, alignment, and micro-interactions.
- [x] Redesign the Battery workspace around real-time, truthful battery data.
- [x] Refine the menu-bar popover for denser but clearer information.
- [x] Build, test, visually inspect, and record final validation.

## Non-negotiables

- No fake 144 Hz promise: optimize for low-latency interaction and avoid continuous animation/rendering when hidden.
- Respect Reduce Motion and do not animate every telemetry tick indiscriminately.
- CPU temperature remains the thermal headline.
- Battery wattage is cell-side current × voltage when available; adapter rating is context, not consumption.
- Every progressive disclosure or detail page must have an obvious close/back action.
- No network service, analytics, or personal telemetry leaves the Mac.

## Implemented in this pass

- Dashboard pages no longer enter the selection pill's spring transaction.
- Battery no longer nests a `ScrollView`; it shares the dashboard's 24pt leading edge.
- Header navigation is hidden while the sidebar is visible, removing duplicate navigation.
- Dashboard routing supports direct System/Battery links from the menu-bar popover.
- Inspector and live-module depth views have explicit close controls and Escape support.
- Battery state distinguishes charging, discharging, and adapter-connected idle.
- The invalid charge-percentage-as-health fallback is removed.
- Battery time estimates reject invalid values over 48 hours.
- Battery history is timestamped and deduplicated at the real 5-second hardware cadence.
- Battery metrics open one depth panel; repeat-click, Done, or Escape closes it.
- Battery fill changes are scoped; charging has a clipped ribbon only while visible.
- Popover state uses rounded, Equatable vitals instead of full volatile host counters.
- Popover vitals deep-link to System and Battery.
- Sidebar micro-pills were replaced by one readable status strip.
- An already attached dashboard hierarchy is reused instead of rebuilt.
- Overview and Battery samplers now pause while the dashboard is minimized or occluded.
- Battery charging motion is removed from the render tree whenever its page is not actually visible.
- Battery history starts a new segment after a visibility gap or charge-direction change, avoiding false slopes and rates.
- Missing macOS power-source state remains unknown instead of being mislabeled as discharge.
- Adapter-connected idle power is only shown as 0 W for a genuinely near-zero reading; contradictory samples remain unavailable.
- Battery chart depth now exposes low/high scale, time span, and a VoiceOver summary.
- The sidebar selection glides within the navigation rail without animating the page or charts.
- Header navigation has an icon-only fallback at constrained widths.
- The menu-bar verdict/vitals card falls back to two rows instead of truncating meaningful text.
- Regular menu-bar launch stays lightweight; the full dashboard opens only on request (or in deterministic UI tests).
- A minimized dashboard is explicitly restored before visibility-gated work resumes.
- Live metric drill-down owns a child-scoped sampler, so CPU, memory, disk, and network values stay current without invalidating the dashboard root.
- Time-to-full and time-to-empty are shown only for a confirmed matching energy direction.
- Unknown adapter state stays “Not reported” instead of being inferred as disconnected.
- The Battery chart's VoiceOver summary includes charge range, elapsed time, and signed power-flow direction/range.

## Final validation

- arm64 Debug build: passed.
- Unit tests: 111/111 passed.
- UI tests: 3/3 passed, covering launch, every dashboard tab, progressive disclosure, Battery detail open/close, and compact popover controls/fans above the fold.
- arm64 Release build: passed with whole-module optimization.
- Visual inspection on live M3 Pro telemetry: Overview and Battery alignment, hierarchy, charging state, real-time wattage, health, temperature, and metric expansion verified.
- Independent performance and UI/UX counter-reviews: no remaining P0 issue; all reported polling, truthfulness, responsive-layout, Reduce Motion, and navigation-motion P1 items addressed.

## Resume notes

The source of truth is the current working tree. Before resuming, run `git status -sb`, read this file, then continue from the first unchecked workstream item. Do not replace the installed app until Debug/Release builds and relevant tests pass.
