import Cocoa
import Carbon
import IOKit.ps
import ServiceManagement

let defaults = UserDefaults.standard
let modMask = UInt32(cmdKey | controlKey | optionKey | shiftKey)

func mono(_ size: CGFloat = 13, bold: Bool = false) -> NSFont {
    NSFont(name: bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", size: size)
        ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
}

// MARK: - Sleep control (pmset disablesleep keeps the Mac awake even with the lid closed)

@discardableResult
func sh(_ cmd: String) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

func setSleepDisabled(_ on: Bool) -> Bool {
    sh("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep \(on ? 1 : 0)") == 0
}

// One-time admin prompt: allow admins to run exactly these two pmset commands without a password.
func installSudoRule() -> Bool {
    let tmp = NSTemporaryDirectory() + "dex-sudoers"
    let rule = "%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
    guard (try? rule.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return false }
    let src = """
    do shell script "/usr/sbin/visudo -cf \(tmp) && /usr/bin/install -m 440 -o root -g wheel \(tmp) /etc/sudoers.d/dex" \
    with prompt "Dex needs permission once to keep your Mac awake with the lid closed." with administrator privileges
    """
    var err: NSDictionary?
    NSAppleScript(source: src)?.executeAndReturnError(&err)
    return err == nil
}

// MARK: - Auto-Disable checks: chip temperature and battery

// Private IOHID sensor API (same one the Stats app uses). Apple Silicon exposes chip die temps without root.
@_silgen_name("IOHIDEventSystemClientCreate") func IOHIDEventSystemClientCreate(_: CFAllocator?) -> Unmanaged<AnyObject>
@_silgen_name("IOHIDEventSystemClientSetMatching") func IOHIDEventSystemClientSetMatching(_: AnyObject, _: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") func IOHIDEventSystemClientCopyServices(_: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty") func IOHIDServiceClientCopyProperty(_: AnyObject, _: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent") func IOHIDServiceClientCopyEvent(_: AnyObject, _: Int64, _: Int32, _: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue") func IOHIDEventGetFloatValue(_: AnyObject, _: Int32) -> Double

/// Hottest chip die sensor in °C, or nil if the Mac doesn't expose them (Intel).
func chipTemp() -> Double? {
    let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault).takeRetainedValue()
    _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
    let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] ?? []
    return services.compactMap { s -> Double? in
        guard (IOHIDServiceClientCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String)?.contains("tdie") == true,
              let e = IOHIDServiceClientCopyEvent(s, 15, 0, 0)?.takeRetainedValue() else { return nil }
        return IOHIDEventGetFloatValue(e, 15 << 16)
    }.max()
}

func batteryPercent() -> Int? {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    guard IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String == kIOPSBatteryPowerValue else { return nil }
    for ps in IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef] {
        if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
           let pct = d[kIOPSCurrentCapacityKey] as? Int { return pct }
    }
    return nil
}

func unsafeReason() -> String? {
    let maxTemp = defaults.integer(forKey: "tempMax"), minBattery = defaults.integer(forKey: "batteryMin")
    if let t = chipTemp() {
        if Int(t) >= maxTemp { return "the chip is at \(Int(t))°C" }
    } else if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
        return "your Mac is getting too hot"
    }
    if let pct = batteryPercent(), pct <= minBattery { return "the battery is at \(pct)%" }
    return nil
}

// MARK: - Global hotkey (Carbon: no Accessibility permission needed)

var hotKeyRef: EventHotKeyRef?
var onHotKey: () -> Void = {}

func registerHotKey(_ code: UInt32, _ mods: UInt32) -> Bool {
    if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
    let id = EventHotKeyID(signature: OSType(0x4445_5831), id: 1) // "DEX1"
    return RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
}

func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
    (f.contains(.command) ? UInt32(cmdKey) : 0) | (f.contains(.control) ? UInt32(controlKey) : 0)
        | (f.contains(.option) ? UInt32(optionKey) : 0) | (f.contains(.shift) ? UInt32(shiftKey) : 0)
}

/// Who already uses this shortcut: macOS, or a window manager that Carbon can't see (Magnet, Rectangle).
func shortcutOwner(_ code: UInt32, _ mods: UInt32) -> String? {
    var arr: Unmanaged<CFArray>?
    if CopySymbolicHotKeys(&arr) == noErr, let list = arr?.takeRetainedValue() as? [[String: Any]], list.contains(where: {
        ($0["kHISymbolicHotKeyEnabled"] as? Bool ?? false) && ($0["kHISymbolicHotKeyCode"] as? Int) == Int(code)
            && UInt32($0["kHISymbolicHotKeyModifiers"] as? Int ?? 0) & modMask == mods
    }) { return "macOS" }

    for key in ["horizontalCommands", "verticalCommands"] {
        guard let data = CFPreferencesCopyAppValue(key as CFString, "com.crowdcafe.windowmagnet" as CFString) as? Data,
              let cmds = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
        if cmds.contains(where: {
            let k = $0["keyboardShortcut"] as? [String: Any], s = k?["shortcut"] as? [String: Any]
            return k?["enabled"] as? Bool == true && s?["carbonKeyCode"] as? Int == Int(code) && s?["carbonModifiers"] as? Int == Int(mods)
        }) { return "Magnet" }
    }

    let rect = "com.knollsoft.Rectangle" as CFString
    let keys = CFPreferencesCopyKeyList(rect, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
    if keys.contains(where: {
        guard let d = CFPreferencesCopyAppValue($0 as CFString, rect) as? [String: Any], d["keyCode"] as? Int == Int(code) else { return false }
        return carbonMods(NSEvent.ModifierFlags(rawValue: UInt(d["modifierFlags"] as? Int ?? 0))) == mods
    }) { return "Rectangle" }
    return nil
}

func label(_ e: NSEvent) -> String {
    let f = e.modifierFlags
    let key = e.keyCode == 49 ? "Space" : (e.charactersIgnoringModifiers ?? "?").uppercased()
    return (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "")
        + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "") + key
}

// MARK: - Dialogs

func alert(_ title: String, _ text: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    NSApp.activate(ignoringOtherApps: true)
    a.runModal()
}

/// Warning with "Don't warn me again". Returns true if the user confirmed (or muted it earlier).
func confirm(_ title: String, _ text: String, ok: String, muteKey: String) -> Bool {
    if defaults.bool(forKey: muteKey) { return true }
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.showsSuppressionButton = true
    a.suppressionButton?.title = "Don't warn me again"
    a.addButton(withTitle: ok)
    a.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    guard a.runModal() == .alertFirstButtonReturn else { return false }
    if a.suppressionButton?.state == .on { defaults.set(true, forKey: muteKey) }
    return true
}

func askNumber(_ title: String, _ text: String, key: String, range: ClosedRange<Int>) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = "\(text) (\(range.lowerBound)–\(range.upperBound))"
    let field = NSTextField(string: "\(defaults.integer(forKey: key))")
    field.font = mono()
    field.frame = NSRect(x: 0, y: 0, width: 80, height: 24)
    a.accessoryView = field
    a.window.initialFirstResponder = field
    a.addButton(withTitle: "Save")
    a.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    guard a.runModal() == .alertFirstButtonReturn else { return }
    guard let v = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), range.contains(v) else { return NSSound.beep() }
    defaults.set(v, forKey: key)
}

// MARK: - Icons

/// Menu bar: lightning bolt in a ring. Idle = thin template (white on dark bar), running = thicker green.
func icon(running: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
        let w: CGFloat = running ? 2 : 1.2
        (running ? NSColor.systemGreen : NSColor.white).setStroke()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: w / 2 + 0.5, dy: w / 2 + 0.5))
        ring.lineWidth = w
        ring.stroke()
        let bolt = NSBezierPath()
        bolt.move(to: NSPoint(x: 10, y: 14))
        for (x, y) in [(6.0, 8.5), (9, 8.5), (8, 4), (12, 9.5), (9, 9.5)] { bolt.line(to: NSPoint(x: x, y: y)) }
        bolt.close()
        bolt.lineWidth = w
        bolt.lineJoinStyle = .round
        bolt.stroke()
        return true
    }
    img.isTemplate = !running
    return img
}

func linkButton(_ title: String, image: NSImage?, tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let b = NSButton(title: title, image: image ?? NSImage(), target: target, action: action)
    if image == nil { b.image = nil }
    b.isBordered = false
    b.font = mono(12)
    b.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    b.contentTintColor = .secondaryLabelColor
    b.toolTip = tip
    return b
}

func pill(_ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let b = NSButton(title: "", target: target, action: action)
    b.bezelStyle = .inline
    b.font = mono(11)
    b.toolTip = tip
    return b
}

func rowItem(_ views: [NSView], tip: String) -> NSMenuItem {
    let stack = NSStackView(views: views)
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
    stack.frame.size = stack.fittingSize
    stack.toolTip = tip
    let item = NSMenuItem()
    item.view = stack
    item.toolTip = tip
    return item
}

// MARK: - App

final class Dex: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let stateItem = NSMenuItem(title: "", action: #selector(toggleFromMenu), keyEquivalent: "")
    let hotKeyItem = NSMenuItem(title: "", action: #selector(changeHotKey), keyEquivalent: "")
    let safeBox = NSButton(checkboxWithTitle: "Auto-Disable when", target: nil, action: #selector(toggleSafeMode))
    lazy var batteryPill = pill("Battery at or below this (on battery). Click to change.", self, #selector(editBattery))
    lazy var tempPill = pill("Chip temperature at or above this. Click to change.", self, #selector(editTemp))
    var awake = false
    var safeTimer: Timer?

    func applicationDidFinishLaunching(_: Notification) {
        _ = setSleepDisabled(false) // clear any leftover state from a crash
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        defaults.register(defaults: ["code": 2, "mods": Int(cmdKey | controlKey | optionKey), "label": "⌃⌥⌘D",
                                     "safeMode": true, "batteryMin": 15, "tempMax": 80])

        let safeTip = "Auto-Disable turns Dex off by itself when the chip gets too hot, or when the Mac is on battery "
            + "and drops too low. Keeps a closed laptop from overheating or draining flat. Click the values to change them."
        safeBox.target = self
        safeBox.font = mono()
        safeBox.toolTip = safeTip

        let menu = NSMenu()
        stateItem.target = self
        stateItem.toolTip = "Click or press the hotkey to switch"
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(rowItem([safeBox, batteryPill, tempPill], tip: safeTip))
        hotKeyItem.target = self
        menu.addItem(hotKeyItem)
        menu.addItem(.separator())
        let gh = NSImage(contentsOfFile: Bundle.main.path(forResource: "github", ofType: "png") ?? "")
        gh?.size = NSSize(width: 14, height: 14)
        gh?.isTemplate = true
        let coffee = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: "Coffee")
        let author = NSTextField(labelWithString: "by Daniel Trifunovic")
        author.font = mono(12)
        author.textColor = .secondaryLabelColor
        menu.addItem(rowItem([
            author,
            linkButton("", image: gh, tip: "github.com/gigacook", self, #selector(openGitHub)),
            linkButton("Support Dex", image: coffee, tip: "Buy me a coffee on Ko-fi", self, #selector(openKofi)),
        ], tip: "Malo periculosam libertatem quam quietum servitium"))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "", action: #selector(NSApp.terminate), keyEquivalent: "q")
        quit.attributedTitle = NSAttributedString(string: "Quit Dex", attributes: [.font: mono()])
        menu.addItem(quit)
        item.menu = menu

        onHotKey = { [weak self] in self?.toggle() }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in onHotKey(); return noErr }, 1, &spec, nil, nil)
        let code = UInt32(defaults.integer(forKey: "code")), mods = UInt32(defaults.integer(forKey: "mods"))
        let label = defaults.string(forKey: "label")!
        if !registerHotKey(code, mods) {
            alert("Hotkey \(label) isn't working", "Another app has it. Open the Dex menu to pick a new one.")
        } else if let owner = shortcutOwner(code, mods) {
            alert("\(owner) also uses \(label)", "Both will react when you press it. Change it in \(owner), or pick a new one in the Dex menu.")
        }
        refresh()
    }

    func applicationWillTerminate(_: Notification) { _ = setSleepDisabled(false) }

    func refresh() {
        item.button?.image = icon(running: awake)
        stateItem.attributedTitle = NSAttributedString(string: "DEX — ", attributes: [.font: mono(13, bold: true)])
            + NSAttributedString(string: awake ? "ACTIVE" : "INACTIVE", attributes: [
                .font: mono(13, bold: true), .foregroundColor: awake ? NSColor.systemGreen : NSColor.secondaryLabelColor,
            ])
        let safe = defaults.bool(forKey: "safeMode")
        safeBox.state = safe ? .on : .off
        batteryPill.title = "≤\(defaults.integer(forKey: "batteryMin"))%"
        tempPill.title = "≥\(defaults.integer(forKey: "tempMax"))°C"
        [batteryPill, tempPill].forEach { $0.isEnabled = safe }
        hotKeyItem.attributedTitle = NSAttributedString(
            string: "Hot Key: \(defaults.string(forKey: "label")!)  (click to change)", attributes: [.font: mono()])

        // Check every 30 s while keeping the Mac awake with Auto-Disable on
        let watch = awake && safe
        if watch, safeTimer == nil {
            safeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.safetyCheck() }
        } else if !watch {
            safeTimer?.invalidate()
            safeTimer = nil
        }
    }

    func setAwake(_ want: Bool) -> Bool {
        guard setSleepDisabled(want) || (installSudoRule() && setSleepDisabled(want)) else { return false }
        awake = want
        refresh()
        return true
    }

    func safetyCheck() {
        guard awake, defaults.bool(forKey: "safeMode"), let reason = unsafeReason(), setAwake(false) else { return }
        alert("Auto-Disable turned Dex off", "Your Mac can sleep normally again because \(reason).")
    }

    func toggle() {
        guard !awake else { _ = setAwake(false); return }
        if defaults.bool(forKey: "safeMode"), let reason = unsafeReason() {
            return alert("Dex can't turn on right now", "Auto-Disable is on and \(reason).")
        }
        guard confirm("Dex keeps your Mac awake, even with the lid closed",
                      "Don't leave it closed in a bag or tight space for long. It can overheat.",
                      ok: "Keep Awake", muteKey: "noHeatWarning") else { return }
        _ = setAwake(true)
    }

    /// Controls inside menu rows: close the menu first so dialogs don't fight menu tracking.
    func afterMenu(_ work: @escaping () -> Void) {
        item.menu?.cancelTracking()
        DispatchQueue.main.async(execute: work)
    }

    @objc func toggleFromMenu() { toggle() }

    @objc func toggleSafeMode() {
        guard defaults.bool(forKey: "safeMode") else {
            defaults.set(true, forKey: "safeMode")
            refresh()
            return afterMenu { self.safetyCheck() }
        }
        afterMenu {
            if confirm("Turn off Auto-Disable?",
                       "Dex will no longer switch itself off when your Mac gets too hot or the battery runs low. "
                           + "A closed laptop could overheat or drain completely.",
                       ok: "Turn Off", muteKey: "noSafeOffWarning") {
                defaults.set(false, forKey: "safeMode")
            }
            self.refresh()
        }
    }

    @objc func editBattery() {
        afterMenu {
            askNumber("Auto-Disable at battery level", "Turn Dex off when on battery and at or below this %.",
                      key: "batteryMin", range: 5...90)
            self.refresh()
            self.safetyCheck()
        }
    }

    @objc func editTemp() {
        afterMenu {
            askNumber("Auto-Disable at chip temperature", "Turn Dex off when the chip reaches this °C.",
                      key: "tempMax", range: 50...105)
            self.refresh()
            self.safetyCheck()
        }
    }

    @objc func openGitHub() { afterMenu { NSWorkspace.shared.open(URL(string: "https://www.github.com/gigacook")!) } }
    @objc func openKofi() { afterMenu { NSWorkspace.shared.open(URL(string: "https://ko-fi.com/gigacook")!) } }

    @objc func changeHotKey() {
        let a = NSAlert()
        a.messageText = "Press a new shortcut"
        a.informativeText = "Current: \(defaults.string(forKey: "label")!)\nUse ⌘, ⌃ or ⌥ plus a key. Esc cancels."
        a.addButton(withTitle: "Cancel")
        var picked: (code: UInt32, mods: UInt32, label: String)?
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { NSApp.abortModal(); return nil }
            let m = carbonMods(e.modifierFlags)
            guard m & UInt32(cmdKey | controlKey | optionKey) != 0 else { NSSound.beep(); return nil }
            picked = (UInt32(e.keyCode), m, label(e))
            NSApp.stopModal()
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
        guard let p = picked else { return }

        let oldCode = UInt32(defaults.integer(forKey: "code")), oldMods = UInt32(defaults.integer(forKey: "mods"))
        var problem: String?
        if let owner = shortcutOwner(p.code, p.mods) {
            problem = "\(p.label) is used by \(owner)."
        } else if !registerHotKey(p.code, p.mods) {
            problem = "\(p.label) is already taken by another app."
        }
        if let problem {
            _ = registerHotKey(oldCode, oldMods)
            return alert(problem, "Keeping \(defaults.string(forKey: "label")!). Pick a different one.")
        }
        defaults.set(Int(p.code), forKey: "code")
        defaults.set(Int(p.mods), forKey: "mods")
        defaults.set(p.label, forKey: "label")
        refresh()
    }
}

func + (a: NSAttributedString, b: NSAttributedString) -> NSAttributedString {
    let m = NSMutableAttributedString(attributedString: a)
    m.append(b)
    return m
}

let app = NSApplication.shared
let delegate = Dex()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
