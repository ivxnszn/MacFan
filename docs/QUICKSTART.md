# MacFan quick start

MacFan lives in the menu bar. Click its fan icon to open the compact control surface; choose **History** for the full dashboard.

## A safe first run

1. Start in **Auto**. This leaves every fan under macOS control.
2. Let the app collect a few minutes of CPU temperature and RPM history.
3. Open **Overview** to inspect the temperature timeline, fan response, and the latest explanation cards.
4. Use **Sensors** when you want a specific die, GPU reading, or technical details.
5. Install or repair the helper only if you want to try Smart, Max, or Manual control.

## Modes

- **Auto** — macOS manages the fans. This is the default and the safest mode.
- **Smart** — requests stronger cooling above the configured threshold and releases it only after the temperature has settled.
- **Max** — requests the discovered hardware maximum for every fan.
- **Manual** — exposes a bounded target for each fan. The slider never exceeds the hardware limits reported by the helper.

If a mode is dimmed or says setup is required, the app is still monitoring normally; control has simply not passed its preflight gate.

## Reading the charts

The temperature chart uses cooler blue/purple tones for normal readings and amber/red markers for genuinely hot periods. The fan chart keeps actual RPM separate from MacFan’s requested target and the macOS target, so a firmware refusal is visible instead of being hidden behind a misleading “active” state.

Click an evidence card, peak, or sensor to reveal the supporting interval and technical detail. Change the range in the upper-right to compare a recent episode with the last day, week, or month.

## Cool Burst

Option-click the menu-bar icon to start a ten-minute maximum-cooling burst. A countdown stays visible and Auto is restored automatically when it ends.

## Troubleshooting

If the helper is unavailable, run the installer again and allow the administrator prompt. Quit other fan controllers before retrying. If control still cannot be verified, leave MacFan in Auto: monitoring and history do not depend on the helper.
