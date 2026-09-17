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

/// Someone else using a shortcut: macOS, or a window manager Carbon can't see. `unbind` is set when Dex can remove it.
struct Conflict {
    let owner: String
    let actions: [String]
    let unbind: (() -> Bool)?
}

/// "command:default.name.leftThird" / "firstThird" → "Left Third"
func pretty(_ name: String) -> String {
    let last = name.split(separator: ".").last.map(String.init) ?? name
    return last.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
}

let magnetID = "com.crowdcafe.windowmagnet"
let magnetKeys = ["horizontalCommands", "verticalCommands"]

func magnetCommands(_ key: String) -> [[String: Any]] {
    guard let data = CFPreferencesCopyAppValue(key as CFString, magnetID as CFString) as? Data else { return [] }
    return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
}

func magnetUses(_ cmd: [String: Any], _ code: UInt32, _ mods: UInt32) -> Bool {
    let k = cmd["keyboardShortcut"] as? [String: Any], s = k?["shortcut"] as? [String: Any]
    return k?["enabled"] as? Bool == true && s?["carbonKeyCode"] as? Int == Int(code) && s?["carbonModifiers"] as? Int == Int(mods)
}

/// Backs up Magnet's settings, quits Magnet, removes the shortcut from matching commands, relaunches Magnet.
func unbindMagnet(_ code: UInt32, _ mods: UInt32) -> Bool {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dex")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    sh("/usr/bin/defaults export \(magnetID) '\(dir.path)/magnet-backup-\(Int(Date().timeIntervalSince1970)).plist'")

    // Magnet only reads its settings at launch
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: magnetID)
    running.forEach { $0.terminate() }
    var waited = 0
    while running.contains(where: { !$0.isTerminated }), waited < 50 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        waited += 1
    }

    for key in magnetKeys {
        var cmds = magnetCommands(key)
        guard !cmds.isEmpty else { continue }
        for i in cmds.indices where magnetUses(cmds[i], code, mods) {
            var k = cmds[i]["keyboardShortcut"] as? [String: Any] ?? [:]
            k.removeValue(forKey: "shortcut")
            cmds[i]["keyboardShortcut"] = k
        }
        if let data = try? JSONSerialization.data(withJSONObject: cmds) {
            CFPreferencesSetAppValue(key as CFString, data as CFData, magnetID as CFString)
        }
    }
    CFPreferencesAppSynchronize(magnetID as CFString)

    if !running.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: magnetID) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    return !magnetKeys.contains { magnetCommands($0).contains { magnetUses($0, code, mods) } }
}

func conflict(_ code: UInt32, _ mods: UInt32) -> Conflict? {
    var arr: Unmanaged<CFArray>?
    if CopySymbolicHotKeys(&arr) == noErr, let list = arr?.takeRetainedValue() as? [[String: Any]], list.contains(where: {
        ($0["kHISymbolicHotKeyEnabled"] as? Bool ?? false) && ($0["kHISymbolicHotKeyCode"] as? Int) == Int(code)
            && UInt32($0["kHISymbolicHotKeyModifiers"] as? Int ?? 0) & modMask == mods
    }) { return Conflict(owner: "macOS", actions: [], unbind: nil) }

    let magnet = magnetKeys.flatMap { magnetCommands($0) }.filter { magnetUses($0, code, mods) }
    if !magnet.isEmpty {
        let names = magnet.compactMap { $0["name"] as? String }.map(pretty)
        return Conflict(owner: "Magnet", actions: names, unbind: { unbindMagnet(code, mods) })
    }

    let rect = "com.knollsoft.Rectangle" as CFString
    let keys = CFPreferencesCopyKeyList(rect, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
    let used = keys.filter {
        guard let d = CFPreferencesCopyAppValue($0 as CFString, rect) as? [String: Any], d["keyCode"] as? Int == Int(code) else { return false }
        return carbonMods(NSEvent.ModifierFlags(rawValue: UInt(d["modifierFlags"] as? Int ?? 0))) == mods
    }
    return used.isEmpty ? nil : Conflict(owner: "Rectangle", actions: used.map(pretty), unbind: nil)
}

enum Resolution { case useIt, pickAnother }

/// Explains the clash and lets the user unbind it in the other app, use it anyway, or pick another shortcut.
func resolve(_ c: Conflict, label: String) -> Resolution {
    let a = NSAlert()
    a.messageText = "\(label) is also used by \(c.owner)"
    let what = c.actions.isEmpty ? "" : "\(c.owner) uses it for: \(c.actions.joined(separator: ", ")).\n"
    let how = switch c.owner {
    case "Magnet": "Unbind removes it from those Magnet commands (Magnet restarts, a backup is saved in ~/Library/Application Support/Dex)."
    case "macOS": "To free it, change it in System Settings → Keyboard → Keyboard Shortcuts."
    default: "To free it, clear it in \(c.owner)'s settings."
    }
    a.informativeText = what + "If both keep it, one key press triggers both.\n\n" + how
    if c.unbind != nil { a.addButton(withTitle: "Unbind in \(c.owner)") }
    a.addButton(withTitle: "Use Anyway")
    a.addButton(withTitle: "Pick Another")
    NSApp.activate(ignoringOtherApps: true)
    let r = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    let choice = c.unbind == nil ? r + 1 : r // 0 unbind, 1 use anyway, 2 pick another
    if choice == 0, let unbind = c.unbind, !unbind() {
        alert("Couldn't unbind it in \(c.owner)", "Clear it in \(c.owner)'s settings, or pick another shortcut.")
        return .pickAnother
    }
    return choice == 2 ? .pickAnother : .useIt
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

// MARK: - Menu bar placement

// On notched MacBooks, status items that don't fit are silently hidden behind the notch.
// It happens whenever the bar gets busier: a Focus / Do Not Disturb icon appearing, or the
// bar re-laying itself out after wake. macOS gives no event for it, so Dex checks its own spot.
let statusAutosave = "dex"
let positionKey = "NSStatusItem Preferred Position \(statusAutosave)"

/// Creates the icon. With no saved spot yet (or when rescuing it), it asks for the slot right
/// next to the system icons: the last place to disappear behind the notch.
func makeStatusItem(nearClock: Bool) -> NSStatusItem {
    if nearClock || defaults.object(forKey: positionKey) == nil { defaults.set(1.0, forKey: positionKey) }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.autosaveName = statusAutosave // remembers where you ⌘-drag it
    item.isVisible = true
    return item
}

/// True when the icon's window sits under the notch or off the screen.
func isHidden(_ item: NSStatusItem) -> Bool {
    guard let window = item.button?.window, let screen = window.screen ?? NSScreen.screens.first else { return true }
    let f = window.frame, s = screen.frame
    if f.maxX <= s.minX || f.minX >= s.maxX || !window.isVisible { return true }
    guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return false } // no notch
    return f.midX > s.minX + left.width && f.midX < s.maxX - right.width
}

// MARK: - App

final class Dex: NSObject, NSApplicationDelegate {
    var item = makeStatusItem(nearClock: false)
    let stateItem = NSMenuItem(title: "", action: #selector(toggleFromMenu), keyEquivalent: "")
    let hotKeyItem = NSMenuItem(title: "", action: #selector(changeHotKey), keyEquivalent: "")
    let safeBox = NSButton(checkboxWithTitle: "Auto-Disable when", target: nil, action: #selector(toggleSafeMode))
    lazy var batteryPill = pill("Battery at or below this (on battery). Click to change.", self, #selector(editBattery))
    lazy var tempPill = pill("Chip temperature at or above this. Click to change.", self, #selector(editTemp))
    var awake = false
    var safeTimer: Timer?
    var lastRescue = Date.distantPast

    func applicationDidFinishLaunching(_: Notification) {
        _ = setSleepDisabled(false) // clear any leftover state from a crash
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        defaults.register(defaults: ["code": 2, "mods": Int(controlKey | optionKey), "label": "⌃⌥D",
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
        watchPlacement()

        onHotKey = { [weak self] in self?.toggle() }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in onHotKey(); return noErr }, 1, &spec, nil, nil)
        let code = UInt32(defaults.integer(forKey: "code")), mods = UInt32(defaults.integer(forKey: "mods"))
        let label = defaults.string(forKey: "label")!
        refresh()
        if !registerHotKey(code, mods) {
            alert("Hotkey \(label) isn't working", "Another app has it. Pick a new one.")
            changeHotKey()
        } else if let c = conflict(code, mods), !defaults.bool(forKey: "allowed-\(code)-\(mods)") {
            if resolve(c, label: label) == .pickAnother { changeHotKey() } else { rememberAllowed(code, mods) }
        }
    }

    /// Re-checks the icon after wake, screen changes, and once a minute (Focus / DND has no event).
    func watchPlacement() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(self, selector: #selector(placementChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(placementChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.rescueIfHidden() }
    }

    /// The bar re-lays itself out for a few seconds after wake, so look once it has settled.
    @objc func placementChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.rescueIfHidden() }
    }

    /// Hidden behind the notch: re-add the icon next to the system icons. At most every 5 minutes,
    /// so Dex never ends up fighting another app over the same spot.
    func rescueIfHidden() {
        guard isHidden(item), Date().timeIntervalSince(lastRescue) > 300 else { return }
        lastRescue = Date()
        let menu = item.menu
        NSStatusBar.system.removeStatusItem(item)
        item = makeStatusItem(nearClock: true)
        item.menu = menu
        refresh()
        NSLog("Dex: menu bar icon was hidden (notch or full menu bar), moved it next to the system icons")
    }

    /// After "Use Anyway": don't ask about this clash again at every launch.
    func rememberAllowed(_ code: UInt32, _ mods: UInt32) {
        if conflict(code, mods) != nil { defaults.set(true, forKey: "allowed-\(code)-\(mods)") }
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

        if let c = conflict(p.code, p.mods) {
            guard resolve(c, label: p.label) == .useIt else { return changeHotKey() }
            rememberAllowed(p.code, p.mods)
        }
        guard registerHotKey(p.code, p.mods) else {
            _ = registerHotKey(UInt32(defaults.integer(forKey: "code")), UInt32(defaults.integer(forKey: "mods")))
            alert("\(p.label) is already taken by another app.", "Keeping \(defaults.string(forKey: "label")!). Pick a different one.")
            return changeHotKey()
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
