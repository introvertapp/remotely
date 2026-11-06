#!/bin/bash
# Upload complete, verified downloads to a draft GitHub Release.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"
[[ $# == 0 ]] || { echo "Usage: $0" >&2; exit 2; }
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
output="$ROOT_DIR/dist/releases/$version"
notes="$ROOT_DIR/docs/releases/v$version.md"
repository="introvertapp/remotely"
command -v gh >/dev/null || { echo "Install GitHub CLI and run gh auth login before publishing." >&2; exit 1; }
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo "Commit the reviewed source before building and publishing." >&2; exit 1;
}
[[ -f "$notes" && -f "$output/BUILD_INFO.txt" ]] || { echo "Missing notes or build metadata." >&2; exit 1; }
source_commit="$(git rev-parse HEAD)"
grep -Fxq "Source commit: $source_commit" "$output/BUILD_INFO.txt" || { echo "Downloads were built from another commit." >&2; exit 1; }
grep -Fxq 'Source status: clean' "$output/BUILD_INFO.txt" || { echo "Downloads were built with uncommitted source." >&2; exit 1; }
for architecture in arm64 x86_64; do
  for suffix in zip dmg; do
    [[ -s "$output/remotely-$version-macos-$architecture.$suffix" ]] || {
      echo "Both architecture downloads must be built before publishing." >&2; exit 1;
    }
  done
done
"$SCRIPT_DIR/validate_release.sh" "$output"
gh auth status --hostname github.com
# Push only this release commit's branch. The default branch is reviewed via PR.
branch="$(git branch --show-current)"
[[ -n "$branch" ]] || { echo "A named release branch is required." >&2; exit 1; }
git push -u origin "$branch"
# Never overwrite an existing release or its assets; failed uploads can be
# inspected and resumed explicitly with gh release upload.
gh release create "v$version" --repo "$repository" --draft --target "$source_commit" \
  --title "remotely v$version" --notes-file "$notes" \
  "$output"/*.dmg "$output"/*.zip "$output/SHA256SUMS" \
  "$output/BUILD_INFO.txt" "$output/INSTALL.txt"
