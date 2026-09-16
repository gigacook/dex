---
name: bundled-fonts
description: Ship a custom font (e.g. JetBrains Mono) inside a macOS .app so it works without the user installing it, and use it in AppKit menus and controls.
---

# Bundled fonts in a Mac app

**Solved in Dex:** the menu uses JetBrains Mono for every user, installed or not.

**When:** any custom typeface in an AppKit/SwiftUI app built without Xcode.

## Example
```sh
J=https://cdn.jsdelivr.net/gh/JetBrains/JetBrainsMono@master
curl -fsSL $J/fonts/ttf/JetBrainsMono-Regular.ttf -o Resources/JetBrainsMono-Regular.ttf
curl -fsSL $J/fonts/ttf/JetBrainsMono-Bold.ttf    -o Resources/JetBrainsMono-Bold.ttf
curl -fsSL $J/OFL.txt                              -o Resources/JetBrainsMono-OFL.txt
```
Info.plist: `<key>ATSApplicationFontsPath</key><string>.</string>` (= fonts sit directly in `Contents/Resources/`).
```swift
func mono(_ size: CGFloat = 13, bold: Bool = false) -> NSFont {
    NSFont(name: bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", size: size)
        ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)   // fallback
}
item.attributedTitle = NSAttributedString(string: "Quit", attributes: [.font: mono()])
```

## Critical considerations
- The name for `NSFont(name:)` is the **PostScript name** (`JetBrainsMono-Regular`), not the file name. Check with `fc-scan` or Font Book → Info.
- Always add a fallback. A wrong name returns nil silently.
- Ship the license file (OFL requires it) and credit the font in the README.
- Only bundle the weights you use (~270 KB each). Skip variable fonts and italics unless needed.
- NSMenuItem: set the font through `attributedTitle`. `NSAlert` title/body text can't take custom fonts easily, so leave dialogs in the system font.
- jsdelivr `gh/<user>/<repo>@<branch>/path` works for any GitHub file. It's faster than downloading release zips.
