# Dex ⚡

A tiny macOS menu bar app that keeps your Mac awake, **even with the lid closed and on battery**, so long jobs keep running. Downloads, renders, builds, training runs.

One icon, one hotkey, nothing to configure.

> *Malo periculosam libertatem quam quietum servitium*

## Features
- **Lid-closed keep-awake:** no charger or external monitor needed
- **Icon shows state:** thin ring = idle, **green and thicker = keeping awake**
- **Global hotkey** (default **⌃⌥D**). Change it from the menu. Dex warns you if macOS or another app already uses it.
- **Safe Mode** (on by default): Dex switches itself off if your Mac gets too hot, or if it's on battery and drops to 15%. A closed laptop in a bag won't cook or drain flat.
- **Starts at login.** Also findable in Spotlight and Launchpad.
- **Open source:** about 250 lines of Swift you can read before trusting it

## Install

Paste into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/gigacook/dex/main/install.sh | sh
```

This puts Dex in `/Applications`, starts it, and adds a `dex` terminal command.

**The first time you turn it on**, macOS asks for your password once. Dex uses it to add a single rule (`/etc/sudoers.d/dex`) that lets it run exactly one command: `pmset -a disablesleep 0/1`. Nothing else.

Requires macOS 13 or later, on Apple Silicon or Intel.

## Use

| | |
|---|---|
| Turn on / off | **⌃⌥D** (or your own hotkey) |
| Menu | Click the menu bar icon |
| Safe Mode | Menu → Safe Mode (hover for details) |
| Start Dex if it's not running | `dex` in Terminal, `open -a Dex`, or Spotlight → "Dex" |

Quitting Dex always restores normal sleep.

## Uninstall

```sh
pkill -x Dex; rm -rf /Applications/Dex.app; sudo rm /etc/sudoers.d/dex
```
Then remove the `alias dex=…` line from `~/.zshrc`.

## Build from source

```sh
./build.sh                      # needs Xcode Command Line Tools → build/Dex.app
swift tools/make-icon.swift     # only if you change the app icon
```

## Support

Dex is free. If it saved your overnight render, you can buy me a coffee:

[![Ko-fi](https://img.shields.io/badge/Ko--fi-support-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/gigacook)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub-sponsor-EA4AAA?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/gigacook)

---

Built by Daniel Trifunovic · [github.com/gigacook](https://www.github.com/gigacook)
