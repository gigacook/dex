---
name: gh-cli
description: Create a public GitHub repo from a local folder, push, and publish a release with a downloadable binary using the gh CLI. One command each.
---

# gh CLI (repo + release)

**Solved in Dex:** went from a local folder to a public repo + v1.0.0 release with `Dex.zip` attached in two commands.

**When:** shipping any project with a built artifact people download.

## Example
```sh
gh auth status                                   # check login first
gh repo view gigacook/dex                        # error = name is free
git init -b main && git add -A && git commit -m "…"
gh repo create gigacook/dex --public --source . --push --description "…"
gh release create v1.0.0 build/Dex.zip --title "Dex 1.0.0" --notes "First release."
```
Stable download URL (always the newest release):
`https://github.com/<user>/<repo>/releases/latest/download/<asset-name>`

## Critical considerations
- Add build outputs to `.gitignore` (`build/`). Binaries go in releases, not in git.
- **Keep the asset name the same** (`Dex.zip`) in every release, or the `latest/download` URL in install scripts breaks.
- New version: bump `CFBundleShortVersionString`, rebuild, then `gh release create v1.0.1 build/Dex.zip`.
- `--source . --push` needs at least one commit, or the push fails.
- Raw files (install scripts) are served at `https://raw.githubusercontent.com/<user>/<repo>/main/<file>`. The CDN can lag ~1–5 min after a push.
