---
name: nsstatusitem
description: Build a no-window macOS menu bar app in AppKit. Covers the status item, an icon drawn in code, the menu, NSAlert dialogs and hiding the Dock icon.
---

# NSStatusItem menu bar app

**Solved in Dex:** the whole UI. A ring + bolt icon drawn in code (thin template = idle, thick green = active), a menu with info/link/hotkey/quit, and alerts for warnings.

**When:** background utilities where the icon itself is the status indicator.

## Example
```swift
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
    NSColor.white.setStroke()
    let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1.1, dy: 1.1)); ring.lineWidth = 1.2; ring.stroke()
    return true
}
img.isTemplate = true            // system tints for light/dark menu bar
item.button?.image = img

let menu = NSMenu()
menu.addItem(withTitle: "Info line", action: nil, keyEquivalent: "")               // greyed text
menu.addItem(withTitle: "Quit", action: #selector(NSApp.terminate), keyEquivalent: "q")
item.menu = menu                 // any click opens the menu

NSApplication.shared.setActivationPolicy(.accessory)                         // no Dock icon
```
Info.plist: `LSUIElement = true` (no Dock icon even before code runs).

## Critical considerations
- 18×18 pt is the right icon size. Drawing with `NSImage(size:flipped:drawingHandler:)` is sharp on Retina and needs no asset files.
- **Template images ignore your color.** Use them for the neutral state. A colored state (green) needs `isTemplate = false`.
- Setting `item.menu` means right and left clicks both open the menu. Handling them separately needs `button.action` + `sendAction(on:)`, which is more code.
- Menu items with `action: nil` show as grey (disabled). Good for author/date/quote lines.
- Custom menu actions need `.target = self` on items, or they stay disabled.
- Call `NSApp.activate(ignoringOtherApps: true)` before `NSAlert.runModal()`, or the alert opens behind other apps.
- `NSAlert.showsSuppressionButton` gives you a free "Don't warn me again" checkbox. Store its result in UserDefaults.
