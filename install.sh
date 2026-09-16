#!/bin/sh
# Installs the latest Dex release into /Applications, adds a `dex` terminal command, and starts it.
set -e
tmp=$(mktemp -d)
echo "Downloading Dex..."
curl -fsSL https://github.com/gigacook/dex/releases/latest/download/Dex.zip -o "$tmp/Dex.zip"
pkill -x Dex 2>/dev/null || true
rm -rf /Applications/Dex.app
ditto -x -k "$tmp/Dex.zip" /Applications
xattr -dr com.apple.quarantine /Applications/Dex.app 2>/dev/null || true

# `dex` command: starts Dex if autostart failed or it was quit
case "$SHELL" in */bash) rc="$HOME/.bash_profile" ;; *) rc="$HOME/.zshrc" ;; esac
grep -qs 'alias dex=' "$rc" || echo 'alias dex="open -a Dex"' >> "$rc"

open /Applications/Dex.app
echo "Done. Look for the lightning ring in your menu bar."
echo "If it's ever missing: type 'dex' in a new terminal, or search Dex in Spotlight."
