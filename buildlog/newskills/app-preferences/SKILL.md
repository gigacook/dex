---
name: app-preferences
description: Find, read, decode and safely edit ANOTHER macOS app's settings (defaults, plutil, CFPreferences), e.g. to detect or remove a conflicting keyboard shortcut in Magnet/Rectangle. Includes the quit → edit → relaunch pattern.
---

# Other apps' preferences (defaults / plutil / CFPreferences)

**Solved in Dex:** found out *why* ⌃⌥D resized windows (Magnet's "Left Third"/"Top Third"), showed those action names in the warning, and added one-click **Unbind in Magnet**.

**When:** your app collides with another app's setting, or you need to know what another app does.

## Find the culprit (terminal)
```sh
ps -axo comm | grep -iE "magnet|rectangle|bettertouch|raycast|karabiner|hammerspoon"   # what's running
defaults read /Applications/Magnet.app/Contents/Info.plist CFBundleIdentifier            # bundle id = prefs domain
defaults read com.crowdcafe.windowmagnet | head                                          # overview
ls ~/Library/Preferences/<id>.plist ~/Library/Containers/<id>/Data/Library/Preferences/  # plain or sandboxed?
# values shown as {length = …, bytes = …} are Data. Decode:
defaults export com.crowdcafe.windowmagnet - | plutil -extract horizontalCommands raw -o - - | base64 -d | python3 -m json.tool
```

## Read + edit from Swift
```swift
let id = "com.crowdcafe.windowmagnet" as CFString
let data = CFPreferencesCopyAppValue("horizontalCommands" as CFString, id) as? Data
var cmds = try JSONSerialization.jsonObject(with: data!) as! [[String: Any]]
// …modify…
CFPreferencesSetAppValue("horizontalCommands" as CFString, try JSONSerialization.data(withJSONObject: cmds) as CFData, id)
CFPreferencesAppSynchronize(id)
```
Safe edit pattern:
1. **Back up:** `defaults export <id> ~/Library/Application Support/<You>/backup-<ts>.plist` (restore: `defaults import <id> file`)
2. **Quit it:** `NSRunningApplication.runningApplications(withBundleIdentifier:)` → `.terminate()`, wait on `isTerminated` (spin the RunLoop, max ~5 s)
3. **Edit** via CFPreferences → `CFPreferencesAppSynchronize`
4. **Relaunch** only if it was running: `NSWorkspace.shared.openApplication(at:configuration:)`
5. **Verify** by reading it back

## Critical considerations
- **Apps cache settings in memory.** Editing while the app runs gets overwritten, or ignored until restart. Always quit → edit → relaunch.
- **Copy the "empty" shape the app already uses.** Magnet separators store `keyboardShortcut` without a `shortcut` key, so removing just that key is a format Magnet already accepts. Don't invent new structures.
- **Dry-run first:** in a `swift` script, change and serialize but don't write. Check the count matches, only the intended entries changed, and Bools are still Bools (`__NSCFBoolean`).
- Sandboxed apps keep prefs in `~/Library/Containers/<id>/…`. Touching those triggers the macOS "access data from other apps" prompt. Plain `~/Library/Preferences` doesn't.
- Magnet: `horizontalCommands`/`verticalCommands` = JSON Data, `name` like `command:default.name.leftThird`, shortcut `carbonKeyCode` + `carbonModifiers`. Rectangle (`com.knollsoft.Rectangle`): per-action dicts `{keyCode, modifierFlags}` (NSEvent flags). **Rectangle's format for a *cleared* shortcut is unverified**, so Dex only warns there and doesn't edit.
- These formats are undocumented and can change with app updates. Fail safe (return "couldn't unbind") and keep the backup.
