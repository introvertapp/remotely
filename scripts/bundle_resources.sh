#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 2 && -d "$1/Contents/Resources" && -d "$2" ]] || {
  echo "Usage: $0 APP_PATH SWIFT_BIN_DIRECTORY" >&2; exit 2;
}
resources="$1/Contents/Resources"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$resources/THIRD_PARTY_NOTICES.md"
ditto "$ROOT_DIR/Resources/ThirdParty" "$resources/ThirdParty"
# Preserve SwiftPM resource bundles, including dependency privacy manifests.
for bundle in "$2"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  ditto "$bundle" "$resources/$(basename "$bundle")"
done
# The runtime-only SwiftProtobuf manifest excludes its SwiftPM resources.
# Retain its supplied privacy declaration explicitly alongside its notices.
cp "$ROOT_DIR/Vendor/swift-protobuf/Sources/SwiftProtobuf/PrivacyInfo.xcprivacy" \
  "$resources/ThirdParty/SwiftProtobuf-PrivacyInfo.xcprivacy"
