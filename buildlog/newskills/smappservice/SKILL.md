---
name: smappservice
description: Make a macOS app launch at login with one line (SMAppService.mainApp, macOS 13+), without LaunchAgent plists or helper apps.
---

# SMAppService (launch at login)

**Solved in Dex:** autostart after reboot or login.

**When:** any macOS 13+ app that should start at login.

## Example
```swift
import ServiceManagement
if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
// turn it off: try? SMAppService.mainApp.unregister()
```

## Critical considerations
- It registers **the bundle at the path it's running from**. Running a dev build from `build/` registers that copy, so delete dev builds or unregister after testing.
- The bundle must be signed (ad-hoc is fine) and have a `CFBundleIdentifier`.
- macOS shows a "Login item added" notification, and users can turn it off in System Settings → General → Login Items. Respect `.requiresApproval`.
- Calling `register()` silently on first launch is fine for a tool whose whole point is to always run. Otherwise offer a menu toggle.
- For older macOS (<13): a LaunchAgent plist in `~/Library/LaunchAgents` is the fallback.
