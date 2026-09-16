#!/bin/sh
# Builds a universal (Apple Silicon + Intel) Dex.app and zips it into build/Dex.zip
set -e
cd "$(dirname "$0")"
rm -rf build && mkdir -p build/Dex.app/Contents/MacOS
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13" Sources/main.swift -o "build/dex-$arch"
done
lipo -create build/dex-arm64 build/dex-x86_64 -output build/Dex.app/Contents/MacOS/Dex
cp Info.plist build/Dex.app/Contents/
codesign --force -s - build/Dex.app
(cd build && ditto -c -k --keepParent Dex.app Dex.zip)
echo "Built build/Dex.app and build/Dex.zip"
