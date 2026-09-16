---
name: swift-scripts
description: Test a macOS API or idea in seconds with a throwaway `swift file.swift` script before wiring it into an app. Covers hotkeys, sensors, prefs and battery checks without rebuilding the app.
---

# Throwaway Swift scripts

**Solved in Dex:** proved things before building them. `CopySymbolicHotKeys` works, `RegisterEventHotKey` does NOT see Magnet, the HID temperature sensors exist on M2, battery readings match `pmset -g batt`, and the Magnet unbind JSON round-trips cleanly. Each took one script run instead of a full build.

**When:** any "does this API actually do what I think on this Mac?" question. Especially private or undocumented APIs.

## Example
```sh
cat > "$TMPDIR/test.swift" <<'SWIFT'
import Carbon
var ref: EventHotKeyRef?
print(RegisterEventHotKey(2, UInt32(controlKey | optionKey), EventHotKeyID(signature: 1, id: 1),
                          GetApplicationEventTarget(), 0, &ref))   // 0 = noErr
SWIFT
swift "$TMPDIR/test.swift" 2>&1 | tail -5
```
Faster repeat runs: `swiftc "$TMPDIR/test.swift" -o "$TMPDIR/t" && "$TMPDIR/t"`.

## Critical considerations
- Put scripts in `$TMPDIR` or the session scratchpad, never in the repo or home folder.
- The first `swift` run is slow (~5–20 s, it compiles). Pipe through `tail` to skip warnings.
- **Dry-run anything destructive:** do the change in memory and print a diff/count instead of writing (see `app-preferences`).
- Scripts run as the terminal app. GUI or permission behavior (TCC prompts, menu bar, focus) can differ from the real bundled app. Test those in the app.
- No top-level `app.run()`. A script that starts an event loop never exits.
