#!/bin/bash
# Produce independent Apple Silicon and Intel downloads. Never installs an app.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

ARCHITECTURES=(arm64 x86_64)
case "${1:-}" in
  "") ;;
  --arch)
    [[ $# == 2 && ( "$2" == arm64 || "$2" == x86_64 ) ]] || {
      echo "Usage: $0 [--arch arm64|x86_64]" >&2; exit 2;
    }
    ARCHITECTURES=("$2") ;;
  *) echo "Usage: $0 [--arch arm64|x86_64]" >&2; exit 2 ;;
esac

[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo "Commit the reviewed source before building release downloads." >&2; exit 1;
}

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)"
output="$ROOT_DIR/dist/releases/$version"
[[ -f Package.resolved ]] || { echo "Package.resolved is required." >&2; exit 1; }
mkdir -p "$ROOT_DIR/.build/release-logs" "$output"
# Keep existing completed artifacts safe from accidental overwrite.
for architecture in "${ARCHITECTURES[@]}"; do
  for suffix in zip dmg; do
    [[ ! -e "$output/remotely-$version-macos-$architecture.$suffix" ]] || {
      echo "Release artifact already exists. Move it aside before rebuilding: $output" >&2; exit 1;
    }
  done
done

lock_digest="$(shasum -a 256 Package.resolved | awk '{print $1}')"
if [[ -f "$output/BUILD_INFO.txt" ]]; then
  grep -Fxq "Source commit: $(git rev-parse HEAD)" "$output/BUILD_INFO.txt" &&
    grep -Fxq "Package.resolved SHA256: $lock_digest" "$output/BUILD_INFO.txt" || {
      echo "Existing downloads were built from different source. Move $output aside." >&2; exit 1;
    }
fi
echo "Preparing pinned dependencies..."
REMOTELY_LOG_DIR="$ROOT_DIR/.build/release-logs" "$SCRIPT_DIR/build.sh" --prepare-only \
  > "$ROOT_DIR/.build/release-logs/dependencies.log" 2>&1 || {
    tail -n 40 "$ROOT_DIR/.build/release-logs/dependencies.log" >&2; exit 1;
  }
[[ "$lock_digest" == "$(shasum -a 256 Package.resolved | awk '{print $1}')" ]] || {
  echo "Dependency resolution changed the lockfile; review it before releasing." >&2; exit 1;
}

staging="$(mktemp -d "$ROOT_DIR/.build/release-staging.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
for architecture in "${ARCHITECTURES[@]}"; do
  echo "Building remotely $version for $architecture..."
  swift build -c release --arch "$architecture" --force-resolved-versions \
    > "$ROOT_DIR/.build/release-logs/$architecture.log" 2>&1 || {
      tail -n 60 "$ROOT_DIR/.build/release-logs/$architecture.log" >&2; exit 1;
    }
  bin_dir="$(swift build -c release --arch "$architecture" --force-resolved-versions --show-bin-path)"
  destination="$staging/$architecture"
  app="$destination/remotely.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin_dir/remotely" "$app/Contents/MacOS/remotely"
  cp Resources/Info.plist "$app/Contents/Info.plist"
  cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
  "$SCRIPT_DIR/bundle_resources.sh" "$app" "$bin_dir"
  cp docs/INSTALL.txt "$destination/INSTALL.txt"
  ln -s /Applications "$destination/Applications"

  # Ad-hoc signing seals the app for macOS, including Apple Silicon. It does
  # not identify a developer or assert Apple approval. No certificate required.
  codesign --force --sign - --timestamp=none "$app"
  "$SCRIPT_DIR/validate_release.sh" --app "$app" --arch "$architecture"

  name="remotely-$version-macos-$architecture"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$name.zip.partial"
  mv "$output/$name.zip.partial" "$output/$name.zip"
  echo "Creating $architecture disk image..."
  hdiutil create -quiet -format UDZO -volname "remotely $version ($architecture)" \
    -srcfolder "$destination" "$staging/$name.dmg"
  mv "$staging/$name.dmg" "$output/$name.dmg"
done

{
  echo "remotely $version ($build_number)"
  echo "Source commit: $(git rev-parse HEAD)"
  echo "Source status: clean"
  echo "Built at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "Signing: ad-hoc; no Developer ID; not notarized"
  echo "Minimum macOS: $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
  echo "Package.resolved SHA256: $lock_digest"
  swift --version
  xcodebuild -version
  echo
  echo "Dependency lockfile:"
  cat Package.resolved
} > "$output/BUILD_INFO.txt"
cp docs/INSTALL.txt "$output/INSTALL.txt"
(
  cd "$output"
  shasum -a 256 ./*.zip ./*.dmg BUILD_INFO.txt INSTALL.txt > SHA256SUMS
)
"$SCRIPT_DIR/validate_release.sh" "$output"
echo "Release downloads are ready: $output"
