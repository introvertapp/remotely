#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_APP="$ROOT_DIR/dist/remotely.app"
DESTINATION_DIR="/Applications"
DESTINATION_APP="$DESTINATION_DIR/remotely.app"
EXPECTED_BUNDLE_ID="com.local.remotely"
PREVIOUS_BUNDLE_ID=""
PREFERENCES_MIGRATION_FILE=""

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Built app not found at: $SOURCE_APP" >&2
  echo "Run ./scripts/build.sh first." >&2
  exit 1
fi

if ! command -v codesign >/dev/null 2>&1; then
  echo "codesign is not available. Install the Xcode Command Line Tools first." >&2
  exit 1
fi

if ! command -v ditto >/dev/null 2>&1; then
  echo "ditto is not available." >&2
  exit 1
fi

if ! command -v open >/dev/null 2>&1; then
  echo "open is not available." >&2
  exit 1
fi

INFO_PLIST="$SOURCE_APP/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "Built app is missing Contents/Info.plist." >&2
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "Unexpected bundle identifier: ${BUNDLE_ID:-<missing>}" >&2
  echo "Expected: $EXPECTED_BUNDLE_ID" >&2
  exit 1
fi

if ! codesign --verify --deep --strict "$SOURCE_APP" >/dev/null 2>&1; then
  echo "Built app failed code-signature verification; refusing to install." >&2
  exit 1
fi

# If an older remotely.app is already installed under a different bundle
# identifier, preserve its complete preferences domain without hard-coding any
# retired product identity. The migration runs once, before the old bundle is
# replaced, and is skipped for subsequent installs using the current identity.
if [[ -f "$DESTINATION_APP/Contents/Info.plist" ]]; then
  PREVIOUS_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION_APP/Contents/Info.plist" 2>/dev/null || true)"
fi

cleanup_preferences_migration() {
  if [[ -n "$PREFERENCES_MIGRATION_FILE" && -f "$PREFERENCES_MIGRATION_FILE" ]]; then
    rm -f "$PREFERENCES_MIGRATION_FILE"
  fi
}
trap cleanup_preferences_migration EXIT

# Quit only the stable installed copy if it is currently running. The app is a
# menu-bar accessory, so it may not have a Dock icon to quit manually.
RUNNING_PID="$(pgrep -f '^/Applications/remotely\.app/Contents/MacOS/remotely$' | head -n 1 || true)"
if [[ -n "$RUNNING_PID" ]]; then
  echo "Stopping installed remotely (PID $RUNNING_PID)..."
  kill "$RUNNING_PID" 2>/dev/null || true
  for _ in {1..20}; do
    if ! kill -0 "$RUNNING_PID" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$RUNNING_PID" 2>/dev/null; then
    echo "Installed remotely did not exit cleanly; stopping it now."
    kill -9 "$RUNNING_PID" 2>/dev/null || true
  fi
fi

if [[ -n "$PREVIOUS_BUNDLE_ID" && "$PREVIOUS_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  PREFERENCES_MIGRATION_FILE="$(mktemp -t remotely-preferences)"
  if /usr/bin/defaults export "$PREVIOUS_BUNDLE_ID" - > "$PREFERENCES_MIGRATION_FILE" 2>/dev/null; then
    echo "Preserving remotely preferences for the bundle-identity migration..."
  else
    rm -f "$PREFERENCES_MIGRATION_FILE"
    PREFERENCES_MIGRATION_FILE=""
  fi
fi

install_without_sudo() {
  rm -rf "$DESTINATION_APP"
  /usr/bin/ditto "$SOURCE_APP" "$DESTINATION_APP"
}

install_with_sudo() {
  echo "Administrator permission is required to update $DESTINATION_APP."
  sudo rm -rf "$DESTINATION_APP"
  sudo /usr/bin/ditto "$SOURCE_APP" "$DESTINATION_APP"
  # Keep the locally installed app owned by the current user so future personal
  # development installs normally do not need sudo again.
  sudo chown -R "$(id -u):$(id -g)" "$DESTINATION_APP"
}

mkdir -p "$DESTINATION_DIR" 2>/dev/null || true
if [[ -w "$DESTINATION_DIR" ]] && { [[ ! -e "$DESTINATION_APP" ]] || [[ -w "$DESTINATION_APP" ]]; }; then
  install_without_sudo
else
  install_with_sudo
fi

if ! codesign --verify --deep --strict "$DESTINATION_APP" >/dev/null 2>&1; then
  echo "Installed app failed code-signature verification." >&2
  exit 1
fi

INSTALLED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DESTINATION_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$INSTALLED_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "Installed app has an unexpected bundle identifier." >&2
  exit 1
fi

if [[ -n "$PREFERENCES_MIGRATION_FILE" ]]; then
  /usr/bin/defaults import "$EXPECTED_BUNDLE_ID" "$PREFERENCES_MIGRATION_FILE" >/dev/null
  echo "Migrated remotely preferences to $EXPECTED_BUNDLE_ID."
fi

echo "Installed remotely:"
echo "  $DESTINATION_APP"
echo
echo "Launching installed copy..."
/usr/bin/open "$DESTINATION_APP"
