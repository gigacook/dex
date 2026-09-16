---
name: pmset
description: Control macOS power management from code, especially keeping a MacBook awake with the lid closed (disablesleep). Use for keep-awake / anti-sleep tools.
---

# pmset

**Solved in Dex:** the core feature. `pmset -a disablesleep 1` keeps the Mac running with the lid closed, and `0` restores normal sleep.

**When:** you need to stop **lid-close (clamshell) sleep**. For "don't idle-sleep while the lid is open", `caffeinate -i` or an IOPMAssertion is enough and needs no root.

## Example
```sh
sudo pmset -a disablesleep 1          # on
sudo pmset -a disablesleep 0          # off
pmset -g | grep SleepDisabled         # read state (no sudo)
```
From Swift: run `/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1` through `Process`. `-n` fails instead of hanging on a password prompt. See `sudoers-dropin`.

## Critical considerations
- **Needs root.** Plan for privilege from the start (sudoers drop-in or a privileged helper).
- `caffeinate`, `IOPMAssertionCreateWithName` and Amphetamine-style assertions do **not** prevent lid-close sleep without an external display.
- The setting **persists** after your app quits or crashes, even across reboots. Always reset to 0 on launch and in `applicationWillTerminate`.
- Heat risk: a closed laptop in a bag keeps running at full power. Warn the user.
- The display still turns off when the lid closes. That's expected.
