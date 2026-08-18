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
BAR_WIDTH=24
LABEL_WIDTH=22
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

# Preserve the Terminal.app output descriptor before stage commands are routed
# to the build log. Progress updates always write to this descriptor directly.
exec 3>&1

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

STAGE_LABELS=(
  "Checking environment"
  "Validating source"
  "Fetching dependencies"
  "Building release"
  "Signing application"
  "Installing & launching"
)

CURRENT_STAGE_INDEX=-1
CURRENT_PROGRESS_FILE=""
DASHBOARD_LINES=${#STAGE_LABELS[@]}
CURSOR_HIDDEN=false

hide_cursor() {
  if [[ "$CURSOR_HIDDEN" == false ]]; then
    printf '\033[?25l' >&3
    CURSOR_HIDDEN=true
  fi
}

show_cursor() {
  if [[ "$CURSOR_HIDDEN" == true ]]; then
    printf '\033[?25h' >&3
    CURSOR_HIDDEN=false
  fi
}

cleanup_terminal() {
  show_cursor
}
trap cleanup_terminal EXIT INT TERM

progress_line() {
  local stage_index="$1"
  local percent="$2"
  local state="${3:-running}"
  local marker=' '
  local filled empty

  if (( percent < 0 )); then percent=0; fi
  if (( percent > 100 )); then percent=100; fi
  filled=$(( percent * BAR_WIDTH / 100 ))
  empty=$(( BAR_WIDTH - filled ))

  case "$state" in
    done) marker='✓' ;;
    failed) marker='x' ;;
  esac

  # Fixed at 53 display columns. Every dashboard row therefore remains one
  # physical Terminal.app line in the project's ~60-column build window.
  printf '[%s] %-*s [%s%s]' \
    "$marker" "$LABEL_WIDTH" "${STAGE_LABELS[$stage_index]}" \
    "$(repeat_char "$filled" '#')" "$(repeat_char "$empty" '-')"
}

show_initial_dashboard() {
  local i
  hide_cursor
  for (( i = 0; i < DASHBOARD_LINES; i++ )); do
    progress_line "$i" 0 pending >&3
    printf '\n' >&3
  done
}

render_progress() {
  local stage_index="$1"
  local percent="$2"
  local state="${3:-running}"
  local rows_up=$(( DASHBOARD_LINES - stage_index ))

  # The cursor normally rests on the blank row immediately below the fixed
  # six-line dashboard. Move to exactly one task row, rewrite that 53-column
  # row, then return to the anchor row. No task line is ever reprinted.
  printf '\033[%dA\r%s\033[%dB\r' \
    "$rows_up" "$(progress_line "$stage_index" "$percent" "$state")" "$rows_up" >&3
}

report_progress() {
  local percent="$1"
  local previous=0

  [[ -n "$CURRENT_PROGRESS_FILE" ]] || return 0
  if [[ -f "$CURRENT_PROGRESS_FILE" ]]; then
    previous="$(cat "$CURRENT_PROGRESS_FILE" 2>/dev/null || printf '0')"
  fi
  [[ "$previous" =~ ^[0-9]+$ ]] || previous=0
  if (( percent <= previous )); then
    return 0
  fi
  if (( percent > 99 )); then percent=99; fi
  printf '%s\n' "$percent" > "$CURRENT_PROGRESS_FILE"
  render_progress "$CURRENT_STAGE_INDEX" "$percent" running
}

show_failure_details() {
  local label="$1"
  echo >&2
  echo "Build failed during: $label" >&2
  echo "Build details (last 35 lines):" >&2
  tail -n 35 "$LOG_FILE" >&2 || true
  echo >&2
  echo "Full log: $LOG_FILE" >&2
}

run_step() {
  local stage_index="$1"
  shift
  local label="${STAGE_LABELS[$stage_index]}"
  local progress_file="${TMPDIR:-/tmp}/remotely-build-stage-$$-$stage_index.progress"
  local step_exit_code=0
  local last_progress=0

  CURRENT_STAGE_INDEX="$stage_index"
  CURRENT_PROGRESS_FILE="$progress_file"
  printf '0\n' > "$progress_file"
  render_progress "$stage_index" 0 running

  {
    echo
    echo "===== $label ====="
    echo "Started: $(date)"
  } >> "$LOG_FILE"

  # Keep command output in the detailed log. The function runs in a subshell so
  # existing defensive `exit 1` paths cannot terminate build.sh before this
  # wrapper can finish the status row and show diagnostics.
  if ( "$@" ) >> "$LOG_FILE" 2>&1; then
    step_exit_code=0
  else
    step_exit_code=$?
  fi

  if [[ -f "$progress_file" ]]; then
    last_progress="$(cat "$progress_file" 2>/dev/null || printf '0')"
  fi
  [[ "$last_progress" =~ ^[0-9]+$ ]] || last_progress=0
  rm -f "$progress_file"

  if (( step_exit_code != 0 )); then
    render_progress "$stage_index" "$last_progress" failed
    show_cursor
    show_failure_details "$label"
    exit "$step_exit_code"
  fi

  echo "Completed: $(date)" >> "$LOG_FILE"
  render_progress "$stage_index" 100 done
}

git_progress_filter() {
  local range_start="$1"
  local range_span="$2"
  local line raw_percent mapped receiving_span resolving_start resolving_span

  receiving_span=$(( range_span * 9 / 10 ))
  resolving_start=$(( range_start + receiving_span ))
  resolving_span=$(( range_span - receiving_span ))

  while IFS= read -r line; do
    printf '%s\n' "$line"
    if [[ "$line" == *"Receiving objects:"* && "$line" =~ ([0-9]{1,3})% ]]; then
      raw_percent="${BASH_REMATCH[1]}"
      if (( raw_percent > 100 )); then raw_percent=100; fi
      mapped=$(( range_start + raw_percent * receiving_span / 100 ))
      report_progress "$mapped"
    elif [[ "$line" == *"Resolving deltas:"* && "$line" =~ ([0-9]{1,3})% ]]; then
      raw_percent="${BASH_REMATCH[1]}"
      if (( raw_percent > 100 )); then raw_percent=100; fi
      mapped=$(( resolving_start + raw_percent * resolving_span / 100 ))
      report_progress "$mapped"
    fi
  done
}

swift_build_progress_filter() {
  local line current total mapped

  while IFS= read -r line; do
    printf '%s\n' "$line"
    if [[ "$line" =~ \[([0-9]+)/([0-9]+)\] ]]; then
      current="${BASH_REMATCH[1]}"
      total="${BASH_REMATCH[2]}"
      if (( total > 0 )); then
        mapped=$(( 5 + current * 80 / total ))
        report_progress "$mapped"
      fi
    fi
  done
}

preflight_environment() {
  local tool
  local checked=0
  local total=10

  for tool in swift git codesign security patch ditto open; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "$tool is not available. Install Xcode or the Xcode Command Line Tools first." >&2
      return 1
    fi
    checked=$(( checked + 1 ))
    report_progress $(( checked * 90 / total ))
  done

  if [[ ! -x "$SCRIPT_DIR/validate_source.sh" ]]; then
    echo "validate_source.sh is missing or not executable." >&2
    return 1
  fi
  checked=$(( checked + 1 ))
  report_progress $(( checked * 90 / total ))

  if [[ ! -x "$SCRIPT_DIR/install.sh" ]]; then
    echo "install.sh is missing or not executable." >&2
    return 1
  fi
  checked=$(( checked + 1 ))
  report_progress $(( checked * 90 / total ))

  if [[ ! -x "$SCRIPT_DIR/setup_signing.sh" ]]; then
    echo "setup_signing.sh is missing or not executable." >&2
    return 1
  fi
  checked=$(( checked + 1 ))
  report_progress 95

  swift --version
  report_progress 99
}

validate_sources() {
  local total_sections
  total_sections="$(grep -c 'echo ".*: PASS"' "$SCRIPT_DIR/validate_source.sh" || true)"
  [[ "$total_sections" =~ ^[0-9]+$ ]] || total_sections=0
  if (( total_sections < 1 )); then total_sections=1; fi

  "$SCRIPT_DIR/validate_source.sh" 2>&1 | while IFS= read -r line; do
    local seen_file="${CURRENT_PROGRESS_FILE}.validation-count"
    local seen=0
    printf '%s\n' "$line"
    if [[ "$line" == *": PASS" ]]; then
      if [[ -f "$seen_file" ]]; then
        seen="$(cat "$seen_file" 2>/dev/null || printf '0')"
      fi
      [[ "$seen" =~ ^[0-9]+$ ]] || seen=0
      seen=$(( seen + 1 ))
      printf '%s\n' "$seen" > "$seen_file"
      report_progress $(( 5 + seen * 90 / total_sections ))
    fi
  done
  local validation_exit_code=$?
  rm -f "${CURRENT_PROGRESS_FILE}.validation-count"
  return "$validation_exit_code"
}

clone_exact_revision() {
  local url="$1"
  local revision="$2"
  local destination="$3"

  rm -rf "$destination"
  mkdir -p "$destination"
  git -C "$destination" init -q
  git -C "$destination" remote add origin "$url"
  report_progress 3

  # Git's own transfer percentages drive this portion of the bar. Convert its
  # carriage-return progress records to lines only inside the build log parser;
  # Terminal.app still receives just our one fixed-width stage row.
  GIT_TERMINAL_PROMPT=0 git -c credential.helper= -C "$destination"     fetch --progress --depth 1 origin "$revision" 2>&1     | tr '\r' '\n'     | git_progress_filter 3 27

  git -c advice.detachedHead=false -C "$destination" checkout -q --detach FETCH_HEAD
  report_progress 30
}

clone_exact_tag() {
  local url="$1"
  local tag="$2"
  local destination="$3"

  rm -rf "$destination"
  GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c advice.detachedHead=false     clone --progress --depth 1 --branch "$tag" "$url" "$destination" 2>&1     | tr '\r' '\n'     | git_progress_filter 30 20
  report_progress 50
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
  report_progress 50

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
  report_progress 55

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
  report_progress 60

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
  report_progress 65

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
  report_progress 70

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
  grep -q 'explicitlySelectedBundleID == bundleID || currentPlayerBundleID == bundleID' "$mrp_manager" || { echo "Core SetNowPlayingPlayer still activates an unrelated client." >&2; exit 1; }
  grep -q 'if !removeClient, let playerID' "$mrp_manager" || { echo "Core RemovePlayer active-player identity guard missing." >&2; exit 1; }
  grep -q 'Some third-party players use Stopped as a' "$mrp_manager" || { echo "Core transient-stopped queue retention missing." >&2; exit 1; }
  grep -q 'if pbState == .playing, nowPlaying == nil, !contentItems.isEmpty' "$mrp_manager" || { echo "Core retained-queue resume path missing." >&2; exit 1; }
  report_progress 76

  # v1.2.5 retains the two-second visible-UI stale-session check as teardown-only.
  # Healthy/partial responses must never flow through normal SetState processing,
  # and only one verifier request may be outstanding. Basic transport UI does not
  # depend on per-client SupportedCommands advertising.
  local now_playing_verification_patch="$ROOT_DIR/Patches/protocol-core-now-playing-verification.patch"
  if [[ ! -f "$now_playing_verification_patch" ]]; then
    echo "MRP teardown-only Now Playing verification patch is missing; refusing to continue." >&2
    exit 1
  fi
  echo "Applying teardown-only MRP Now Playing verification support..."
  if ! patch -d "$(dirname "$mrp_manager")" -p0 --forward --batch < "$now_playing_verification_patch"; then
    echo "Protocol core changed and the teardown-only Now Playing verification patch no longer applies cleanly; refusing to guess." >&2
    exit 1
  fi
  grep -q 'public func verifyNowPlayingTeardown()' "$mrp_manager" || { echo "Core teardown-only Now Playing verifier missing after patch." >&2; exit 1; }
  grep -q 'private var nowPlayingVerificationPending = false' "$mrp_manager" || { echo "Core verifier single-flight guard missing after patch." >&2; exit 1; }
  grep -q 'private var nowPlayingVerificationGeneration: UInt64 = 0' "$mrp_manager" || { echo "Core verifier request-generation guard missing after patch." >&2; exit 1; }
  grep -q 'let sessionGeneration = playbackQueueRequestGeneration' "$mrp_manager" || { echo "Core verifier playback-session generation capture missing after patch." >&2; exit 1; }
  grep -q 'self.playbackQueueRequestGeneration == sessionGeneration' "$mrp_manager" || { echo "Core verifier stale-session response rejection missing after patch." >&2; exit 1; }
  grep -q 'self.currentPlayerBundleID == sessionBundleID' "$mrp_manager" || { echo "Core verifier bundle ownership guard missing after patch." >&2; exit 1; }
  grep -q 'self.currentPlayerIdentifier == sessionPlayerID' "$mrp_manager" || { echo "Core verifier player ownership guard missing after patch." >&2; exit 1; }
  grep -q 'self.handleNowPlayingTeardownVerification(' "$mrp_manager" || { echo "Core verifier response gate missing after patch." >&2; exit 1; }
  grep -q 'guard reportsStopped || reportsEmptyQueue else { return }' "$mrp_manager" || { echo "Core verifier is not restricted to conclusive teardown state." >&2; exit 1; }
  grep -q 'if state.hasPlaybackState && state.playbackState == .playing { return }' "$mrp_manager" || { echo "Core verifier lacks playing-state protection." >&2; exit 1; }
  grep -q 'request.returnContentItemAssetsInUserCompletion = false' "$mrp_manager" || { echo "Core verifier still requests content-item assets." >&2; exit 1; }
  ! grep -A35 'public func verifyNowPlayingTeardown()' "$mrp_manager" | grep -q 'handleSetState(response)' || { echo "Core teardown verifier still mutates healthy SetState/queue state." >&2; exit 1; }
  report_progress 82

  # Native MRP exposes standard transport senders directly. remotely intentionally
  # does not gate basic playback UI on optional per-client SupportedCommands
  # advertising, which some otherwise-compatible tvOS apps omit on resume.
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
  report_progress 88

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
  report_progress 90
}


fetch_external_dependencies() {
  prepare_vendor_sources
  report_progress 92
  swift package resolve
  report_progress 99
}

build_release_app() {
  report_progress 2
  swift build -c release 2>&1 | swift_build_progress_filter
  report_progress 87

  local bin_dir
  bin_dir="$(swift build -c release --show-bin-path)"
  local executable="$bin_dir/remotely"
  report_progress 90

  if [[ ! -x "$executable" ]]; then
    echo "Build completed but executable was not found at: $executable" >&2
    return 1
  fi

  rm -rf "$ROOT_DIR/dist"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  report_progress 93
  cp "$executable" "$APP/Contents/MacOS/remotely"
  report_progress 96
  cp "$ROOT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  report_progress 99
}

find_signing_identity_hash() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -v name="$SIGNING_IDENTITY_NAME" '$0 ~ ("\"" name "\"") { print $2; exit }'
}

sign_application() {
  local signing_identity_hash
  report_progress 10
  signing_identity_hash="$(find_signing_identity_hash)"
  if [[ -z "$signing_identity_hash" ]]; then
    echo "Stable signing identity not found: $SIGNING_IDENTITY_NAME"
    echo "Provisioning the local signing identity..."
    report_progress 20
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
  report_progress 45

  echo "Signing identity: $SIGNING_IDENTITY_NAME ($signing_identity_hash)"
  codesign --force --deep --sign "$signing_identity_hash" "$APP"
  report_progress 70
  codesign --verify --strict --deep --verbose=2 "$APP"
  report_progress 85

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
  report_progress 99
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
  REMOTELY_BUILD_PIPELINE=1 "$SCRIPT_DIR/install.sh" 2>&1 | while IFS= read -r line; do
    if [[ "$line" =~ ^__REMOTELY_PROGRESS__:([0-9]+)$ ]]; then
      report_progress "${BASH_REMATCH[1]}"
    else
      printf '%s\n' "$line"
    fi
  done
}

print_summary() {
  echo
  echo "remotely v1.2.10 built, signed, installed, and launched successfully."
  echo "Installed app: /Applications/remotely.app"
  echo "Build log:     $LOG_FILE"
}

self_test_progress_step() {
  # Real builds never use timed/fabricated movement. The self-test emits a few
  # deterministic checkpoints only to exercise the same fixed-width repaint
  # path and verify that intermediate states overwrite one physical row.
  report_progress 20
  report_progress 45
  report_progress 70
  report_progress 99
}

if [[ "$SELF_TEST_PROGRESS" == true ]]; then
  STAGE_LABELS=("Self-test one" "Self-test two" "Self-test three" "Self-test four" "Self-test five" "Self-test six")
  DASHBOARD_LINES=${#STAGE_LABELS[@]}
  show_initial_dashboard
  run_step 0 self_test_progress_step
  run_step 1 self_test_progress_step
  run_step 2 self_test_progress_step
  run_step 3 self_test_progress_step
  run_step 4 self_test_progress_step
  run_step 5 self_test_progress_step
  show_cursor
  rm -f "$LOG_FILE"
  exit 0
fi

# Any installation authorization prompt must happen before the fixed dashboard
# is drawn so it cannot shift the dashboard's cursor anchor. Cursor hiding starts
# first and remains active through the entire visible build.
hide_cursor
prepare_install_authorization
show_initial_dashboard

run_step 0 preflight_environment
run_step 1 validate_sources
run_step 2 fetch_external_dependencies
run_step 3 build_release_app
run_step 4 sign_application
run_step 5 install_and_launch
show_cursor
print_summary
