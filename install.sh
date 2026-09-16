#!/bin/sh
# Installs the latest Dex release into /Applications and starts it.
set -e
tmp=$(mktemp -d)
echo "Downloading Dex..."
curl -fsSL https://github.com/gigacook/dex/releases/latest/download/Dex.zip -o "$tmp/Dex.zip"
pkill -x Dex 2>/dev/null || true
rm -rf /Applications/Dex.app
ditto -x -k "$tmp/Dex.zip" /Applications
xattr -dr com.apple.quarantine /Applications/Dex.app 2>/dev/null || true
open /Applications/Dex.app
echo "Done. Look for the lightning ring in your menu bar."
