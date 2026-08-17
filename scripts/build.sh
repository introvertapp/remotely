#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

PROTOCOL_CORE_REF="052d9a9a0416d577119316ea813aa3b822b408e5"
PROTOCOL_CORE_URL="https://github.com/nickustinov/itsytv-core.git"
SWIFT_PROTOBUF_TAG="1.31.0"
SIGNING_IDENTITY_NAME="${REMOTELY_SIGNING_IDENTITY:-remotely Local Signing}"
VENDOR_DIR="$ROOT_DIR/Vendor"
CORE_DIR="$VENDOR_DIR/ProtocolCore"
PROTOBUF_DIR="$VENDOR_DIR/swift-protobuf"
APP="$ROOT_DIR/dist/remotely.app"
LOG_DIR="$HOME/Library/Logs/remotely"
LOG_FILE="$LOG_DIR/build.log"
BAR_WIDTH=28
USE_PROGRESS_UI=true
SELF_TEST_PROGRESS=false
if [[ "${1:-}" == "--self-test-progress" ]]; then
  SELF_TEST_PROGRESS=true
  LOG_FILE="${TMPDIR:-/tmp}/remotely-build-progress-selftest-$$.log"
fi

mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"
{
  echo "remotely build log"
  echo "Started: $(date)"
  echo "Source: $ROOT_DIR"
  echo
} >> "$LOG_FILE"

if [[ ! -t 1 || "${TERM:-}" == "dumb" ]]; then
  USE_PROGRESS_UI=false
fi

repeat_char() {
  local count="$1"
  local char="$2"
  local result=""
  local i
  for (( i = 0; i < count; i++ )); do
    result+="$char"
  done
  printf '%s' "$result"
}

cell_bar() {
  local filled="$1"
  if (( filled < 0 )); then filled=0; fi
  if (( filled > BAR_WIDTH )); then filled="$BAR_WIDTH"; fi
  local empty=$(( BAR_WIDTH - filled ))
  printf '[%s%s]' "$(repeat_char "$filled" '█')" "$(repeat_char "$empty" ' ')"
}

STAGE_LABELS=(
  "Checking build environment"
  "Validating source"
  "Fetching external dependencies"
  "Building release"
  "Signing application"
  "Installing and launching"
)
STAGE_STATES=("pending" "pending" "pending" "pending" "pending" "pending")
STAGE_PROGRESS=(0 0 0 0 0 0)
# Progress is deliberately monotonic. Each running stage fills left-to-right at
# a conservative stage-specific cadence, then snaps to full only when the stage
# actually succeeds. No numeric percentage is claimed for operations (Git,
# SwiftPM, codesign) that do not expose one unified reliable percentage.
STAGE_TICK_DIVISORS=(2 3 12 22 3 3)
DASHBOARD_RENDERED=false
DASHBOARD_LINES=${#STAGE_LABELS[@]}
CURSOR_HIDDEN=false

stage_marker() {
  case "$1" in
    done) printf '[✓]' ;;
    running) printf '[ ]' ;;
    failed) printf '[✗]' ;;
    *) printf '[ ]' ;;
  esac
}

stage_bar() {
  local index="$1"
  case "${STAGE_STATES[$index]}" in
    done) cell_bar "$BAR_WIDTH" ;;
    running|failed) cell_bar "${STAGE_PROGRESS[$index]}" ;;
    *) cell_bar 0 ;;
  esac
}

hide_cursor() {
  if [[ "$USE_PROGRESS_UI" == true && "$CURSOR_HIDDEN" == false ]]; then
    printf '\033[?25l'
    CURSOR_HIDDEN=true
  fi
}

show_cursor() {
  if [[ "$CURSOR_HIDDEN" == true ]]; then
    printf '\033[?25h'
    CURSOR_HIDDEN=false
  fi
}

cleanup_terminal() {
  show_cursor
}
trap cleanup_terminal EXIT INT TERM

render_dashboard() {
  local i
  if [[ "$USE_PROGRESS_UI" == true ]]; then
    hide_cursor
    if [[ "$DASHBOARD_RENDERED" == true ]]; then
      # The cursor is hidden while rows are rewritten, preventing the visible
      # up/down cursor bounce seen with the earlier dashboard implementation.
      printf '\033[%dA' "$DASHBOARD_LINES"
    fi

    for (( i = 0; i < ${#STAGE_LABELS[@]}; i++ )); do
      printf '\r\033[2K%s %-31s %s\n' \
        "$(stage_marker "${STAGE_STATES[$i]}")" \
        "${STAGE_LABELS[$i]}" \
        "$(stage_bar "$i")"
    done
    DASHBOARD_RENDERED=true
  fi
}

show_initial_dashboard() {
  if [[ "$USE_PROGRESS_UI" == true ]]; then
    render_dashboard
  else
    local i
    for (( i = 0; i < ${#STAGE_LABELS[@]}; i++ )); do
      printf '[ ] %s\n' "${STAGE_LABELS[$i]}"
    done
  fi
}

show_failure_details() {
  local label="$1"
  show_cursor
  echo >&2
  echo "Build failed during: $label" >&2
  echo "Build details (last 35 lines):" >&2
  tail -n 35 "$LOG_FILE" >&2 || true
  echo >&2
  echo "Full log: $LOG_FILE" >&2
}

advance_stage_progress() {
  local stage_index="$1"
  local tick="$2"
  local divisor="${STAGE_TICK_DIVISORS[$stage_index]}"
  local target=$(( tick / divisor ))
  local max_running=$(( BAR_WIDTH - 1 ))
  if (( target > max_running )); then target="$max_running"; fi
  if (( target > STAGE_PROGRESS[$stage_index] )); then
    STAGE_PROGRESS[$stage_index]="$target"
  fi
}

run_step() {
  local stage_index="$1"
  shift
  local label="${STAGE_LABELS[$stage_index]}"

  STAGE_STATES[$stage_index]="running"
  STAGE_PROGRESS[$stage_index]=0
  if [[ "$USE_PROGRESS_UI" == true ]]; then
    render_dashboard
  else
    printf '[ ] %s\n' "$label"
  fi

  {
    echo
    echo "===== $label ====="
    echo "Started: $(date)"
  } >> "$LOG_FILE"

  ( "$@" ) >> "$LOG_FILE" 2>&1 &
  local pid=$!
  local tick=0
  while kill -0 "$pid" 2>/dev/null; do
    tick=$(( tick + 1 ))
    advance_stage_progress "$stage_index" "$tick"
    if [[ "$USE_PROGRESS_UI" == true ]]; then
      render_dashboard
    fi
    sleep 0.25
  done

  local step_exit_code=0
  if wait "$pid"; then
    step_exit_code=0
  else
    step_exit_code=$?
  fi

  if (( step_exit_code != 0 )); then
    STAGE_STATES[$stage_index]="failed"
    if [[ "$USE_PROGRESS_UI" == true ]]; then
      render_dashboard
    else
      printf '[✗] %s\n' "$label" >&2
    fi
    show_failure_details "$label"
    exit "$step_exit_code"
  fi

  echo "Completed: $(date)" >> "$LOG_FILE"
  STAGE_PROGRESS[$stage_index]="$BAR_WIDTH"
  STAGE_STATES[$stage_index]="done"
  if [[ "$USE_PROGRESS_UI" == true ]]; then
    render_dashboard
  else
    printf '[✓] %s\n' "$label"
  fi
}

preflight_environment() {
  local tool
  for tool in swift git codesign security patch ditto open; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "$tool is not available. Install Xcode or the Xcode Command Line Tools first." >&2
      return 1
    fi
  done
  if [[ ! -x "$SCRIPT_DIR/validate_source.sh" ]]; then
    echo "validate_source.sh is missing or not executable." >&2
    return 1
  fi
  if [[ ! -x "$SCRIPT_DIR/install.sh" ]]; then
    echo "install.sh is missing or not executable." >&2
    return 1
  fi
  if [[ ! -x "$SCRIPT_DIR/setup_signing.sh" ]]; then
    echo "setup_signing.sh is missing or not executable." >&2
    return 1
  fi
  swift --version
}

validate_sources() {
  "$SCRIPT_DIR/validate_source.sh"
}

clone_exact_revision() {
  local url="$1"
  local revision="$2"
  local destination="$3"

  rm -rf "$destination"
  mkdir -p "$destination"
  git -C "$destination" init -q
  git -C "$destination" remote add origin "$url"
  # Public source checkout only. Disable interactive credential prompting so a
  # personal build can never unexpectedly ask for a GitHub login.
  GIT_TERMINAL_PROMPT=0 git -c credential.helper= -C "$destination" fetch -q --depth 1 origin "$revision"
  git -c advice.detachedHead=false -C "$destination" checkout -q --detach FETCH_HEAD
}

clone_exact_tag() {
  local url="$1"
  local tag="$2"
  local destination="$3"

  rm -rf "$destination"
  GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" "$url" "$destination"
}

prepare_vendor_sources() {
  mkdir -p "$VENDOR_DIR"

  # Pin the exact protocol-core revision validated for this release. Do not
  # follow moving `main` during a release build; upstream changes are reviewed
  # deliberately before this pin moves.
  echo "Fetching Apple TV protocol core source..."
  clone_exact_revision "$PROTOCOL_CORE_URL" "$PROTOCOL_CORE_REF" "$CORE_DIR"
  local resolved_core_rev="$(git -C "$CORE_DIR" rev-parse HEAD)"
  echo "Resolved protocol core revision: $resolved_core_rev"

  if [[ ! -d "$PROTOBUF_DIR/.git" ]] || [[ "$(git -C "$PROTOBUF_DIR" describe --tags --exact-match 2>/dev/null || true)" != "$SWIFT_PROTOBUF_TAG" ]]; then
    echo "Fetching SwiftProtobuf $SWIFT_PROTOBUF_TAG source..."
    clone_exact_tag "https://github.com/apple/swift-protobuf.git" "$SWIFT_PROTOBUF_TAG" "$PROTOBUF_DIR"
  fi

  # SwiftProtobuf 1.31 includes an optional protoc binary target. SwiftPM may
  # download that public GitHub Release artifact even though this app only needs
  # the runtime library. Replace the checkout manifest with a runtime-only local
  # package so no binary artifact or GitHub credentials are involved.
  cat > "$PROTOBUF_DIR/Package.swift" <<'RUNTIME_MANIFEST'
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SwiftProtobuf",
    products: [
        .library(name: "SwiftProtobuf", targets: ["SwiftProtobuf"])
    ],
    targets: [
        .target(
            name: "SwiftProtobuf",
            path: "Sources/SwiftProtobuf",
            exclude: ["CMakeLists.txt", "PrivacyInfo.xcprivacy"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
RUNTIME_MANIFEST

  # Point the protocol engine at our local runtime-only SwiftProtobuf
  # source package. The upstream manifest uses this exact one-line
  # declaration; fail below if it ever changes rather than guessing.
  sed -i '' \
    's#\.package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0")#.package(path: "../swift-protobuf")#' \
    "$CORE_DIR/Package.swift"

  if grep -q 'github.com/apple/swift-protobuf' "$CORE_DIR/Package.swift"; then
    echo "SwiftProtobuf URL remains in patched protocol-core Package.swift; refusing to continue." >&2
    exit 1
  fi

  if grep -qE 'binaryTarget|protoc-artifactbundle' "$PROTOBUF_DIR/Package.swift"; then
    echo "Runtime-only SwiftProtobuf manifest unexpectedly contains a binary target." >&2
    exit 1
  fi

  # Keep all runtime identity owned by remotely. Locate upstream implementation
  # files by role rather than adopting the dependency's directory naming.
  local keychain_storage="$(find "$CORE_DIR/Sources" -type f -path '*/Crypto/KeychainStorage.swift' -print -quit)"
  if [[ -z "$keychain_storage" || ! -f "$keychain_storage" ]]; then
    echo "Protocol core no longer contains the expected KeychainStorage.swift; refusing to guess." >&2
    exit 1
  fi

  if ! grep -Eq 'private static let service = "[^"]+\.credentials"' "$keychain_storage"; then
    echo "Protocol core Keychain service declaration changed; refusing to guess." >&2
    exit 1
  fi
  sed -E -i '' \
    's/private static let service = "[^"]+\.credentials"/private static let service = "com.local.remotely.credentials"/' \
    "$keychain_storage"
  grep -q 'com.local.remotely.credentials' "$keychain_storage" || { echo "remotely Keychain namespace was not applied; refusing to continue." >&2; exit 1; }

  # The MRP client announces a friendly name to Apple TV. Force that runtime
  # identity to remotely without depending on the upstream project's branding.
  local mrp_manager="$(find "$CORE_DIR/Sources" -type f -path '*/MRP/MRPManager.swift' -print -quit)"
  if [[ -z "$mrp_manager" || ! -f "$mrp_manager" ]]; then
    echo "Protocol core no longer contains the expected MRPManager.swift; refusing to guess." >&2
    exit 1
  fi
  if ! grep -Eq 'deviceInfo\.name = "[^"]+"' "$mrp_manager"; then
    echo "Protocol core MRP client-name declaration changed; refusing to guess." >&2
    exit 1
  fi
  sed -E -i '' \
    's/deviceInfo\.name = "[^"]+"/deviceInfo.name = "remotely"/' \
    "$mrp_manager"
  grep -q 'deviceInfo.name = "remotely"' "$mrp_manager" || { echo "remotely MRP client name was not applied; refusing to continue." >&2; exit 1; }

  # v1.9.9 retains the validated Now Playing content correction: a current
  # queue item remains valid when textual metadata is temporarily absent but
  # playback/timing/artwork state is present.
  local content_patch="$ROOT_DIR/Patches/protocol-core-now-playing-content.patch"
  if [[ ! -f "$content_patch" ]]; then
    echo "Now Playing content-validity patch is missing; refusing to continue." >&2
    exit 1
  fi
  echo "Applying Now Playing content-validity correction..."
  if ! patch -d "$(dirname "$mrp_manager")" -p0 --forward --batch < "$content_patch"; then
    echo "Protocol core changed and the content-validity patch no longer applies cleanly; refusing to guess." >&2
    exit 1
  fi
  grep -q 'let hasTextContent =' "$mrp_manager" || { echo "Core textual-content predicate missing after patch." >&2; exit 1; }
  grep -q 'let hasPlaybackContent =' "$mrp_manager" || { echo "Core playback-content predicate missing after patch." >&2; exit 1; }
  grep -q 'meta.hasDuration ||' "$mrp_manager" || { echo "Core duration validity signal missing after patch." >&2; exit 1; }
  grep -q 'meta.hasElapsedTime ||' "$mrp_manager" || { echo "Core elapsed-time validity signal missing after patch." >&2; exit 1; }
  grep -q 'meta.hasPlaybackRate ||' "$mrp_manager" || { echo "Core playback-rate validity signal missing after patch." >&2; exit 1; }
  grep -q 'item.hasArtworkData' "$mrp_manager" || { echo "Core artwork validity signal missing after patch." >&2; exit 1; }
  grep -q 'let hasContent = hasTextContent || hasPlaybackContent' "$mrp_manager" || { echo "Core combined Now Playing validity predicate missing after patch." >&2; exit 1; }

  # v1.9.9 retains the validated MRP player isolation correction. tvOS can
  # publish SetState for several clients during one session; capabilities, queue
  # state and playback state must remain scoped to the client that is actually
  # playing instead of being overwritten by background Music/AirPlay clients.
  local player_isolation_patch="$ROOT_DIR/Patches/protocol-core-player-isolation.patch"
  if [[ ! -f "$player_isolation_patch" ]]; then
    echo "MRP player-isolation patch is missing; refusing to continue." >&2
    exit 1
  fi
  echo "Applying MRP player-state isolation correction..."
  if ! patch -d "$(dirname "$mrp_manager")" -p0 --forward --batch < "$player_isolation_patch"; then
    echo "Protocol core changed and the player-isolation patch no longer applies cleanly; refusing to guess." >&2
    exit 1
  fi
  grep -q 'private var commandsByBundleID:' "$mrp_manager" || { echo "Core per-client command cache missing after patch." >&2; exit 1; }
  grep -q 'private var skipIntervalsByBundleID:' "$mrp_manager" || { echo "Core per-client skip interval cache missing after patch." >&2; exit 1; }
  grep -q 'private var currentPlayerBundleID:' "$mrp_manager" || { echo "Core active-player client selector missing after patch." >&2; exit 1; }
  grep -q 'private func activatePlayer(bundleID: String)' "$mrp_manager" || { echo "Core player activation helper missing after patch." >&2; exit 1; }
  grep -q 'guard shouldApplyPlaybackState else { return }' "$mrp_manager" || { echo "Core inactive-player playback-state guard missing after patch." >&2; exit 1; }
  grep -q 'bundleID != currentPlayerBundleID' "$mrp_manager" || { echo "Core inactive-player content-update guard missing after patch." >&2; exit 1; }

  # Opening-content auto-skip uses the AVKit main-content boundary preserved in
  # opaque MediaRemote metadata. Apply this only after player isolation so its
  # queue/update hooks are scoped to the active playback client.
  local main_content_patch="$ROOT_DIR/Patches/protocol-core-main-content-start.patch"
  if [[ ! -f "$main_content_patch" ]]; then
    echo "MRP main-content auto-skip patch is missing; refusing to continue." >&2
    exit 1
  fi
  echo "Applying MRP main-content auto-skip support..."
  if ! patch -d "$(dirname "$mrp_manager")" -p0 --forward --batch < "$main_content_patch"; then
    echo "Protocol core changed and the main-content auto-skip patch no longer applies cleanly; refusing to guess." >&2
    exit 1
  fi
  grep -q 'import SwiftProtobuf' "$mrp_manager" || { echo "Core SwiftProtobuf import missing after main-content patch." >&2; exit 1; }
  grep -q 'public var autoSkipOpeningContentEnabled = false' "$mrp_manager" || { echo "Core auto-skip preference gate missing after patch." >&2; exit 1; }
  grep -q 'avkt/TVRMainContentStartTime' "$mrp_manager" || { echo "Core AVKit main-content metadata key missing after patch." >&2; exit 1; }
  grep -q 'position <= 10' "$mrp_manager" || { echo "Core playback-start safety window missing after patch." >&2; exit 1; }
  grep -q 'autoSkipOpeningCompletedKeys.insert(key)' "$mrp_manager" || { echo "Core one-shot auto-skip guard missing after patch." >&2; exit 1; }
  grep -q 'self.seekToPosition(currentTarget)' "$mrp_manager" || { echo "Core main-content seek missing after patch." >&2; exit 1; }

  # Normalize structured MediaRemote TV metadata at the protocol boundary so
  # remotely renders the same title / season-episode / secondary-line model
  # regardless of which playback app supplied the queue.
  local media_metadata_patch="$ROOT_DIR/Patches/protocol-core-media-metadata.patch"
  if [[ ! -f "$media_metadata_patch" ]]; then
    echo "MRP supplemental media-metadata patch is missing; refusing to continue." >&2
    exit 1
  fi
  echo "Applying MRP supplemental media metadata support..."
  if ! patch -d "$(dirname "$mrp_manager")" -p0 --forward --batch < "$media_metadata_patch"; then
    echo "Protocol core changed and the media-metadata patch no longer applies cleanly; refusing to guess." >&2
    exit 1
  fi
  grep -q 'public var nowPlayingSeasonNumber: Int?' "$mrp_manager" || { echo "Core season-number metadata surface missing after patch." >&2; exit 1; }
  grep -q 'public var nowPlayingEpisodeNumber: Int?' "$mrp_manager" || { echo "Core episode-number metadata surface missing after patch." >&2; exit 1; }
  grep -q 'public var nowPlayingEpisodeTitle: String?' "$mrp_manager" || { echo "Core episode-title metadata surface missing after patch." >&2; exit 1; }
  grep -q 'mdta/com.apple.hls.episode-title' "$mrp_manager" || { echo "Core HLS episode-title key missing after patch." >&2; exit 1; }
  grep -q 'avkt/com.apple.avkit.seasonNumber' "$mrp_manager" || { echo "Core AVKit season-number key missing after patch." >&2; exit 1; }
  grep -q 'avkt/com.apple.avkit.episodeNumber' "$mrp_manager" || { echo "Core AVKit episode-number key missing after patch." >&2; exit 1; }

  # v1.1.3 follows MRP's explicit now-playing client/player lifecycle so app
  # switches retire stale sessions immediately. It also protobuf-merges partial
  # updates only for the same content-item identity, preserving descriptive
  # episode metadata through Apple TV ad/recap timing updates.
  local session_lifecycle_patch="$ROOT_DIR/Patches/protocol-core-session-lifecycle.patch"
  if [[ ! -f "$session_lifecycle_patch" ]]; then
    echo "MRP session-lifecycle patch is missing; refusing to continue." >&2
    exit 1
  fi
  echo "Applying MRP session lifecycle and partial-metadata correction..."
  if ! patch -d "$(dirname "$mrp_manager")" -p0 --forward --batch < "$session_lifecycle_patch"; then
    echo "Protocol core changed and the session-lifecycle patch no longer applies cleanly; refusing to guess." >&2
    exit 1
  fi
  grep -q 'case 46:' "$mrp_manager" || { echo "Core SetNowPlayingClient lifecycle handling missing after patch." >&2; exit 1; }
  grep -q 'case 47:' "$mrp_manager" || { echo "Core SetNowPlayingPlayer lifecycle handling missing after patch." >&2; exit 1; }
  grep -q 'case 53:' "$mrp_manager" || { echo "Core RemoveClient lifecycle handling missing after patch." >&2; exit 1; }
  grep -q 'case 54:' "$mrp_manager" || { echo "Core RemovePlayer lifecycle handling missing after patch." >&2; exit 1; }
  [[ "$(grep -c 'firstLengthDelimitedField(number: 1, in: payload).flatMap' "$mrp_manager")" -ge 4 ]] || { echo "Core lifecycle wrapper decoding missing after patch." >&2; exit 1; }
  grep -q 'private var currentPlayerIdentifier: String?' "$mrp_manager" || { echo "Core player identity isolation missing after patch." >&2; exit 1; }
  grep -q 'private var explicitlySelectedBundleID: String?' "$mrp_manager" || { echo "Core explicit now-playing client selector missing after patch." >&2; exit 1; }
  grep -q 'explicitlySelectedBundleID == nil || explicitlySelectedBundleID == bundleID' "$mrp_manager" || { echo "Core lifecycle-over-heuristic activation gate missing after patch." >&2; exit 1; }
  grep -q 'private func clearCurrentPlaybackSnapshot()' "$mrp_manager" || { echo "Core playback-session reset helper missing after patch." >&2; exit 1; }
  grep -q 'try merged.merge(serializedData: serialized, partial: true)' "$mrp_manager" || { echo "Core same-item partial metadata merge missing after patch." >&2; exit 1; }
  grep -q 'currentOwnerMatches(bundleID: bundleID, playerID: playerID)' "$mrp_manager" || { echo "Core player-scoped stale-update guard missing after patch." >&2; exit 1; }
  grep -q 'playbackQueueRequestGeneration' "$mrp_manager" || { echo "Core lifecycle queue-request generation guard missing after patch." >&2; exit 1; }

  # v1.1.4 keeps protocol pushes primary but verifies Now Playing while its UI
  # is visible. This request is metadata-only so a two-second foreground cadence
  # cannot turn into repeated artwork downloads.
  local now_playing_verification_patch="$ROOT_DIR/Patches/protocol-core-now-playing-verification.patch"
  if [[ ! -f "$now_playing_verification_patch" ]]; then
    echo "MRP Now Playing verification patch is missing; refusing to continue." >&2
    exit 1
  fi
  echo "Applying lightweight MRP Now Playing verification support..."
  if ! patch -d "$(dirname "$mrp_manager")" -p0 --forward --batch < "$now_playing_verification_patch"; then
    echo "Protocol core changed and the Now Playing verification patch no longer applies cleanly; refusing to guess." >&2
    exit 1
  fi
  grep -q 'public func verifyNowPlaying()' "$mrp_manager" || { echo "Core lightweight Now Playing verifier missing after patch." >&2; exit 1; }
  grep -q 'request.includeMetadata = true' "$mrp_manager" || { echo "Core metadata-only verifier does not request metadata." >&2; exit 1; }
  grep -q 'request.returnContentItemAssetsInUserCompletion = false' "$mrp_manager" || { echo "Core verifier still requests content-item assets." >&2; exit 1; }
  grep -q 'nowPlayingVerificationGeneration' "$mrp_manager" || { echo "Core verifier stale-response generation guard missing." >&2; exit 1; }

  # Native MRP skip-forward/backward is capability-driven and does not require
  # duration metadata merely to expose the ±10-second transport controls.
  local media_command="$(find "$CORE_DIR/Sources" -type f -path '*/Models/MediaCommand.swift' -print -quit)"
  if [[ -z "$media_command" || ! -f "$media_command" ]]; then
    echo "Core no longer contains MediaCommand.swift; refusing to guess." >&2
    exit 1
  fi
  grep -q 'case skipForward' "$media_command" || { echo "Core lacks skipForward media command." >&2; exit 1; }
  grep -q 'case skipBackward' "$media_command" || { echo "Core lacks skipBackward media command." >&2; exit 1; }
  grep -q 'public func sendSkip(_ command: MediaCommand, interval: Float = 15)' "$mrp_manager" || { echo "Core lacks interval skip sender." >&2; exit 1; }
  grep -q 'public var activeAppBundleID:' "$mrp_manager" || { echo "Core lacks active-app state." >&2; exit 1; }

  # v1.8+ uses the core's local Companion app-list/launch support. Guard the
  # protocol API explicitly so a future dependency change cannot silently remove
  # the Apps card transport contract.
  local apple_tv_manager="$(find "$CORE_DIR/Sources" -type f -path '*/Protocol/AppleTVManager.swift' -print -quit)"
  if [[ -z "$apple_tv_manager" || ! -f "$apple_tv_manager" ]]; then
    echo "Core no longer contains AppleTVManager.swift; refusing to guess." >&2
    exit 1
  fi

  # v1.9.14 completes the pinned core's existing Companion text-input support:
  # tvOS emits _tiStarted/_tiStopped events when an editable field gains/loses
  # focus, while the initial _tiStart response is required when we connect to
  # an already-focused field. Expose that protocol state through the core's
  # existing keyboardFocused property instead of inferring search UI locally.
  local keyboard_focus_patch="$ROOT_DIR/Patches/protocol-core-keyboard-focus.patch"
  if [[ ! -f "$keyboard_focus_patch" ]]; then
    echo "Companion keyboard-focus patch is missing; refusing to continue." >&2
    exit 1
  fi
  echo "Applying Companion keyboard-focus correction..."
  if ! patch -d "$(dirname "$apple_tv_manager")" -p0 --forward --batch < "$keyboard_focus_patch"; then
    echo "Protocol core changed and the keyboard-focus patch no longer applies cleanly; refusing to guess." >&2
    exit 1
  fi
  grep -q 'private func updateTextInputFocus(from content: OPACK.Value?)' "$apple_tv_manager" || { echo "Core keyboard-focus helper missing after patch." >&2; exit 1; }
  grep -q 'eventName == "_tiStarted" || eventName == "_tiStopped"' "$apple_tv_manager" || { echo "Core Companion keyboard event handling missing after patch." >&2; exit 1; }
  grep -Fq 'self?.updateTextInputFocus(from: response["_c"])' "$apple_tv_manager" || { echo "Core initial keyboard-focus snapshot missing after patch." >&2; exit 1; }
  grep -q 'self?.sentText = result.currentText' "$apple_tv_manager" || { echo "Core text-session state synchronization missing after patch." >&2; exit 1; }

  grep -q 'public var installedApps:' "$apple_tv_manager" || { echo "Core lacks installedApps support." >&2; exit 1; }
  grep -q 'public func fetchApps()' "$apple_tv_manager" || { echo "Core lacks fetchApps support." >&2; exit 1; }
  grep -q 'public func launchApp(bundleID: String)' "$apple_tv_manager" || { echo "Core lacks launchApp support." >&2; exit 1; }
  grep -q 'public func touchBegan(referenceSize: CGSize)' "$apple_tv_manager" || { echo "Core lacks real-time touch begin support." >&2; exit 1; }
  grep -q 'public func touchMoved(translation: CGPoint)' "$apple_tv_manager" || { echo "Core lacks real-time touch move support." >&2; exit 1; }
  grep -q 'public func touchEnded(translation: CGPoint, velocity: CGPoint)' "$apple_tv_manager" || { echo "Core lacks real-time touch end/inertia support." >&2; exit 1; }

  # v1.9.14 build hygiene: Patch tools can leave .orig backup files in unusual failure/offset cases. SwiftPM treats those files as unhandled source-tree
  # contents and emits a warning. Reject real patch failures, then remove benign
  # backup artifacts before SwiftPM ever inspects the vendored package.
  if find "$CORE_DIR" -type f -name '*.rej' -print -quit | grep -q .; then
    echo "Patch reject artifact remains in vendored protocol core; refusing to continue." >&2
    find "$CORE_DIR" -type f -name '*.rej' -print >&2
    exit 1
  fi
  find "$CORE_DIR" -type f -name '*.orig' -delete
  if find "$CORE_DIR" -type f -name '*.orig' -print -quit | grep -q .; then
    echo "Could not remove patch backup artifacts from vendored protocol core." >&2
    exit 1
  fi
}


fetch_external_dependencies() {
  prepare_vendor_sources
  swift package resolve
}

build_release_app() {
  swift build -c release
  local bin_dir
  bin_dir="$(swift build -c release --show-bin-path)"
  local executable="$bin_dir/remotely"

  if [[ ! -x "$executable" ]]; then
    echo "Build completed but executable was not found at: $executable" >&2
    return 1
  fi

  rm -rf "$ROOT_DIR/dist"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$executable" "$APP/Contents/MacOS/remotely"
  cp "$ROOT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
}

find_signing_identity_hash() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -v name="$SIGNING_IDENTITY_NAME" '$0 ~ ("\"" name "\"") { print $2; exit }'
}

sign_application() {
  local signing_identity_hash
  signing_identity_hash="$(find_signing_identity_hash)"
  if [[ -z "$signing_identity_hash" ]]; then
    echo "Stable signing identity not found: $SIGNING_IDENTITY_NAME"
    echo "Provisioning the local signing identity..."
    if ! REMOTELY_SIGNING_IDENTITY="$SIGNING_IDENTITY_NAME" "$SCRIPT_DIR/setup_signing.sh"; then
      echo "Automatic signing setup failed; no ad-hoc signature was created." >&2
      return 1
    fi

    signing_identity_hash="$(find_signing_identity_hash)"
    if [[ -z "$signing_identity_hash" ]]; then
      echo "Signing setup completed without producing a usable identity: $SIGNING_IDENTITY_NAME" >&2
      return 1
    fi
  fi

  echo "Signing identity: $SIGNING_IDENTITY_NAME ($signing_identity_hash)"
  codesign --force --deep --sign "$signing_identity_hash" "$APP"
  codesign --verify --strict --deep --verbose=2 "$APP"

  local designated_requirement
  designated_requirement="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
  if [[ -z "$designated_requirement" ]]; then
    echo "Could not read remotely's designated requirement after signing." >&2
    return 1
  fi
  if [[ "$designated_requirement" == *cdhash* ]]; then
    echo "remotely was signed with a build-specific cdhash requirement; refusing to continue." >&2
    echo "Designated requirement: $designated_requirement" >&2
    return 1
  fi
  if [[ "$designated_requirement" != *'identifier "com.local.remotely"'* ]]; then
    echo "remotely's designated requirement does not contain the expected bundle identifier." >&2
    echo "Designated requirement: $designated_requirement" >&2
    return 1
  fi
  echo "Stable designated requirement: $designated_requirement"
}

prepare_install_authorization() {
  local destination_dir="/Applications"
  local destination_app="$destination_dir/remotely.app"

  if [[ ! -w "$destination_dir" ]] || { [[ -e "$destination_app" ]] && [[ ! -w "$destination_app" ]]; }; then
    echo "Administrator permission is required to update $destination_app."
    sudo -v
  fi
}

install_and_launch() {
  REMOTELY_BUILD_PIPELINE=1 "$SCRIPT_DIR/install.sh"
}

print_summary() {
  echo
  echo "remotely v1.1.4 built, signed, installed, and launched successfully."
  echo "Installed app: /Applications/remotely.app"
  echo "Build log:     $LOG_FILE"
}

if [[ "$SELF_TEST_PROGRESS" == true ]]; then
  # Exercise the same fixed multi-stage dashboard used by real builds. This
  # catches shell/runtime and cursor-redraw failures before packaging.
  USE_PROGRESS_UI=true
  STAGE_LABELS=("Self-test one" "Self-test two" "Self-test three" "Self-test four" "Self-test five" "Self-test six")
  STAGE_STATES=("pending" "pending" "pending" "pending" "pending" "pending")
  STAGE_PROGRESS=(0 0 0 0 0 0)
  STAGE_TICK_DIVISORS=(1 1 1 1 1 1)
  DASHBOARD_LINES=${#STAGE_LABELS[@]}
  DASHBOARD_RENDERED=false
  CURSOR_HIDDEN=false
  show_initial_dashboard
  run_step 0 sleep 0.55
  run_step 1 sleep 0.55
  run_step 2 sleep 0.55
  run_step 3 sleep 0.55
  run_step 4 sleep 0.55
  run_step 5 sleep 0.55
  show_cursor
  rm -f "$LOG_FILE"
  exit 0
fi

show_initial_dashboard
run_step 0 preflight_environment
run_step 1 validate_sources
run_step 2 fetch_external_dependencies
run_step 3 build_release_app
run_step 4 sign_application

# Authenticate before the final progress step if /Applications requires admin
# rights. Restore the cursor first so any password prompt remains normal and
# visible, then the final progress stage hides it again while redrawing.
show_cursor
prepare_install_authorization
run_step 5 install_and_launch
show_cursor
print_summary
