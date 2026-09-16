---
name: ditto
description: Zip and unzip macOS .app bundles without breaking them (keeps symlinks, permissions, signatures). Use instead of zip/unzip for apps.
---

# ditto

**Solved in Dex:** made `build/Dex.zip` for the GitHub release, and unpacked it into /Applications in `install.sh`.

**When:** any time an `.app` goes into or out of an archive.

## Example
```sh
(cd build && ditto -c -k --keepParent Dex.app Dex.zip)   # pack
ditto -x -k Dex.zip /Applications                        # unpack
```

## Critical considerations
- `--keepParent` puts `Dex.app/` inside the zip. Without it you get loose `Contents/`.
- Plain `zip -r` can drop symlinks and extended attributes and break code signatures in bigger bundles. `ditto -c -k` makes the same kind of zip as Finder's "Compress".
- `ditto -x -k` into /Applications merges with an existing app. `rm -rf` the old one first for a clean install.
