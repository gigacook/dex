---
name: curl-installer
description: Make an unsigned macOS app installable with one Terminal line (curl script → download release zip → /Applications → strip quarantine → open). Also covers what a Homebrew tap needs.
---

# One-line curl installer (+ xattr)

**Solved in Dex:** free distribution with no Apple Developer account.

**When:** hobby or unsigned Mac apps shared with technical users.

## Example
`install.sh` in the repo root:
```sh
#!/bin/sh
set -e
tmp=$(mktemp -d)
curl -fsSL https://github.com/gigacook/dex/releases/latest/download/Dex.zip -o "$tmp/Dex.zip"
pkill -x Dex 2>/dev/null || true
rm -rf /Applications/Dex.app
ditto -x -k "$tmp/Dex.zip" /Applications
xattr -dr com.apple.quarantine /Applications/Dex.app 2>/dev/null || true
open /Applications/Dex.app
```
User runs: `curl -fsSL https://raw.githubusercontent.com/gigacook/dex/main/install.sh | sh`

## Critical considerations
- `curl -f` fails on HTTP errors instead of saving a 404 page as the zip. `set -e` stops on the first error.
- `pkill` before replacing, or you overwrite a running app.
- Admin users can write to /Applications without sudo. Don't add sudo unless needed.
- Browser downloads get the `com.apple.quarantine` flag and Gatekeeper blocks unsigned apps. Curl doesn't add it, but `xattr -dr` is cheap insurance.
- **Claude Code auto mode blocks `curl … | sh`** as a security weakening. Agents should verify the pieces instead (download the asset, `codesign -v`, `lipo -archs`, HEAD the script URL) and leave the real run to the user.
- Always document uninstall in the README.

## Homebrew tap (upgrade path)
1. Repo `<user>/homebrew-tap` (the `homebrew-` prefix is required).
2. `Casks/dex.rb` with `version`, `url` (release zip), `sha256` (`shasum -a 256 Dex.zip`), `app "Dex.app"`.
3. Users: `brew install --cask <user>/tap/dex`, and updates with `brew upgrade`.
4. Brew quarantines downloads, so unsigned apps get blocked. Doing it properly needs Developer ID signing + notarization ($99/yr).
5. Every release: update `version` + `sha256` in the cask.
