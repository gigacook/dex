---
name: carbon-hotkeys
description: Register a global keyboard shortcut in a macOS app without Accessibility permission (RegisterEventHotKey), record a new one, and detect conflicts with system shortcuts (CopySymbolicHotKeys).
---

# Carbon hotkeys

**Solved in Dex:** ⌃⌥D toggles from anywhere. The user can rebind it, and gets a warning if macOS or another app already uses the combo.

**When:** any background or menu bar app that needs a global shortcut.

## Example
```swift
import Carbon
var hotKeyRef: EventHotKeyRef?
var onHotKey: () -> Void = {}                       // global: C callbacks can't capture

var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in onHotKey(); return noErr }, 1, &spec, nil, nil)

let id = EventHotKeyID(signature: OSType(0x44455831), id: 1)
let ok = RegisterEventHotKey(2 /* D */, UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr

// system conflict check
var arr: Unmanaged<CFArray>?
CopySymbolicHotKeys(&arr)
let list = arr!.takeRetainedValue() as! [[String: Any]]
// keys: "kHISymbolicHotKeyCode", "kHISymbolicHotKeyModifiers", "kHISymbolicHotKeyEnabled"
```
Recording: `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` while an NSAlert runs modally. Take `e.keyCode` and the modifiers, then call `NSApp.stopModal()`. Esc (keyCode 53) calls `NSApp.abortModal()`.

## Critical considerations
- Carbon modifier values ≠ NSEvent flags. Convert: cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096.
- Mask system modifiers with `cmd|ctrl|opt|shift` before comparing. They contain extra bits.
- `RegisterEventHotKey` only fails (`eventHotKeyExistsErr`) if **another app registered the same combo the same way**. It can't see other apps' menu shortcuts. Warn on what you can detect and don't promise more.
- Require at least one of ⌘/⌃/⌥, or you'll hijack plain typing.
- On a failed rebind, re-register the old hotkey. Unregistering first leaves you with none.
- Save keyCode + modifiers + a display label (`charactersIgnoringModifiers`) in UserDefaults. Translating keyCode back to a character is heavy (`UCKeyTranslate`), so skip it.
- `NSApp.activate(ignoringOtherApps:)` before the alert, or a background app's dialog won't get keyboard focus.
