---
name: iokit-power
description: Read battery percentage, charger vs battery, and thermal pressure on macOS from Swift (IOKit.ps + ProcessInfo.thermalState). Use for auto-off safety logic in power/keep-awake tools.
---

# IOKit power sources + thermal state

**Solved in Dex:** Safe Mode. Auto-off when the Mac is hot, or on battery at ≤ 15%.

**When:** anything that should back off under heat or low battery.

## Example
```swift
import IOKit.ps

let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue

let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
let onBattery = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String == kIOPSBatteryPowerValue
for ps in IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef] {
    if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
       let pct = d[kIOPSCurrentCapacityKey] as? Int { print(pct) }
}
```
Terminal equivalents for quick checks: `pmset -g batt`, `pmset -g therm`.

## Critical considerations
- **Memory rules:** `Copy…` functions → `takeRetainedValue()`. `Get…` functions → `takeUnretainedValue()`. Mixing them up leaks memory or crashes.
- Desktops (Mac mini/Studio) have no battery source. The loop simply finds nothing, so treat that as "not low".
- `thermalState` is a coarse system pressure level (nominal/fair/serious/critical), not degrees. Real temperatures need private SMC APIs, so skip them.
- A 30 s `Timer` only while active is enough. `ProcessInfo.thermalStateDidChangeNotification` exists for instant reaction if needed.
- Timers don't fire while an `NSAlert` is modal. Fine here, because the unsafe state is handled before the alert shows.
