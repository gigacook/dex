---
name: codesign
description: Ad-hoc sign a hand-assembled .app bundle so it launches on Apple Silicon and system services (login items) accept it. No paid developer account.
---

# codesign (ad-hoc)

**Solved in Dex:** made the hand-built `Dex.app` a valid signed bundle for free, so it runs on arm64 and `SMAppService` can register it.

**When:** last step before zipping any `.app` you assembled yourself.

## Example
```sh
codesign --force -s - build/Dex.app   # "-" = ad-hoc identity
codesign -v build/Dex.app             # silent + exit 0 = valid
```

## Critical considerations
- Ad-hoc ≠ Developer ID. Gatekeeper still blocks it when it arrives with the quarantine flag (browser download, Homebrew). Curl downloads have no quarantine, so they open fine.
- Real distribution without warnings needs Developer ID ($99/yr) + `codesign --options runtime -s "Developer ID Application: …"` + `xcrun notarytool submit` + `xcrun stapler staple`.
- Sign **after** every change to the bundle (binary, Info.plist, resources). Otherwise it's "code object is not signed at all" or the seal is broken.
- Arm64 binaries must be signed to run at all. The linker ad-hoc signs the bare binary, but the bundle needs its own seal.
