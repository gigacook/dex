---
name: macos-permissions
description: Which commands trigger macOS privacy (TCC) prompts like Screen Recording or Automation/System Events, who the prompt is really for, whether allowing is permanent, and how to avoid them when building/verifying Mac apps with an agent.
---

# macOS privacy prompts (TCC)

**Solved/learned in Dex:** trying to screenshot Dex's menu automatically triggered two prompts **for Ghostty** (the terminal Claude runs in), not for Dex:
- `screencapture` → **"Ghostty.app would like to record this computer's screen and audio"** (Screen Recording)
- `osascript -e 'tell application "System Events" … click menu bar item'` → **"Ghostty.app wants access to control System Events.app"** (Automation). The command also **hung 120 s**, because clicking a menu blocks until the menu closes.

## Who gets the permission
The prompt names the **app that ran the command**: the terminal (Ghostty, Terminal, iTerm), not Claude and not your app. If allowed, **every program started from that terminal** gets it, **permanently**, including future agent sessions and any script.

## Undo / check
System Settings → Privacy & Security →
- **Screen & System Audio Recording** → turn Ghostty off
- **Automation** → Ghostty → turn System Events off
- **Accessibility / Input Monitoring** → same idea

Reset from terminal: `tccutil reset ScreenCapture com.mitchellh.ghostty` / `tccutil reset AppleEvents com.mitchellh.ghostty`

## What needs what (for building menu bar tools)
| Action | Prompt? |
|---|---|
| `RegisterEventHotKey` (Carbon hotkey) | None |
| `NSEvent.addGlobalMonitorForEvents` (keyboard) | Accessibility / Input Monitoring |
| `screencapture`, `CGWindowListCreateImage` | Screen Recording |
| `osascript` → System Events / other apps | Automation (per target app) + often Accessibility |
| `do shell script … with administrator privileges` | Password dialog only (not TCC) |
| Reading another app's `~/Library/Preferences` plist | None |
| Reading another app's `~/Library/Containers/…` | "Access data from other apps" |
| `pmset`, IOKit battery, IOHID temperature | None |

## Critical considerations
- **Agents: don't automate GUI verification** (menus, screenshots) through osascript/screencapture. It prompts the user, grants go to their terminal, and menu clicks hang. Ask the user for a screenshot instead.
- Tell the user **before** running a command that can trigger a prompt, and why.
- Denying is safe. The command just fails. macOS usually won't ask again, so change it in System Settings later if needed.
