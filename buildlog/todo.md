# Dex: your to-do

## 1. Donations (the links are already in the app + README, they just need accounts behind them)
- [ ] **Ko-fi:** sign up at https://ko-fi.com with the username **`gigacook`** (the link points to `ko-fi.com/gigacook`).
  If that name is taken, tell Claude the new one. It needs changing in `Sources/main.swift`, `README.md` and `.github/FUNDING.yml`.
- [ ] **Ko-fi payouts:** connect PayPal or Stripe in Ko-fi settings, or nobody can pay you.
- [ ] **GitHub Sponsors:** go to https://github.com/sponsors → "Get sponsored" → fill in your profile, connect Stripe, and set a few tiers (e.g. $2 / $5 / $10).
  Approval can take a few days. Until then the **Sponsor** button on the repo only shows Ko-fi.

## 2. Test by hand (Claude can't do these)
- [ ] Install for real: `curl -fsSL https://raw.githubusercontent.com/gigacook/dex/main/install.sh | sh`
- [ ] Delete the test build: `rm -rf ~/Documents/Claude/sandBox/17_dex/build`. It registered itself as a login item from that folder.
- [ ] System Settings → General → Login Items: only **one** Dex listed, and it points to /Applications
- [ ] **Your ⌃⌥D:** Magnet → Settings → Keyboard shortcuts → clear "Left Third" (and "Top Third"). Then Dex menu → Hot Key → press ⌃⌥D
- [ ] Hotkey (⌃⌥⌘D, or ⌃⌥D after the step above) → heat warning → password prompt → icon turns green, menu shows `DEX — ACTIVE`
- [ ] **Look at the new menu** (JetBrains Mono, row spacing, GitHub icon, coffee icon). Screenshot it (⌘⇧4) and send it to Claude if anything looks off
- [ ] Close the lid for 5+ min on battery with something running (e.g. `ping 1.1.1.1`) → reopen → still running
- [ ] Hover **Auto-Disable** → tooltip. Untick → warning with "Don't warn me again"
- [ ] Click `≥80°C` → set 45 while active → Dex turns itself off within 30 s ("the chip is at …°C"). Set back to 80
- [ ] Hot Key → try ⌘Space (warns "used by macOS"). Try ⌃⌥D before clearing it in Magnet (warns "used by Magnet")
- [ ] Quit Dex → `pmset -g | grep SleepDisabled` shows `0`
- [ ] New terminal → `dex` starts it. Spotlight → "Dex" finds it (with the green icon).

- [ ] Happy with it → tell Claude "ship" → push + v1.2.0 release

## 3. Get people to use it (free)
- [ ] Add a screenshot/GIF of the menu to the README (Cmd+Shift+5)
- [ ] Post it on r/macapps, r/MacOS, Hacker News "Show HN", and in friends' group chats

## Later (only if people actually use it)
- [ ] Timer ("stay awake for 2 h")
- [ ] Apple Developer account ($99/yr) → signed + notarized → Homebrew cask, no security warnings
