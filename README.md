# Dex ⚡

A tiny macOS menu bar app that keeps your Mac awake, **even with the lid closed**, so long jobs keep running.

- Ring + bolt icon, thin = idle, **green and thicker = keeping awake**
- Toggle with a global hotkey (default **⌃⌥D**). Change it from the menu. Dex warns you if macOS or another app already uses the shortcut.
- Starts automatically at login
- Heat warning the first time you turn it on (you can turn the warning off)

> *Malo periculosam libertatem quam quietum servitium*

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/gigacook/dex/main/install.sh | sh
```

The first time you turn it on, macOS asks for your password once. Dex uses it to add a single rule (`/etc/sudoers.d/dex`) that lets it run only `pmset -a disablesleep 0/1`.

Requires macOS 13+.

### Uninstall

```sh
pkill -x Dex; rm -rf /Applications/Dex.app; sudo rm /etc/sudoers.d/dex
```

## Build from source

```sh
./build.sh   # needs Xcode Command Line Tools → build/Dex.app
```

Built by Daniel Trifunovic, 2026-09-16 · [github.com/gigacook](https://www.github.com/gigacook)
