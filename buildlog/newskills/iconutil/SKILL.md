---
name: iconutil
description: Generate a macOS app icon (.icns) from code with no design tools. Render PNGs with a Swift script, then convert with iconutil. Makes the app look right in Finder, Spotlight and Launchpad.
---

# iconutil (+ Swift PNG renderer)

**Solved in Dex:** a green bolt-in-ring app icon for Spotlight/Finder, drawn in ~40 lines. No Figma, no asset catalog.

**When:** any hand-built `.app` (without an icon it shows a blank generic app).

## Example
```sh
swift tools/make-icon.swift                                        # writes build/AppIcon.iconset/*.png
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns   # commit the .icns
```
Info.plist: `<key>CFBundleIconFile</key><string>AppIcon</string>`. build.sh copies it to `Contents/Resources/`.

Render one size: `NSBitmapImageRep(pixelsWide:…)` → `NSGraphicsContext(bitmapImageRep:)` → draw `NSBezierPath` → `rep.representation(using: .png, …)`.

## Critical considerations
- The iconset folder **must** end in `.iconset`, and files must be named exactly `icon_{16,32,128,256,512}x{same}.png` plus `@2x` versions (double the pixels).
- Leave ~8% transparent margin and use rounded corners to match macOS Big Sur+ icon style.
- Finder/Spotlight cache icons. After changing one: `touch /Applications/Dex.app` or `killall Dock`.
- Generate once and commit the `.icns`. Don't regenerate on every build.
- Spotlight indexes any `.app` in /Applications automatically. No extra setup.
