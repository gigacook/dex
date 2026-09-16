# Dex build log

Rolling log. Newest session at the bottom. Reusable tool notes live in [`newskills/`](newskills/).

## Session 1: 2026-09-16, v1.0.0

**Goal:** a menu bar app with no window. A hotkey toggles "keep awake with the lid closed". The menu shows author, date, quote, GitHub link and a hotkey changer. It starts at login, lives in a public repo, and is installable by others.

### Pipeline chosen (cheapest that works)
One `main.swift` → `swiftc` ×2 archs → `lipo` → hand-made `.app` folder + `Info.plist` → `codesign -s -` → `ditto` zip → `gh release` → `install.sh` via curl.
No Xcode project, no SwiftPM, no dependencies.

### Timeline
| Step | What | Result |
|---|---|---|
| 1 | Checked env: sandBox numbering, `gh auth status`, `swiftc --version` | Swift 6.3.3, gh logged in as gigacook |
| 2 | Asked 4 questions: toggle trigger, default hotkey, install method, date | Revealed the real feature: keep awake **with lid closed** + heat warning |
| 3 | Wrote `Sources/main.swift`, `Info.plist`, `build.sh`, `install.sh` | |
| 4 | First build failed: `value of type 'Any' has no member '0'` | Mixed `Int`/`Double` tuple array literal became `[Any]`. Fixed with `6.0` |
| 5 | Rebuilt | Universal binary OK |
| 6 | Verified `CopySymbolicHotKeys` with a throwaway script | 230 system shortcuts; ⌃⌘Space found |
| 7 | Launched app | Running, `SleepDisabled 0` at start |
| 8 | `git init` → `gh repo create --push` → `gh release create v1.0.0 build/Dex.zip` | Public repo + release |
| 9 | Tried `curl … install.sh \| sh` | **Blocked by Claude Code auto-mode classifier** (piping a remote script to a shell). Checked the pieces separately instead |

### Key decisions
- **Lid-closed awake = `pmset -a disablesleep 1`.** `caffeinate` and IOPMAssertions do NOT stop clamshell sleep. The command needs root, so on first use the app installs a sudoers drop-in that allows only that exact command (one password prompt ever).
- **Carbon `RegisterEventHotKey`** instead of `NSEvent` global monitors, because it needs no Accessibility permission.
- **Template image** for the idle icon: the system tints it white or black to match the menu bar. The running icon is non-template green.
- **`SMAppService.mainApp`** for autostart. No LaunchAgent plist needed.
- **Unsigned (ad-hoc) + curl installer** instead of notarization. $0, but people outside Homebrew/curl hit Gatekeeper.

### Problems / gotchas hit
1. Swift tuple array type inference (see step 4).
2. Running the test build registered **`build/Dex.app`** as the login item. Delete `build/` after installing the real app.
3. The agent can't run `curl | sh`. Verify the release asset and script URL separately, and let the user run the installer.
4. Not testable by the agent: admin password prompt, closing the lid, the key-recorder dialog. Test these by hand.

### Cost savers for next time
- Start from `newskills/swiftc` + `nsstatusitem` + `codesign` + `ditto`. The whole pipeline is ~15 lines of shell.
- Ask "what does the app actually *do*" first. The icon spec hid the core feature.
- Write the throwaway verification script in `$TMPDIR`, not the repo.

### Open / next
- [ ] Manual test: ⌃⌥D → warning → password → green → close the lid
- [x] ~~Homebrew tap / notarization~~: declined, $99/yr not worth it for now (2026-09-16)

## Session 2: 2026-09-16, v1.1.0

**Goal:** Safe Mode (on by default, hover tooltip, warning with "Don't warn again" when turning it off), a way to start Dex from the terminal, Spotlight visibility, Ko-fi + GitHub Sponsors, README, todo.md.

### Timeline
| Step | What | Result |
|---|---|---|
| 1 | Safe Mode: `ProcessInfo.thermalState` ≥ `.serious` OR on battery ≤ 15% (IOKit power sources), checked every 30 s while awake | Also blocks turning on if already unsafe |
| 2 | Pulled out a `confirm(… muteKey:)` helper | Heat warning + Safe Mode off warning share one dialog function |
| 3 | Menu item `Safe Mode` with `.state` checkmark + `.toolTip` | Tooltip on hover, no custom view needed |
| 4 | App icon via `tools/make-icon.swift` → iconset → `iconutil` → `Resources/AppIcon.icns` | Spotlight/Finder/Launchpad show a green bolt instead of a blank icon |
| 5 | `install.sh` appends `alias dex="open -a Dex"` to `~/.zshrc` / `~/.bash_profile` | `dex` starts it again. `open -a` never starts a second copy |
| 6 | `.github/FUNDING.yml` (github + ko_fi), Ko-fi menu item, README badges | Accounts still need creating → `todo.md` |
| 7 | Build, v1.1.0 release | First try, no compile errors |

### Key decisions
- **Spotlight:** nothing to build. Any `.app` in /Applications gets indexed. It only needed a real icon.
- **Terminal command:** a shell alias instead of a binary in `/usr/local/bin` (that folder may not exist on Apple Silicon and can need sudo).
- **Safe Mode trigger values:** thermal `.serious` (macOS's own throttling signal) and 15% battery. No temperature sensors, which need private APIs.
- Donation usernames were assumed to be `gigacook` everywhere. Listed in todo.md to confirm.

### Cost savers for next time
- Menu item tooltip + checkmark = `item.toolTip` + `item.state`. Don't build a custom NSView.
- One `confirm()` helper with a UserDefaults mute key covers every "warn once" dialog.
- See `newskills/iokit-power` and `newskills/iconutil`.

## Session 3: 2026-09-16, v1.2.0

**Goal:** figure out why ⌃⌥D resizes windows. JetBrains Mono menu redesign (`DEX — STATE` / Auto-Disable with `≤15%` `≥80°C` editable / Hot Key / author + GitHub + coffee). Real °C temperature.

### Timeline
| Step | What | Result |
|---|---|---|
| 1 | `ps` + `/Applications` scan for window managers | **Magnet** + Karabiner running |
| 2 | Decoded Magnet prefs (`defaults export` → `plutil -extract … raw` → base64 → JSON) | Magnet "Left Third" + "Top Third" = keyCode 2, mods 6144 (⌃⌥D) |
| 3 | Test `RegisterEventHotKey` ⌃⌥D while Magnet runs | **Succeeds** (noErr). Carbon can't see Magnet's binding, so both fire |
| 4 | Fix: default → ⌃⌥⌘D. `shortcutOwner()` reads Magnet + Rectangle prefs via `CFPreferencesCopyAppValue`. Launch warning on conflict | Verified: ⌃⌥D → Magnet, ⌃⌥⌘D → free |
| 5 | Private IOHID sensor API test script | M2: `PMU tdie*` sensors ≈ 40°C idle. `tcal` = fake 51.85 constant, skip it |
| 6 | JetBrains Mono TTF + OFL from jsdelivr → `Resources/`, `ATSApplicationFontsPath = .` | Fonts load from the bundle, no install |
| 7 | GitHub mark: octicons SVG → PNG via `NSImage(contentsOfFile:)` in `make-icon.swift` | Committed `Resources/github.png` (SVG in build/ only) |
| 8 | Menu rebuilt: attributed titles + `NSStackView` custom row views | Compiled first try |
| 9 | Tried `osascript` System Events click on the status item for a screenshot | **Hung 120 s**. A menu click blocks until the menu closes. Killed it. Visual check left to the user |

### Key decisions
- **Default hotkey ⌃⌥⌘D** (still D). ⌃⌥D collides with Magnet *and* Rectangle defaults. The user can rebind after removing it in Magnet.
- **Temp = max of `tdie` sensors** (chip die). Intel fallback = `thermalState ≥ .serious`.
- **Editable values = pill buttons → NSAlert with a text field.** Typing into text fields *inside* an open menu is unreliable.
- Dropped the date/quote rows per the new layout. The quote lives on as the author row's tooltip.

### Cost savers for next time
- Hotkey "taken" checks must read the popular window managers' prefs. Carbon alone lies.
- Don't try to automate status-menu screenshots with osascript. Ask the user for a screenshot.
- See `newskills/iohid-temperature`, `newskills/bundled-fonts`, and the updated `carbon-hotkeys` + `nsstatusitem`.

## Session 4: 2026-09-16, v1.2.0 (cont.)

**Goal:** audit skills for gaps. Explain the Ghostty permission prompts. Default back to ⌃⌥D. Conflict warning with Unbind / Use Anyway / Pick Another, showing the colliding app's action names. Magnet unbind done by Dex. README with behavior + limits.

### Timeline
| Step | What | Result |
|---|---|---|
| 1 | User screenshot: Ghostty asked for **Screen Recording** + **Automation → System Events** | Caused by *my* session 3 `screencapture` + `osascript` attempt, not by Dex. Documented in `newskills/macos-permissions` |
| 2 | Skill audit vs everything used | Missing: `defaults`/`plutil`/CFPreferences (other apps' prefs), `swift` test scripts, TCC prompts, SVG→PNG. Added `app-preferences`, `swift-scripts`, `macos-permissions` + iconutil note |
| 3 | Inspected Magnet: bundle id, prefs location, "empty shortcut" shape | Plain `~/Library/Preferences` (not sandboxed). Separators store `keyboardShortcut` without a `shortcut` key → safe "unbound" format |
| 4 | `Conflict {owner, actions, unbind?}` + `resolve()` alert (Unbind / Use Anyway / Pick Another), used at launch + on rebind | "Use Anyway" remembered per combo (`allowed-<code>-<mods>`) |
| 5 | `unbindMagnet`: backup (`defaults export`) → terminate → edit JSON → `CFPreferencesAppSynchronize` → relaunch → verify | |
| 6 | **Dry-run** in a swift script (no write) | Hits exactly `Left Third` + `Top Third`, 24/24 commands kept, 1 shortcut removed per list, Bools intact |
| 7 | README rewritten: behavior tables + "Good to know" limits | |

### Key decisions
- **Default stays ⌃⌥D** (user preference). Clashes are handled by the dialog instead of avoided.
- **Rectangle: warn only, no auto-unbind.** Not installed here, so its "cleared" format can't be verified, and a wrong edit could reset its shortcuts to defaults.
- **macOS clashes: warn + Use Anyway.** Editing `com.apple.symbolichotkeys` needs a logout to apply.
- Did **not** run the real Magnet unbind myself. It changes the user's Magnet setup, so the user triggers it from the dialog.

### Cost savers for next time
- Never verify GUI via osascript/screencapture (prompts go to the user's terminal, permanently if allowed).
- Before editing another app's settings: find an existing "empty" entry and copy its shape, then dry-run.
