# Contributing to MacFan

MacFan is a local-first macOS utility. Contributions should preserve three product guarantees:

- No network service, analytics, account, or cloud dependency.
- No misleading control state: a mode is active only after hardware confirmation.
- Any lost heartbeat, invalid telemetry, sleep/wake transition, app quit, or helper failure returns fans to macOS/System control.

Before opening a pull request:

1. Run the unit tests with `xcodebuild -project MacFan.xcodeproj -scheme MacFan -destination 'platform=macOS,arch=arm64' test`.
2. Run the UI tests on a Mac when changing SwiftUI/AppKit behavior.
3. Run `git diff --check`.
4. Do not commit `build/`, DerivedData, telemetry databases, screenshots containing personal desktop content, signing identities, or administrator credentials.

Keep changes focused and explain any change to helper behavior or fan safety in the pull request description.
