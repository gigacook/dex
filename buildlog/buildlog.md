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
