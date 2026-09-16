---
name: iohid-temperature
description: Read real chip temperatures (°C) on Apple Silicon Macs from Swift without root, via the private IOHIDEventSystemClient API. Use for thermal cutoffs or temperature displays.
---

# IOHID temperature sensors (Apple Silicon)

**Solved in Dex:** Auto-Disable at a user-set °C (default 80). `ProcessInfo.thermalState` only gives coarse levels.

**When:** you need an actual temperature number. No SMC code, no sudo, no `powermetrics`.

## Example
```swift
@_silgen_name("IOHIDEventSystemClientCreate") func IOHIDEventSystemClientCreate(_: CFAllocator?) -> Unmanaged<AnyObject>
@_silgen_name("IOHIDEventSystemClientSetMatching") func IOHIDEventSystemClientSetMatching(_: AnyObject, _: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") func IOHIDEventSystemClientCopyServices(_: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty") func IOHIDServiceClientCopyProperty(_: AnyObject, _: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent") func IOHIDServiceClientCopyEvent(_: AnyObject, _: Int64, _: Int32, _: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue") func IOHIDEventGetFloatValue(_: AnyObject, _: Int32) -> Double

let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault).takeRetainedValue()
_ = IOHIDEventSystemClientSetMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
for s in IOHIDEventSystemClientCopyServices(c)?.takeRetainedValue() as? [AnyObject] ?? [] {
    let name = IOHIDServiceClientCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
    if let e = IOHIDServiceClientCopyEvent(s, 15, 0, 0)?.takeRetainedValue() {   // 15 = temperature event
        print(name, IOHIDEventGetFloatValue(e, 15 << 16))
    }
}
```

## Critical considerations
- **Private API.** Fine for direct distribution, **rejected by the Mac App Store**, and can break in a future macOS.
- Sensor names (M2): `PMU tdie1…8` / `PMU2 tdie*` = chip die (use max). `tdev*` = other parts. `gas gauge battery` = battery. `NAND` = SSD. **`tcal` is a constant (~51.85), not a real reading**, so exclude it.
- Some `tdev` sensors report garbage negatives (-1.5). Filter by name, not by taking max of everything.
- Apple Silicon chips normally run 90–100°C under heavy load. A low cutoff (80) will trip during real work. That's intended for Dex (closed-lid safety), but tell the user.
- Intel Macs: these sensors mostly don't exist. Fall back to `ProcessInfo.processInfo.thermalState`.
- Test fast with `swift test.swift` before wiring into the app.
