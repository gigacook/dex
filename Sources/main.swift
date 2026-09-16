import Cocoa
import Carbon
import IOKit.ps
import ServiceManagement

let defaults = UserDefaults.standard
let modMask = UInt32(cmdKey | controlKey | optionKey | shiftKey)
let lowBattery = 15

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

// MARK: - Safe mode checks: too hot, or on battery and low

func unsafeReason() -> String? {
    if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
        return "your Mac is getting too hot"
    }
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    guard IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String == kIOPSBatteryPowerValue else { return nil }
    for ps in IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef] {
        if let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
           let pct = d[kIOPSCurrentCapacityKey] as? Int, pct <= lowBattery {
            return "the battery is at \(pct)%"
        }
    }
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

func isSystemShortcut(_ code: UInt32, _ mods: UInt32) -> Bool {
    var arr: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&arr) == noErr,
          let list = arr?.takeRetainedValue() as? [[String: Any]] else { return false }
    return list.contains {
        ($0["kHISymbolicHotKeyEnabled"] as? Bool ?? false)
            && ($0["kHISymbolicHotKeyCode"] as? Int).map(UInt32.init) == code
            && (($0["kHISymbolicHotKeyModifiers"] as? Int).map(UInt32.init) ?? 0) & modMask == mods
    }
}

func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
    (f.contains(.command) ? UInt32(cmdKey) : 0) | (f.contains(.control) ? UInt32(controlKey) : 0)
        | (f.contains(.option) ? UInt32(optionKey) : 0) | (f.contains(.shift) ? UInt32(shiftKey) : 0)
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

// MARK: - Icon: lightning bolt in a ring. Idle = thin template (white on dark bar), running = thicker green.

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

// MARK: - App

final class Dex: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let hotKeyItem = NSMenuItem(title: "", action: #selector(changeHotKey), keyEquivalent: "")
    let safeItem = NSMenuItem(title: "Safe Mode", action: #selector(toggleSafeMode), keyEquivalent: "")
    var awake = false
    var safeTimer: Timer?

    func applicationDidFinishLaunching(_: Notification) {
        _ = setSleepDisabled(false) // clear any leftover state from a crash
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        defaults.register(defaults: ["code": 2, "mods": Int(controlKey | optionKey), "label": "⌃⌥D", "safeMode": true])

        let menu = NSMenu()
        for t in ["Dex by Daniel Trifunovic", "2026-09-16", "Malo periculosam libertatem quam quietum servitium"] {
            menu.addItem(withTitle: t, action: nil, keyEquivalent: "")
        }
        menu.addItem(withTitle: "github.com/gigacook", action: #selector(openGitHub), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Support Dex on Ko-fi ☕", action: #selector(openKofi), keyEquivalent: "").target = self
        menu.addItem(.separator())
        safeItem.target = self
        safeItem.toolTip = "Turns Dex off by itself if your Mac gets too hot, or if it's on battery "
            + "and drops to \(lowBattery)%. Keeps a closed laptop from overheating or draining flat."
        menu.addItem(safeItem)
        hotKeyItem.target = self
        menu.addItem(hotKeyItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dex", action: #selector(NSApp.terminate), keyEquivalent: "q")
        item.menu = menu

        onHotKey = { [weak self] in self?.toggle() }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in onHotKey(); return noErr }, 1, &spec, nil, nil)
        _ = registerHotKey(UInt32(defaults.integer(forKey: "code")), UInt32(defaults.integer(forKey: "mods")))
        refresh()
    }

    func applicationWillTerminate(_: Notification) { _ = setSleepDisabled(false) }

    func refresh() {
        item.button?.image = icon(running: awake)
        safeItem.state = defaults.bool(forKey: "safeMode") ? .on : .off
        hotKeyItem.title = "Hotkey: \(defaults.string(forKey: "label")!)  (click to change)"
        // Check every 30 s while keeping the Mac awake with safe mode on
        let watch = awake && defaults.bool(forKey: "safeMode")
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
        alert("Safe Mode turned Dex off", "Your Mac can sleep normally again because \(reason).")
    }

    func toggle() {
        guard !awake else { _ = setAwake(false); return }
        if defaults.bool(forKey: "safeMode"), let reason = unsafeReason() {
            return alert("Dex can't turn on right now", "Safe Mode is on and \(reason).")
        }
        guard confirm("Dex keeps your Mac awake, even with the lid closed",
                      "Don't leave it closed in a bag or tight space for long. It can overheat.",
                      ok: "Keep Awake", muteKey: "noHeatWarning") else { return }
        _ = setAwake(true)
    }

    @objc func toggleSafeMode() {
        let on = defaults.bool(forKey: "safeMode")
        if on {
            guard confirm("Turn off Safe Mode?",
                          "Dex will no longer switch itself off when your Mac gets too hot or the battery runs low. "
                              + "A closed laptop could overheat or drain completely.",
                          ok: "Turn Off", muteKey: "noSafeOffWarning") else { return }
        }
        defaults.set(!on, forKey: "safeMode")
        refresh()
        safetyCheck()
    }

    @objc func openGitHub() { NSWorkspace.shared.open(URL(string: "https://www.github.com/gigacook")!) }
    @objc func openKofi() { NSWorkspace.shared.open(URL(string: "https://ko-fi.com/gigacook")!) }

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
        if isSystemShortcut(p.code, p.mods) {
            problem = "\(p.label) is used by macOS."
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

let app = NSApplication.shared
let delegate = Dex()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
