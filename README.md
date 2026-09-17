# Dex ⚡

A tiny macOS menu bar app that keeps your Mac awake, **even with the lid closed and on battery**, so long jobs keep running. Downloads, renders, builds, training runs.

One icon, one hotkey, safe defaults.

> *Malo periculosam libertatem quam quietum servitium*

## Install

Paste into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/gigacook/dex/main/install.sh | sh
```

This puts Dex in `/Applications`, starts it, sets it to start at login, and adds a `dex` terminal command.
Requires macOS 13 or later, on Apple Silicon or Intel.

## The menu

```
DEX — INACTIVE                          click to switch (ACTIVE = green)
─────────────────────────────────
☑ Auto-Disable when  [≤15%] [≥80°C]     click a value to change it
Hot Key: ⌃⌥D  (click to change)
─────────────────────────────────
Memory Hogs        ⌃⌥M                  what is eating your RAM
Sweep Build Slop   ⌃⌥K                  close what a build left running
─────────────────────────────────
by Daniel Trifunovic   [GitHub]  ☕ Support Dex
─────────────────────────────────
Quit Dex
```

Menu bar icon: **thin ring + bolt = inactive**, **thicker green = keeping your Mac awake**.

## How it behaves

### Turning it on / off
- Press **⌃⌥D** (or your own hotkey), or click `DEX — INACTIVE` in the menu.
- **The first time:** a heat warning ("don't leave it closed in a bag"), with "Don't warn me again".
- **The first time only:** macOS asks for your password. Dex uses it to add one rule, `/etc/sudoers.d/dex`, that lets it run exactly `pmset -a disablesleep 0` and `1`, nothing else. After that, switching is instant with no password.
- **Quitting Dex, restarting the Mac, or Dex crashing** always ends with normal sleep. Dex resets it at launch and at quit.

### Auto-Disable (on by default)
Dex switches itself **off** and tells you why when:
- the **chip temperature** reaches **80°C**, or
- the Mac is **on battery** and drops to **15%**.

It checks every 30 seconds while active, and won't turn on if either is already true.
- **Change the values:** click `≤15%` (5–90) or `≥80°C` (50–105). Hover the row for an explanation.
- **Turn it off:** untick the checkbox → warning with "Don't warn me again".

### Memory Hogs (⌃⌥M)
Everything using **1% of RAM or more**, biggest first, with PID, %MEM, RSS and name. *End a Process…* takes a PID
(the biggest one is filled in), asks it to quit, and forces it only if it ignores that.

### Sweep Build Slop (⌃⌥K)
Long sessions leave things running. One press closes them and tells you what went and how much RAM came back:

| Closed | Left alone |
|---|---|
| **Dev servers** — Python, Node, Ruby, PHP, Deno, Bun or `http.server`/uvicorn/vite-style processes holding a port | Servers that belong to an installed app |
| **Automation browsers** — headless, Playwright, Puppeteer, chromedriver and friends | Your normal browser windows |
| **Idle terminals** — a shell with nothing running in it and no typing for 30+ minutes | Anything inside tmux, screen or zellij |
| **Orphaned build tools** — swift, clang, esbuild, tsc left behind, and Node/Python orphans over 50% CPU or 500 MB | — |

It never touches other users' processes, system processes, Claude, Terminal, iTerm, ssh or Dex itself. A terminal with
something running in it is never idle, so a working session is safe.

Both hotkeys follow the modifiers of your keep-awake shortcut: change it to ⌘⌥D and they become ⌘⌥M and ⌘⌥K.

### Hotkey and clashing apps
Default is **⌃⌥D**. Click *Hot Key* and press a new combo (it needs ⌘, ⌃ or ⌥). Esc cancels.

Dex checks whether something else already uses the shortcut, **when it starts and when you pick one**:

| Clashes with | Dex shows | Your choices |
|---|---|---|
| **Magnet** | Which Magnet actions use it (e.g. *Left Third, Top Third*) | **Unbind in Magnet** (automatic), **Use Anyway**, **Pick Another** |
| **Rectangle** | Which Rectangle actions use it | **Use Anyway**, **Pick Another** (clear it in Rectangle yourself) |
| **macOS** shortcuts | That macOS uses it | **Use Anyway**, **Pick Another** |

**Unbind in Magnet:**
1. saves a backup to `~/Library/Application Support/Dex/magnet-backup-<time>.plist`
2. quits Magnet
3. removes the shortcut from those actions only (everything else untouched)
4. reopens Magnet

To restore: `defaults import com.crowdcafe.windowmagnet ~/Library/Application\ Support/Dex/magnet-backup-<time>.plist`, then restart Magnet.

**Use Anyway** is remembered for that combo, so Dex won't ask again at every launch. Both apps then react to the key press.

### If Dex isn't running
`dex` in Terminal, `open -a Dex`, or Spotlight → "Dex". Opening it again never starts a second copy.

## Good to know (how it works and its limits)

- **Why a password?** Keeping a Mac awake *with the lid closed* is only possible with `pmset disablesleep`, which needs admin rights. The usual tools (`caffeinate`, Amphetamine-style "assertions") don't stop lid-close sleep without a charger and external display.
- **80°C will trip under heavy work.** Apple Silicon chips normally run 90–100°C when busy. For a closed laptop in a bag that's the point. If you run long heavy jobs **with the lid open**, raise the limit.
- **Temperature reading uses an undocumented macOS interface** (the same one monitoring apps like Stats use). It needs no permissions, but a future macOS update could break it. If it stops working, Dex falls back to macOS's own "too hot" signal.
- **Intel Macs** don't expose chip temperature this way, so they always use that "too hot" signal instead of the °C value.
- **Notched MacBooks hide menu bar icons that don't fit.** A Focus / Do Not Disturb icon appearing, or the bar re-laying itself out after wake, can push icons behind the notch. Dex checks its own icon after wake, on screen changes and once a minute, and moves itself next to the system icons if it got hidden. ⌘-drag it where you like; Dex remembers the spot. If your bar is truly full, some other icon gets hidden instead.
- **Hotkey detection has limits.** macOS lets two apps register the same shortcut without error, so Dex specifically reads **Magnet's** and **Rectangle's** settings. Clashes with other apps (Raycast, BetterTouchTool, Karabiner rules, in-app shortcuts) are **not** detected.
- **The Magnet unbind edits Magnet's settings file** in a format Magnet doesn't document. It was built against Magnet's current settings format. If a Magnet update changes it, Dex tells you it couldn't unbind, and the backup is always saved first.
- **Unsigned app.** Dex isn't signed with a paid Apple Developer ID. The curl installer avoids Gatekeeper's block. If you download the zip in a browser instead, right-click → Open the first time.
- **No privacy permissions.** Dex needs no Accessibility, Screen Recording or Automation access. If you see such a prompt, it isn't from Dex.
- **Not possible on the Mac App Store.** App Store apps can't change system sleep settings or read chip sensors.

## Uninstall

```sh
pkill -x Dex; rm -rf /Applications/Dex.app; sudo rm /etc/sudoers.d/dex
rm -rf ~/Library/Application\ Support/Dex; defaults delete com.gigacook.dex
```
Then remove the `alias dex=…` line from `~/.zshrc`, and the Dex entry in System Settings → General → Login Items if it's still listed.

## Build from source

```sh
./build.sh                      # needs Xcode Command Line Tools → build/Dex.app + build/Dex.zip
swift tools/make-icon.swift     # only if you change the app icon / GitHub icon
```
Build notes: [`buildlog/`](buildlog/).

## Support

Dex is free. If it saved your overnight render, you can buy me a coffee:

[![Ko-fi](https://img.shields.io/badge/Ko--fi-support-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/gigacook)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub-sponsor-EA4AAA?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/gigacook)

---

Font: [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) (SIL Open Font License, bundled).
Built by Daniel Trifunovic · [github.com/gigacook](https://www.github.com/gigacook)
