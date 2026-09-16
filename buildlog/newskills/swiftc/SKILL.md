---
name: swiftc
description: Compile a small native macOS app (AppKit/Carbon) from a single .swift file with no Xcode project. Use for tiny menu bar or utility apps.
---

# swiftc

**Solved in Dex:** built the whole app from one `Sources/main.swift`, with no Xcode project, SwiftPM or dependencies.

**When:** single-file or few-file tools that need nothing but Apple frameworks (Cocoa, Carbon, ServiceManagement).

## Example
```sh
swiftc -O -target arm64-apple-macos13  Sources/main.swift -o build/dex-arm64
swiftc -O -target x86_64-apple-macos13 Sources/main.swift -o build/dex-x86_64
```
Entry point: top-level code in `main.swift` (`NSApplication.shared`, set delegate, `app.run()`). Don't use `@main`.

## Critical considerations
- `-target <arch>-apple-macos<min>` sets both the architecture and the minimum OS. Keep it in sync with `LSMinimumSystemVersion` in Info.plist.
- Cross-compiling to x86_64 works on Apple Silicon with only the Command Line Tools.
- **Type inference trap:** `[(6, 8.5), (8, 4)]` becomes `[Any]`, which fails with "has no member '0'". Make one literal a Double (`6.0`) or annotate the type.
- Swift 6 compiler defaults to language mode 5, so concurrency issues are warnings, not errors. Don't add `-swift-version 6` for quick AppKit tools.
- Carbon C callbacks (`InstallEventHandler`) can't capture context. Route them through a global closure var.
- Quick API check: compile a throwaway `$TMPDIR/test.swift` and run it. That's faster than rebuilding the app.
