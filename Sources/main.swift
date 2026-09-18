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

var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
var onHotKey: (UInt32) -> Void = { _ in }

/// id 1 = keep awake, 2 = memory hogs (M), 3 = sweep build slop (K).
func registerHotKey(_ code: UInt32, _ mods: UInt32, id hotKeyID: UInt32 = 1) -> Bool {
    if let r = hotKeyRefs[hotKeyID] { UnregisterEventHotKey(r); hotKeyRefs[hotKeyID] = nil }
    let id = EventHotKeyID(signature: OSType(0x4445_5831), id: hotKeyID) // "DEX1"
    var ref: EventHotKeyRef?
    guard RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref) == noErr else { return false }
    hotKeyRefs[hotKeyID] = ref
    return true
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

// MARK: - Processes (memory hogs, build slop)

struct Proc {
    let pid: Int32, ppid: Int32, uid: UInt32, cpu: Double, mem: Double, rssMB: Double, tty: String, path: String, args: String
    var name: String { (path as NSString).lastPathComponent }
}

struct Slop {
    let pid: Int32, name: String, reason: String, rssMB: Double
}

func out(_ tool: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// `ps` twice: both `comm` and `args` can contain spaces, so each needs to be the last column.
func processes() -> [Proc] {
    var argsByPID: [Int32: String] = [:]
    for line in out("/bin/ps", ["-axww", "-o", "pid=,args="]).split(separator: "\n") {
        let t = line.drop { $0 == " " }
        guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]) else { continue }
        argsByPID[pid] = String(t[sp...].drop { $0 == " " })
    }
    return out("/bin/ps", ["-axo", "pid=,ppid=,uid=,pcpu=,pmem=,rss=,tty=,comm="]).split(separator: "\n").compactMap { line in
        let f = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
        guard f.count == 8, let pid = Int32(f[0]), let ppid = Int32(f[1]), let uid = UInt32(f[2]),
              let cpu = Double(f[3]), let mem = Double(f[4]), let rss = Double(f[5]) else { return nil }
        return Proc(pid: pid, ppid: ppid, uid: uid, cpu: cpu, mem: mem, rssMB: rss / 1024, tty: String(f[6]),
                    path: String(f[7]).trimmingCharacters(in: .whitespaces),
                    args: argsByPID[pid] ?? String(f[7]).trimmingCharacters(in: .whitespaces))
    }
}

func memoryHogs(threshold: Double = 1.0) -> [Proc] {
    processes().filter { $0.mem >= threshold }.sorted { $0.mem > $1.mem }
}

/// The hogs it is safe to put behind a single keypress: yours, and not something the login
/// session rests on. Ending WindowServer or loginwindow logs you out; the old dialog made you
/// type the PID, which was guard enough, but a numbered End button is not.
func endableHogs() -> [Proc] {
    let uid = getuid(), me = getpid()
    return memoryHogs().filter { $0.uid == uid && $0.pid != me && !["loginwindow", "Dex"].contains($0.name) }
}

/// SIGTERM (or SIGHUP for a shell), then SIGKILL if it is still there a moment later.
@discardableResult
func endProcess(_ pid: Int32, hangup: Bool = false) -> Bool {
    guard pid > 1, kill(pid, 0) == 0 else { return false }
    kill(pid, hangup ? SIGHUP : SIGTERM)
    for _ in 0..<12 {
        usleep(100_000)
        if kill(pid, 0) != 0 { return true }
    }
    kill(pid, SIGKILL)
    usleep(150_000)
    return kill(pid, 0) != 0
}

/// Leftovers from building: dev servers, automation browsers, idle terminals, orphaned build tools.
func buildSlop() -> [Slop] {
    let all = processes()
    let me = getpid(), uid = getuid()
    var parents: [Int32: Proc] = [:], childCount: [Int32: Int] = [:]
    for p in all { parents[p.pid] = p; childCount[p.ppid, default: 0] += 1 }
    var safe: Set<Int32> = [me]           // never touch Dex or whatever launched it
    var walk = parents[me]?.ppid
    while let pid = walk, pid > 1, !safe.contains(pid) { safe.insert(pid); walk = parents[pid]?.ppid }

    let listening = Set(out("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fp"]).split(separator: "\n")
        .compactMap { $0.hasPrefix("p") ? Int32($0.dropFirst()) : nil })
    let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "-sh"]
    let keep: Set<String> = ["claude", "Claude", "login", "launchd", "Terminal", "iTerm2", "ssh", "sshd", "Dex"]
    let runtimes: Set<String> = ["node", "ruby", "php", "deno", "bun", "perl"]
    let builders: Set<String> = ["swift-frontend", "swift-build", "swift-driver", "clang", "esbuild", "tsc", "sourcekit-lsp", "clangd"]
    let servers = ["http.server", "uvicorn", "gunicorn", "flask", "runserver", "streamlit", "jupyter", "vite",
                   "next dev", "webpack serve", "webpack-dev-server", "http-server", "live-server", "php -S",
                   "hugo server", "jekyll serve", "rails server", "nodemon"]
    let robots = ["--headless", "--enable-automation", "ms-playwright", "puppeteer", "chromedriver", "geckodriver", "safaridriver"]

    func idleMinutes(_ tty: String) -> Double? {
        var st = stat()
        guard stat("/dev/" + tty, &st) == 0 else { return nil }
        return (Date().timeIntervalSince1970 - Double(st.st_atimespec.tv_sec)) / 60
    }

    return all.compactMap { p -> Slop? in
        let name = p.name
        guard p.uid == uid, p.pid > 1, !safe.contains(p.pid), !keep.contains(name) else { return nil }
        let bundled = p.path.contains(".app/Contents/") || p.path.hasPrefix("/System/")
        let isPython = name.range(of: #"^[Pp]ython(\d+(\.\d+)?)?$"#, options: .regularExpression) != nil
        let runtime = isPython || runtimes.contains(name)
        var why: String?

        if robots.contains(where: { p.args.contains($0) }) {
            // Only the root of an automation browser; its helpers go down with it.
            if let parent = parents[p.ppid], robots.contains(where: { parent.args.contains($0) }) { return nil }
            why = "automation browser"
        } else if listening.contains(p.pid), !bundled, runtime || servers.contains(where: { p.args.contains($0) }) {
            why = "dev server"
        } else if shells.contains(name), p.tty != "??", childCount[p.pid] == nil,
                  let parent = parents[p.ppid], !["tmux", "screen", "zellij"].contains(parent.name),
                  let idle = idleMinutes(p.tty), idle >= 30 {
            why = "idle terminal \(Int(idle)) min"
        } else if p.ppid == 1, !bundled {
            if builders.contains(name) { why = "orphaned build tool" }
            else if runtime, p.cpu >= 50 || p.rssMB >= 500 { why = "runaway orphan" }
        }
        return why.map { Slop(pid: p.pid, name: name, reason: $0, rssMB: p.rssMB) }
    }
}

// MARK: - Tool sheets (M and K): a dark panel that slides down from the menu bar

/// The green from the app icon — the one accent these sheets use.
let dexGreen = NSColor(srgbRed: 0.31, green: 0.86, blue: 0.47, alpha: 1)
let panelInk = NSColor(white: 1, alpha: 0.85)
let panelDim = NSColor(white: 1, alpha: 0.35)

func panelLabel(_ s: String, _ size: CGFloat, _ color: NSColor, bold: Bool = false) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.font = mono(size, bold: bold)
    t.textColor = color
    t.sizeToFit()
    return t
}

func hairline(_ frame: NSRect) -> NSView {
    let v = NSView(frame: frame)
    v.wantsLayer = true
    v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.09).cgColor
    return v
}

/// Borderless panels refuse key status by default; these sheets live on esc and the number keys.
final class SlidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Top-down coordinates, and it tells the sheet when the pointer arrives or a click lands.
final class PanelBody: NSView {
    var onTouch: (() -> Void)?
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onTouch?() }
    override func mouseDown(with event: NSEvent) { onTouch?() }
}

/// Rows stack downwards inside this.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A flat key cap: the digit you can press, then what pressing it does.
final class KeyButton: NSButton {
    var spent = false {
        didSet {
            isEnabled = !spent
            if spent { layer?.removeAnimation(forKey: "breathe") }
            layer?.backgroundColor = NSColor(white: 1, alpha: spent ? 0.02 : 0.07).cgColor
            layer?.borderColor = NSColor(white: 1, alpha: spent ? 0.06 : 0.14).cgColor
        }
    }

    private let cap: String

    /// `cap` is what you press — a digit, or a hotkey like ⌃⌥M.
    init(cap: String, word: String, minWidth: CGFloat = 0, target: AnyObject, action: Selector) {
        self.cap = cap
        let text = cap + "  " + word
        let fitted = ceil(mono(11).maximumAdvancement.width * CGFloat(text.count)) + 18
        super.init(frame: NSRect(x: 0, y: 0, width: max(minWidth, fitted), height: 21))
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        let t = NSMutableAttributedString(string: cap,
                                          attributes: [.font: mono(11, bold: true), .foregroundColor: dexGreen])
        t.append(NSAttributedString(string: "  " + word,
                                    attributes: [.font: mono(11), .foregroundColor: panelInk]))
        attributedTitle = t
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Re-labels the box without touching its key cap or its width.
    func setWord(_ word: String) {
        let t = NSMutableAttributedString(string: cap,
                                          attributes: [.font: mono(11, bold: true), .foregroundColor: dexGreen])
        t.append(NSAttributedString(string: "  " + word,
                                    attributes: [.font: mono(11), .foregroundColor: panelInk]))
        attributedTitle = t
    }

    /// A slow pulse around the box, so the keys read as live things waiting to be pressed.
    /// Staggered by row, which looks like breathing rather than a blinking row of lights.
    func breathe(delay: Double) {
        let pulse = CABasicAnimation(keyPath: "borderColor")
        pulse.fromValue = NSColor(white: 1, alpha: 0.14).cgColor
        pulse.toValue = dexGreen.withAlphaComponent(0.6).cgColor
        pulse.duration = 1.5
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.beginTime = CACurrentMediaTime() + delay
        layer?.add(pulse, forKey: "breathe")
    }
}

/// The same box the key caps wear, with nothing to press: sweep has already happened, so its
/// rows report a count instead of offering a key.
func capChip(_ cap: String, _ word: String, width: CGFloat, dim: Bool) -> NSView {
    let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 21))
    box.wantsLayer = true
    box.layer?.cornerRadius = 5
    box.layer?.backgroundColor = NSColor(white: 1, alpha: dim ? 0.03 : 0.07).cgColor
    box.layer?.borderWidth = 1
    box.layer?.borderColor = NSColor(white: 1, alpha: dim ? 0.07 : 0.14).cgColor
    let t = NSMutableAttributedString(string: cap, attributes: [
        .font: mono(11, bold: true), .foregroundColor: dim ? panelDim : dexGreen])
    t.append(NSAttributedString(string: "  " + word, attributes: [
        .font: mono(11), .foregroundColor: dim ? panelDim : panelInk]))
    let label = NSTextField(labelWithAttributedString: t)
    label.sizeToFit()
    label.frame.origin = NSPoint(x: (width - label.frame.width) / 2, y: (21 - label.frame.height) / 2)
    box.addSubview(label)
    return box
}

/// Shared chrome: the icon, the lowercase green name beside it, an "esc to close" note top right,
/// and the drop-down/pull-up. Subclasses fill the area below `headerHeight`.
class ToolPanel: NSObject {
    static let headerHeight: CGFloat = 46

    /// Which of the three sheets this is, so a hotkey can tell "close me" from "swap to me".
    enum Kind { case dex, memcheck, sweep }

    let kind: Kind
    let width: CGFloat
    let panel = SlidePanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                           styleMask: [.borderless], backing: .buffered, defer: false)
    let body = PanelBody()
    let note = panelLabel("esc to close", 9.5, panelDim)
    let title: NSTextField
    /// Menus go away when you click past them; the dex sheet is a menu, the other two are not.
    var closeWhenClickedAway = false
    /// Called just before a click-away closes the sheet.
    var onClickedAway: (() -> Void)?
    private var keyMonitor: Any?
    private var resignObserver: Any?
    private(set) var onScreen = false

    init(kind: Kind, name: String, width: CGFloat) {
        self.kind = kind
        self.width = width
        self.title = panelLabel(name, 15, dexGreen, bold: true)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        body.wantsLayer = true
        body.layer?.cornerRadius = 12
        body.layer?.masksToBounds = true
        body.layer?.backgroundColor = NSColor(srgbRed: 0.105, green: 0.105, blue: 0.115, alpha: 1).cgColor
        body.layer?.borderWidth = 1
        body.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        panel.contentView = body

        let icon = NSImageView(frame: NSRect(x: 14, y: 11, width: 23, height: 23))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        body.addSubview(icon)

        title.frame.origin = NSPoint(x: 46, y: 14)
        body.addSubview(title)

        body.addSubview(note)
        placeNote()
        body.addSubview(hairline(NSRect(x: 14, y: Self.headerHeight - 1, width: width - 28, height: 1)))
    }

    /// The note is right-aligned, so it has to be repositioned whenever its text changes length.
    func placeNote() {
        note.sizeToFit()
        note.frame.origin = NSPoint(x: width - 14 - note.frame.width, y: 17)
    }

    // MARK: Showing and hiding

    /// Drops the sheet out from behind the menu bar, hanging off the status item.
    func present(height: CGFloat, anchor: NSRect?) {
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.intersects(a) } }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let wanted = (anchor?.maxX ?? visible.maxX) - width
        let x = min(max(visible.minX + 8, wanted), visible.maxX - width - 8)
        let rest = NSRect(x: x, y: visible.maxY - height - 6, width: width, height: height)

        panel.setFrame(rest.offsetBy(dx: 0, dy: height + 10), display: false)
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        onScreen = true
        installKeys()
        if closeWhenClickedAway {
            // Armed late: the sheet is still taking key focus while it slides in, and an early
            // resign would snap it shut before it had finished appearing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
                guard onScreen, resignObserver == nil else { return }
                resignObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
                        self?.onClickedAway?()
                        self?.dismiss()
                    }
            }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(rest, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() { dismiss(animated: true) }

    /// Slides back up the way it came. Swapping one sheet for another skips the animation, or the
    /// two would slide past each other in the same patch of screen.
    func dismiss(animated: Bool) {
        guard onScreen else { return }
        onScreen = false
        removeKeys()
        guard animated else { return panel.orderOut(nil) }
        let up = panel.frame.offsetBy(dx: 0, dy: panel.frame.height + 10)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(up, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [self] in panel.orderOut(nil) })
    }

    /// Grows or shrinks the sheet with its top edge pinned, so the header never moves.
    func resize(to height: CGFloat, animated: Bool) {
        let f = panel.frame
        let target = NSRect(x: f.minX, y: f.maxY - height, width: width, height: height)
        if animated { panel.animator().setFrame(target, display: true) } else { panel.setFrame(target, display: true) }
    }

    // MARK: Keys

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.onScreen else { return e }
            if e.keyCode == 53 { self.dismiss(); return nil } // esc
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "q" {
                NSApp.terminate(nil)
                return nil
            }
            return self.handle(e) ? nil : e
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// Subclass hook for extra keys. Return true when the key was consumed.
    func handle(_ event: NSEvent) -> Bool { false }

    // MARK: Feedback

    /// A short sideways shake: this page is cleared, here comes the next.
    func shake(then: @escaping () -> Void) {
        let base = panel.frame
        let steps: [CGFloat] = [-7, 6, -4, 3, 0]
        var i = 0
        Timer.scheduledTimer(withTimeInterval: 0.045, repeats: true) { [self] t in
            panel.setFrame(base.offsetBy(dx: steps[i], dy: 0), display: true)
            i += 1
            guard i == steps.count else { return }
            t.invalidate()
            then()
        }
    }

    /// A single wash of colour over the whole sheet.
    func flash(_ color: NSColor) {
        let v = NSView(frame: body.bounds)
        v.wantsLayer = true
        v.layer?.backgroundColor = color.withAlphaComponent(0.26).cgColor
        body.addSubview(v)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.34
            v.animator().alphaValue = 0
        }, completionHandler: { v.removeFromSuperview() })
    }

    /// The closing exhale: green swells once and fades, then the sheet leaves.
    func breatheOutAndClose() {
        let v = NSView(frame: body.bounds)
        v.wantsLayer = true
        v.layer?.backgroundColor = dexGreen.withAlphaComponent(0).cgColor
        body.addSubview(v)
        let breath = CABasicAnimation(keyPath: "backgroundColor")
        breath.fromValue = dexGreen.withAlphaComponent(0).cgColor
        breath.toValue = dexGreen.withAlphaComponent(0.32).cgColor
        breath.duration = 0.34
        breath.autoreverses = true
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        v.layer?.add(breath, forKey: "breath")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) { [self] in
            v.removeFromSuperview()
            dismiss()
        }
    }
}

// MARK: memcheck (M)

/// Four hogs at a time, each with an End button on keys 1–4. Clear all four and the next four
/// slide up from under; clear the last of them and the sheet breathes green and leaves.
final class MemcheckPanel: ToolPanel {
    private static let rowHeight: CGFloat = 28
    private static let contentTop = ToolPanel.headerHeight + 20
    private static let perPage = 4

    private var remaining: [Proc]
    private var page: [Proc] = []
    private var buttons: [KeyButton] = []
    private var ended: Set<Int> = []
    private var turning = false
    private let rowsHost = FlippedView()

    init(hogs: [Proc]) {
        remaining = hogs
        super.init(kind: .memcheck, name: "memcheck", width: 430)

        // Same size as the rows, or the monospaced columns would not line up under it.
        let columns = panelLabel("   PID    %MEM      RSS     NAME", 11, panelDim)
        columns.frame.origin = NSPoint(x: 86, y: ToolPanel.headerHeight + 3)
        body.addSubview(columns)
        body.addSubview(rowsHost)
    }

    func show(anchor: NSRect?) {
        layoutPage()
        present(height: height(for: page.count), anchor: anchor)
    }

    private func height(for rows: Int) -> CGFloat {
        Self.contentTop + CGFloat(rows) * Self.rowHeight + 12
    }

    // MARK: Pages

    private func layoutPage(slidingUp: Bool = false) {
        page = Array(remaining.prefix(Self.perPage))
        ended = []
        rowsHost.subviews.forEach { $0.removeFromSuperview() }
        buttons = []

        for (i, p) in page.enumerated() {
            let row = NSView(frame: NSRect(x: 0, y: CGFloat(i) * Self.rowHeight,
                                           width: width, height: Self.rowHeight))
            let button = KeyButton(cap: "\(i + 1)", word: "End", minWidth: 64,
                                   target: self, action: #selector(endTapped(_:)))
            button.tag = i
            button.frame.origin = NSPoint(x: 14, y: 3)
            button.breathe(delay: Double(i) * 0.18)
            row.addSubview(button)
            buttons.append(button)

            let name = p.name.count > 22 ? p.name.prefix(21) + "\u{2026}" : p.name[...]
            let text = panelLabel(String(format: "%6d  %5.1f%%  %7.0f MB  %@",
                                         p.pid, p.mem, p.rssMB, String(name)), 11, panelInk)
            text.frame.origin = NSPoint(x: 86, y: 7)
            row.addSubview(text)
            rowsHost.addSubview(row)
        }

        let rowsHeight = CGFloat(page.count) * Self.rowHeight
        rowsHost.frame = NSRect(x: 0, y: Self.contentTop, width: width, height: rowsHeight)
        guard slidingUp else { return }

        rowsHost.frame.origin.y = Self.contentTop + rowsHeight
        rowsHost.alphaValue = 0
        NSAnimationContext.runAnimationGroup { [self] ctx in
            ctx.duration = 0.26
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            resize(to: height(for: page.count), animated: true)
            rowsHost.animator().setFrameOrigin(NSPoint(x: 0, y: Self.contentTop))
            rowsHost.animator().alphaValue = 1
        }
    }

    // MARK: Ending

    @objc private func endTapped(_ sender: NSButton) { end(at: sender.tag) }

    override func handle(_ event: NSEvent) -> Bool {
        guard let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...Self.perPage).contains(digit) else {
            return false
        }
        end(at: digit - 1)
        return true
    }

    private func end(at i: Int) {
        guard !turning, i < page.count, !ended.contains(i) else { return NSSound.beep() }
        let target = page[i]
        guard endProcess(target.pid) else {
            flash(.systemRed)
            return NSSound.beep()
        }
        ended.insert(i)
        remaining.removeAll { $0.pid == target.pid }
        buttons[i].spent = true
        rowsHost.subviews[i].animator().alphaValue = 0.28
        guard ended.count == page.count else { return }
        turnPage()
    }

    private func turnPage() {
        turning = true
        shake { [self] in
            flash(dexGreen)
            guard !remaining.isEmpty else {
                turning = false
                return breatheOutAndClose()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                rowsHost.alphaValue = 1
                layoutPage(slidingUp: true)
                turning = false
            }
        }
    }
}

// MARK: sweep (K)

/// What went, as a dotted list of item-words and what each freed. Closes itself after five
/// seconds — the count runs down in the corner — unless you hover or click, which hands the
/// sheet back to esc.
final class SweepPanel: ToolPanel {
    private static let rowHeight: CGFloat = 28
    private static let contentTop = ToolPanel.headerHeight + 10
    private static let chipWidth: CGFloat = 84

    private var secondsLeft = 5
    private var countdown: Timer?

    init(closed: [Slop], survived: [Slop]) {
        super.init(kind: .sweep, name: "sweep", width: 430)

        // One line per kind of leftover, not per process: "idle terminal 42 min" is one item-word.
        var order: [String] = []
        var freed: [String: Double] = [:]
        var counts: [String: Int] = [:]
        for s in closed {
            let word = String(s.reason.prefix(while: { !$0.isNumber })).trimmingCharacters(in: .whitespaces)
            if freed[word] == nil { order.append(word) }
            freed[word, default: 0] += s.rssMB
            counts[word, default: 0] += 1
        }
        if !survived.isEmpty {
            order.append("survived")
            freed["survived"] = survived.reduce(0) { $0 + $1.rssMB }
            counts["survived"] = survived.count
        }

        let rows = FlippedView(frame: NSRect(x: 0, y: Self.contentTop, width: width,
                                             height: CGFloat(order.count) * Self.rowHeight))
        let textX = 14 + Self.chipWidth + 12
        let listColumns = Int((width - textX - 14) / mono(10.5).maximumAdvancement.width)
        for (i, word) in order.enumerated() {
            let gone = word != "survived"
            let top = CGFloat(i) * Self.rowHeight
            let chip = capChip("\(counts[word] ?? 0)", gone ? "gone" : "left",
                               width: Self.chipWidth, dim: !gone)
            chip.frame.origin = NSPoint(x: 14, y: top + 4)
            rows.addSubview(chip)
            let line = panelLabel(dots(word, "\(Int(freed[word] ?? 0)) MB", columns: listColumns),
                                  10.5, gone ? panelInk : panelDim)
            line.frame.origin = NSPoint(x: textX, y: top + 8)
            rows.addSubview(line)
        }
        body.addSubview(rows)

        var y = Self.contentTop + rows.frame.height + 8
        body.addSubview(hairline(NSRect(x: 14, y: y, width: width - 28, height: 1)))
        y += 10

        let totalColumns = Int((width - 28) / mono(11, bold: true).maximumAdvancement.width)
        let total = panelLabel(dots("freed", "\(Int(closed.reduce(0) { $0 + $1.rssMB })) MB",
                                    columns: totalColumns),
                               11, dexGreen, bold: true)
        total.frame.origin = NSPoint(x: 14, y: y)
        body.addSubview(total)
        sheetHeight = y + 20 + 12

        body.onTouch = { [weak self] in self?.holdOpen() }
    }

    private var sheetHeight: CGFloat = 0

    /// `word ·········· amount`, filling the row width. The font is monospaced, so counting
    /// characters is the same as measuring.
    private func dots(_ left: String, _ right: String, columns: Int) -> String {
        let gap = max(2, columns - left.count - right.count - 2)
        return left + " " + String(repeating: "·", count: gap) + " " + right
    }

    func show(anchor: NSRect?) {
        present(height: sheetHeight, anchor: anchor)
        tick()
    }

    /// Counts 5 down to 1 in the corner, then closes.
    private func tick() {
        note.stringValue = "esc to close · \(secondsLeft)"
        placeNote()
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] t in
            secondsLeft -= 1
            guard secondsLeft > 0 else {
                t.invalidate()
                return dismiss()
            }
            note.stringValue = "esc to close · \(secondsLeft)"
            placeNote()
        }
    }

    /// Hovering or clicking means you are reading it: the timer stops for good, esc closes it.
    private func holdOpen() {
        guard countdown != nil else { return }
        countdown?.invalidate()
        countdown = nil
        note.stringValue = "esc to close"
        placeNote()
    }

    override func dismiss(animated: Bool) {
        countdown?.invalidate()
        countdown = nil
        super.dismiss(animated: animated)
    }
}

// MARK: dex (the menu bar dropdown)

/// The dropdown itself, rebuilt as one of these sheets so it slides like the other two and
/// carries the same key caps. Every control still calls the same actions the NSMenu called.
final class DexPanel: ToolPanel {
    /// One width for every key cap, so they line up and none of them jumps when its word changes.
    private static let capWidth: CGFloat = 170

    private let toggleKey: KeyButton
    private let safeBox = NSButton(checkboxWithTitle: "Auto-Disable when", target: nil, action: nil)
    private let batteryPill: NSButton
    private let tempPill: NSButton
    private let hotKeyRow = NSButton(title: "", target: nil, action: nil)
    private(set) var sheetHeight: CGFloat = 0
    private var pillOrigin: NSPoint = .zero
    private weak var owner: Dex?

    init(owner: Dex) {
        let label = defaults.string(forKey: "label")!
        let keys = String(label.dropLast())
        self.owner = owner
        toggleKey = KeyButton(cap: label, word: "Keep Awake", minWidth: DexPanel.capWidth, target: owner,
                              action: #selector(Dex.toggleFromMenu))
        batteryPill = pill("Battery at or below this (on battery). Click to change.", owner, #selector(Dex.editBattery))
        tempPill = pill("Chip temperature at or above this. Click to change.", owner, #selector(Dex.editTemp))
        super.init(kind: .dex, name: "dex", width: 400)
        closeWhenClickedAway = true

        var y = Self.headerHeight + 10

        toggleKey.frame.origin = NSPoint(x: 14, y: y)
        toggleKey.toolTip = "Click, or press \(label), to switch"
        toggleKey.breathe(delay: 0)
        body.addSubview(toggleKey)
        y += 33
        body.addSubview(hairline(NSRect(x: 14, y: y, width: width - 28, height: 1)))
        y += 11

        let safeTip = "Auto-Disable turns Dex off by itself when the chip gets too hot, or when the Mac is on battery "
            + "and drops too low. Keeps a closed laptop from overheating or draining flat. Click the values to change them."
        safeBox.target = owner
        safeBox.action = #selector(Dex.toggleSafeMode)
        safeBox.attributedTitle = NSAttributedString(string: "Auto-Disable when",
                                                     attributes: [.font: mono(12), .foregroundColor: panelInk])
        safeBox.toolTip = safeTip
        safeBox.sizeToFit()
        safeBox.frame.origin = NSPoint(x: 14, y: y)
        body.addSubview(safeBox)
        [batteryPill, tempPill].forEach(body.addSubview)
        pillOrigin = NSPoint(x: safeBox.frame.maxX + 8, y: y - 1)
        y += 30

        hotKeyRow.target = owner
        hotKeyRow.action = #selector(Dex.changeHotKey)
        hotKeyRow.isBordered = false
        hotKeyRow.setButtonType(.momentaryChange)
        hotKeyRow.alignment = .left
        hotKeyRow.frame = NSRect(x: 12, y: y, width: width - 24, height: 20)
        body.addSubview(hotKeyRow)
        y += 30
        body.addSubview(hairline(NSRect(x: 14, y: y, width: width - 28, height: 1)))
        y += 11

        for (cap, word, action, tip) in [
            (keys + "M", "memcheck", #selector(Dex.memcheckFromMenu),
             "Your processes using 1% of RAM or more, four at a time. Press 1\u{2013}4 to end one; esc closes."),
            (keys + "K", "sweep", #selector(Dex.sweepFromMenu),
             "Closes leftovers from builds: dev servers, automation browsers, terminals idle 30+ minutes "
                + "and orphaned build tools, then lists what it freed."),
        ] {
            let b = KeyButton(cap: cap, word: word, minWidth: Self.capWidth, target: owner, action: action)
            b.frame.origin = NSPoint(x: 14, y: y)
            b.toolTip = tip
            body.addSubview(b)
            y += 29
        }
        y += 4
        body.addSubview(hairline(NSRect(x: 14, y: y, width: width - 28, height: 1)))
        y += 10

        let author = panelLabel("by Daniel Trifunovic", 12, panelDim)
        author.frame.origin = NSPoint(x: 14, y: y + 3)
        author.toolTip = "Malo periculosam libertatem quam quietum servitium"
        body.addSubview(author)

        let gh = NSImage(contentsOfFile: Bundle.main.path(forResource: "github", ofType: "png") ?? "")
        gh?.size = NSSize(width: 14, height: 14)
        gh?.isTemplate = true
        let ghButton = linkButton("", image: gh, tip: "github.com/gigacook", owner, #selector(Dex.openGitHub))
        ghButton.sizeToFit()
        ghButton.frame.origin = NSPoint(x: author.frame.maxX + 10, y: y)
        body.addSubview(ghButton)

        let coffee = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: "Coffee")
        let kofi = linkButton("Support Dex", image: coffee, tip: "Buy me a coffee on Ko-fi", owner,
                              #selector(Dex.openKofi))
        kofi.sizeToFit()
        kofi.frame.origin = NSPoint(x: ghButton.frame.maxX + 8, y: y)
        body.addSubview(kofi)
        y += 30
        body.addSubview(hairline(NSRect(x: 14, y: y, width: width - 28, height: 1)))
        y += 10

        let quit = NSButton(title: "", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.isBordered = false
        quit.setButtonType(.momentaryChange)
        quit.alignment = .left
        quit.attributedTitle = NSAttributedString(string: "⌧ Quit Dex",
                                                  attributes: [.font: mono(12), .foregroundColor: panelInk])
        quit.frame = NSRect(x: 12, y: y, width: 140, height: 20)
        body.addSubview(quit)

        let quitKey = panelLabel("⌘Q", 11, panelDim)
        quitKey.frame.origin = NSPoint(x: width - 14 - quitKey.frame.width, y: y + 2)
        body.addSubview(quitKey)
        y += 30

        sheetHeight = y + 4
        sync()
    }

    func show(anchor: NSRect?) { present(height: sheetHeight, anchor: anchor) }

    /// Pulls the live values back out of defaults — the sheet stays open while they change.
    func sync() {
        let awake = owner?.awake ?? false
        title.attributedStringValue = NSAttributedString(
            string: "dex", attributes: [.font: mono(15, bold: true), .foregroundColor: dexGreen])
            + NSAttributedString(string: awake ? " — active" : " — inactive", attributes: [
                .font: mono(15, bold: true), .foregroundColor: awake ? dexGreen : panelDim,
            ])
        title.sizeToFit()
        toggleKey.setWord(awake ? "Let It Sleep" : "Keep Awake")

        let safe = defaults.bool(forKey: "safeMode")
        safeBox.state = safe ? .on : .off
        batteryPill.title = "≤\(defaults.integer(forKey: "batteryMin"))%"
        tempPill.title = "≥\(defaults.integer(forKey: "tempMax"))°C"
        for pill in [batteryPill, tempPill] {
            pill.isEnabled = safe
            pill.sizeToFit()
            pill.frame.size.width += 10
        }
        batteryPill.frame.origin = pillOrigin
        tempPill.frame.origin = NSPoint(x: batteryPill.frame.maxX + 6, y: pillOrigin.y)
        hotKeyRow.attributedTitle = NSAttributedString(
            string: "Hot Key: \(defaults.string(forKey: "label")!)  (click to change)",
            attributes: [.font: mono(12), .foregroundColor: panelInk])
    }
}

// MARK: - App

final class Dex: NSObject, NSApplicationDelegate {
    var item = makeStatusItem(nearClock: false)
    var awake = false
    /// The one sheet on screen, if any: the dropdown, memcheck or sweep.
    var sheet: ToolPanel?
    var safeTimer: Timer?
    /// When a click outside last closed a sheet, so the status item can ignore that same click.
    var lastClickAway = Date.distantPast
    var lastRescue = Date.distantPast

    func applicationDidFinishLaunching(_: Notification) {
        _ = setSleepDisabled(false) // clear any leftover state from a crash
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        defaults.register(defaults: ["code": 2, "mods": Int(controlKey | optionKey), "label": "\u{2303}\u{2325}D",
                                     "safeMode": true, "batteryMin": 15, "tempMax": 80])
        armStatusItem()
        watchPlacement()

        onHotKey = { [weak self] id in
            switch id {
            case 2: self?.show(.memcheck)
            case 3: self?.show(.sweep)
            default: self?.toggle()
            }
        }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            onHotKey(id.id)
            return noErr
        }, 1, &spec, nil, nil)
        let code = UInt32(defaults.integer(forKey: "code")), mods = UInt32(defaults.integer(forKey: "mods"))
        let label = defaults.string(forKey: "label")!
        refresh()
        registerToolKeys()
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
        NSStatusBar.system.removeStatusItem(item)
        item = makeStatusItem(nearClock: true)
        armStatusItem()
        refresh()
        NSLog("Dex: menu bar icon was hidden (notch or full menu bar), moved it next to the system icons")
    }

    /// After "Use Anyway": don't ask about this clash again at every launch.
    func rememberAllowed(_ code: UInt32, _ mods: UInt32) {
        if conflict(code, mods) != nil { defaults.set(true, forKey: "allowed-\(code)-\(mods)") }
    }

    func applicationWillTerminate(_: Notification) { _ = setSleepDisabled(false) }

    /// The dropdown is a sheet now, so the status item carries an action instead of a menu.
    func armStatusItem() {
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
    }

    @objc func statusClicked() {
        // The click that closes an open sheet also lands on the button; without this the sheet
        // would shut and immediately reopen.
        guard Date().timeIntervalSince(lastClickAway) > 0.3 else { return lastClickAway = .distantPast }
        show(.dex)
    }

    /// One sheet at a time. The same hotkey again puts it away; a different one swaps it out,
    /// and closing that leaves nothing behind.
    func show(_ kind: ToolPanel.Kind) {
        let showing = sheet?.onScreen == true ? sheet?.kind : nil
        sheet?.dismiss(animated: showing == kind)
        sheet = nil
        guard showing != kind else { return }
        switch kind {
        case .dex:
            let panel = DexPanel(owner: self)
            panel.onClickedAway = { [weak self] in self?.lastClickAway = Date() }
            sheet = panel
            panel.show(anchor: item.button?.window?.frame)
        case .memcheck: showMemcheck()
        case .sweep: sweepSlop()
        }
    }

    func refresh() {
        item.button?.image = icon(running: awake)
        (sheet as? DexPanel)?.sync()

        // Check every 30 s while keeping the Mac awake with Auto-Disable on
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
        alert("Auto-Disable turned Dex off", "Your Mac can sleep normally again because \(reason).")
    }

    func toggle() {
        if sheet is DexPanel { sheet?.dismiss(); sheet = nil }
        guard !awake else { _ = setAwake(false); return }
        if defaults.bool(forKey: "safeMode"), let reason = unsafeReason() {
            return alert("Dex can't turn on right now", "Auto-Disable is on and \(reason).")
        }
        guard confirm("Dex keeps your Mac awake, even with the lid closed",
                      "Don't leave it closed in a bag or tight space for long. It can overheat.",
                      ok: "Keep Awake", muteKey: "noHeatWarning") else { return }
        _ = setAwake(true)
    }

    /// Controls inside the sheets: put the sheet away first. It floats at status bar level, so
    /// anything it opens would otherwise end up behind it.
    func afterMenu(_ work: @escaping () -> Void) {
        sheet?.dismiss()
        sheet = nil
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

    // MARK: Memory hogs (M) and build slop sweep (K)

    /// Same modifiers as the keep-awake hotkey, with M and K.
    func registerToolKeys() {
        let mods = UInt32(defaults.integer(forKey: "mods"))
        _ = registerHotKey(46, mods, id: 2) // M
        _ = registerHotKey(40, mods, id: 3) // K
    }

    @objc func memcheckFromMenu() { afterMenu { self.show(.memcheck) } }
    @objc func sweepFromMenu() { afterMenu { self.show(.sweep) } }

    /// memcheck: what is eating RAM, four at a time, each endable with its own number key.
    func showMemcheck() {
        let hogs = Array(endableHogs().prefix(12))
        guard !hogs.isEmpty else { return alert("Nothing is hogging RAM", "No process is using 1% or more.") }
        let panel = MemcheckPanel(hogs: hogs)
        sheet = panel
        panel.show(anchor: item.button?.window?.frame)
    }

    /// Closes build leftovers and says what went, by kind.
    func sweepSlop() {
        let targets = buildSlop()
        guard !targets.isEmpty else {
            return alert("Nothing to sweep", "No dev servers, automation browsers, idle terminals or orphaned build tools.")
        }
        var closed: [Slop] = [], left: [Slop] = []
        for t in targets {
            if endProcess(t.pid, hangup: t.reason.hasPrefix("idle terminal")) { closed.append(t) } else { left.append(t) }
        }
        let panel = SweepPanel(closed: closed, survived: left)
        sheet = panel
        panel.show(anchor: item.button?.window?.frame)
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
        registerToolKeys()
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
