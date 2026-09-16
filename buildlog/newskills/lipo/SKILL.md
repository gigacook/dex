---
name: lipo
description: Merge per-architecture macOS binaries into one universal (arm64 + x86_64) binary, or inspect which architectures a binary contains.
---

# lipo

**Solved in Dex:** one download runs on both Apple Silicon and Intel Macs.

**When:** after compiling the same source for each architecture, and before placing the binary in `.app/Contents/MacOS/`.

## Example
```sh
lipo -create build/dex-arm64 build/dex-x86_64 -output build/Dex.app/Contents/MacOS/Dex
lipo -archs build/Dex.app/Contents/MacOS/Dex   # → x86_64 arm64
```

## Critical considerations
- Inputs must be the same kind of binary (both executables) built from the same source.
- Run `lipo` **before** `codesign`. Changing the binary afterwards invalidates the signature.
- The output name must match `CFBundleExecutable` in Info.plist, or the app won't launch.
- `lipo -archs` is the cheapest check that a release really is universal.
