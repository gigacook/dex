---
name: nsapplescript-admin
description: Show the native macOS admin password dialog from a Swift app and run a shell command as root, using NSAppleScript "with administrator privileges". Use for one-time privileged setup steps.
---

# NSAppleScript "with administrator privileges"

**Solved in Dex:** a native password dialog to install the sudoers rule once, with no helper tool or entitlements.

**When:** a one-off root action triggered by a user action (setup, install, uninstall).

## Example
```swift
let src = """
do shell script "/usr/sbin/visudo -cf \(tmp) && /usr/bin/install -m 440 -o root -g wheel \(tmp) /etc/sudoers.d/dex" \
with prompt "Dex needs permission once to keep your Mac awake with the lid closed." with administrator privileges
"""
var err: NSDictionary?
NSAppleScript(source: src)?.executeAndReturnError(&err)
let ok = err == nil   // cancel or failure → err is set
```

## Critical considerations
- Quoting: a Swift string inside an AppleScript string inside a shell command. Avoid spaces and quotes in paths. Write content to a temp file instead of `echo '…'`.
- Clicking Cancel returns error -128. Treat it as "do nothing", not as a crash.
- It runs synchronously on the main thread and the UI waits for the password. Fine for a one-time step.
- Don't use it for repeated actions, since it asks every time. Pair it with `sudoers-dropin`.
- Deprecated-looking but still supported. The modern alternative (SMAppService daemon) is much heavier.
