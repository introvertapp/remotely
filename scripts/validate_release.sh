#!/bin/bash
# Validate the actual downloads, not just their source configuration.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/Resources/Info.plist")"
validate_app() {
  local app="$1" architecture="$2" executable="$1/Contents/MacOS/remotely" linked notice
  [[ -x "$executable" ]] || fail "Missing executable: $app"
  [[ "$(lipo -archs "$executable")" == "$architecture" ]] || fail "Wrong architecture: $app"
  [[ "$(plist_value "$app" CFBundleIdentifier)" == com.local.remotely ]] || fail "Wrong app identity"
  [[ "$(plist_value "$app" CFBundleShortVersionString)" == "$version" ]] || fail "Wrong version"
  [[ "$(plist_value "$app" CFBundleVersion)" == "$build_number" ]] || fail "Wrong build number"
  [[ "$(plist_value "$app" LSMinimumSystemVersion)" == 14.0 ]] || fail "Wrong minimum macOS"
  plutil -lint "$app/Contents/Info.plist" >/dev/null
  [[ "$(xcrun vtool -show-build "$executable" | awk '/minos/ {print $2}')" == 14.0 ]] || fail "Executable deployment target differs from macOS 14"
  codesign --verify --deep --strict "$app"
  codesign -dv --verbose=4 "$app" 2>&1 | grep -F 'Signature=adhoc' >/dev/null || fail "Release must be ad-hoc signed"
  [[ -s "$app/Contents/Resources/AppIcon.icns" ]] || fail "Missing icon"
  cmp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/THIRD_PARTY_NOTICES.md" || fail "Missing or outdated notices"
  for notice in "$ROOT_DIR/Resources/ThirdParty/"*; do
    cmp "$notice" "$app/Contents/Resources/ThirdParty/$(basename "$notice")" || fail "License files differ"
  done
  [[ -s "$app/Contents/Resources/ThirdParty/SwiftProtobuf-PrivacyInfo.xcprivacy" ]] || fail "Missing SwiftProtobuf privacy manifest"
  [[ -d "$app/Contents/Resources/swift-crypto_Crypto.bundle" ]] || fail "Missing SwiftCrypto resource bundle"
  while IFS= read -r linked; do
    case "$linked" in /System/Library/*|/usr/lib/*) ;; *) fail "Non-system runtime dependency: $linked" ;; esac
  done < <(otool -L "$executable" | tail -n +2 | awk '{print $1}')
  # Launch only a command-line version check: no UI or Apple TV connection.
  if [[ "$architecture" == "$(uname -m)" ]]; then
    [[ "$("$executable" --version)" == "remotely $version ($build_number)" ]] || fail "Version smoke test failed"
  elif [[ "$architecture" == x86_64 && "$(uname -m)" == arm64 ]] && /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
    [[ "$(/usr/bin/arch -x86_64 "$executable" --version)" == "remotely $version ($build_number)" ]] || fail "Intel smoke test failed"
  else
    echo "Runtime smoke test skipped for $architecture: compatible execution environment unavailable."
  fi
  echo "App validation ($architecture): PASS"
}
if [[ "${1:-}" == --app ]]; then
  [[ $# == 4 && "$3" == --arch && ( "$4" == arm64 || "$4" == x86_64 ) ]] || fail "Usage: $0 --app PATH --arch arm64|x86_64"
  validate_app "$2" "$4"
  exit 0
fi
[[ $# == 1 && -d "$1" ]] || fail "Usage: $0 RELEASE_DIRECTORY"
output="$(cd "$1" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/remotely-release-check.XXXXXX")"
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then hdiutil detach -quiet "$scratch/mount" || true; fi
  rm -rf "$scratch"
}
trap cleanup EXIT
[[ -s "$output/SHA256SUMS" && -s "$output/BUILD_INFO.txt" && -s "$output/INSTALL.txt" ]] || fail "Missing release metadata"
(cd "$output" && shasum -a 256 -c SHA256SUMS) || fail "Checksum verification failed"
for artifact in "$output"/*.zip "$output"/*.dmg "$output/BUILD_INFO.txt" "$output/INSTALL.txt"; do
  [[ -f "$artifact" ]] || continue
  expected_digest="$(shasum -a 256 "$artifact" | awk '{print $1}')"
  grep -Eq "^$expected_digest  (\./)?$(basename "$artifact" | sed 's/\./\\./g')$" "$output/SHA256SUMS" || fail "Unlisted or changed artifact: $artifact"
done
count=0
for architecture in arm64 x86_64; do
  name="remotely-$version-macos-$architecture"
  if [[ ! -e "$output/$name.zip" && ! -e "$output/$name.dmg" ]]; then continue; fi
  [[ -f "$output/$name.zip" && -f "$output/$name.dmg" ]] || fail "Incomplete $architecture downloads"
  mkdir -p "$scratch/$architecture" "$scratch/mount"
  ditto -x -k "$output/$name.zip" "$scratch/$architecture"
  validate_app "$scratch/$architecture/remotely.app" "$architecture"
  hdiutil verify -quiet "$output/$name.dmg"
  hdiutil attach -quiet -readonly -nobrowse -mountpoint "$scratch/mount" "$output/$name.dmg"
  mounted=true
  validate_app "$scratch/mount/remotely.app" "$architecture"
  [[ -s "$scratch/mount/INSTALL.txt" && "$(readlink "$scratch/mount/Applications")" == /Applications ]] || fail "DMG installation contents missing"
  hdiutil detach -quiet "$scratch/mount"
  mounted=false
  count=$((count + 1))
done
[[ "$count" -gt 0 ]] || fail "No downloads found"
echo "Release archive, disk image, and checksum validation: PASS"
