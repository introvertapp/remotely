#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "$1: PASS"; }

for script in build.sh clean.sh install.sh setup_signing.sh validate_source.sh; do
  [[ -x "$SCRIPT_DIR/$script" ]] || fail "scripts/$script missing or not executable"
done
if find "$ROOT_DIR" -maxdepth 1 -type f -name '*.sh' -print -quit | grep -q .; then
  fail "shell scripts must live under scripts/"
fi
pass "script layout"

[[ -f Package.swift ]] || fail "Package.swift missing"
[[ -f Resources/Info.plist ]] || fail "Info.plist missing"
[[ -f Resources/AppIcon.icns ]] || fail "AppIcon.icns missing"
[[ -d Sources/remotely ]] || fail "Sources/remotely missing"
[[ "$(find Sources -mindepth 1 -maxdepth 1 -type d -print)" == "Sources/remotely" ]] || fail "first-party source directory must be Sources/remotely only"
grep -q 'name: "remotely"' Package.swift || fail "Swift package name is not remotely"
grep -q 'path: "Sources/remotely"' Package.swift || fail "Swift target source path is not remotely-owned"
grep -q '<string>com.local.remotely</string>' Resources/Info.plist || fail "remotely bundle identifier missing"
grep -q '<string>1.2.10</string>' Resources/Info.plist || fail "v1.2.10 bundle version missing"
awk '/<key>CFBundleVersion<\/key>/{getline; if ($0 ~ /<string>17<\/string>/) found=1} END{exit found ? 0 : 1}' Resources/Info.plist || fail "v1.2.10 build number 17 missing"
grep -q 'PROTOCOL_CORE_REF="052d9a9a0416d577119316ea813aa3b822b408e5"' "$SCRIPT_DIR/build.sh" || fail "pinned protocol-core revision missing"
grep -Fq 'echo "remotely v1.2.10 built, signed, installed, and launched successfully."' "$SCRIPT_DIR/build.sh" || fail "build summary version is not v1.2.10"
pass "package / version"

# Everything outside this maintenance fix is pinned byte-for-byte to current
# main (fc573fe5985db38312002182a2bf66066f4c87a1). This is stricter than a
# collection of presence greps: any accidental edit to existing first-party
# Swift behavior or unchanged protocol patches fails validation immediately.
check_blob() {
  local expected="$1"
  local file_path="$2"
  [[ -f "$file_path" ]] || fail "$file_path missing"
  local actual
  actual="$(git hash-object "$file_path")"
  [[ "$actual" == "$expected" ]] || fail "$file_path differs from the v1.2.9/current-main baseline"
}

check_blob 0322dc5e0ca4aee746fdb9d2c4a76d5481fb327c Package.swift
check_blob 36d7206c260bb2eec17862b81625035449aa3e5e Sources/remotely/AppArtworkLoader.swift
check_blob 4b3d699f749b773f721c80a1fcaedbb7693f7c9c Sources/remotely/AppConstants.swift
check_blob 079253e4ef0e6a8b47a7e9967e1a383b17a24101 Sources/remotely/AppController.swift
check_blob 0858dd59b31d30cb13edd8d6bfdbf19eac929e17 Sources/remotely/AppModel.swift
check_blob 2c3101a3aa1c8a7b886dabda5724500da52e3f07 Sources/remotely/AppleTVLogoView.swift
check_blob b56a597a6ca604a9a20a1b186c67a107cbcc3580 Sources/remotely/AppleTVService.swift
check_blob d4f6f21b5a78a6c22b2001ead59151a42dd76be6 Sources/remotely/AppsView.swift
check_blob 7a4c2afee02660eebe36f104e5bb7ffb33cf8390 Sources/remotely/ClickpadSwipeCapture.swift
check_blob cab041623209bcae20ce17e148a5147405be28a5 Sources/remotely/MiniRemoteView.swift
check_blob 2ad1642eb8a362044c8107833d144d68d10576db Sources/remotely/NowPlayingShared.swift
check_blob def3960ed64e4022ba78417075b97bd76d709be6 Sources/remotely/OverflowMarqueeText.swift
check_blob be4a946565b1aece213b833f66cc949a35f6ed30 Sources/remotely/PanelRootView.swift
check_blob 223c49ffe1989abe77fd14b40c60adf73dca34f2 Sources/remotely/PreferencesView.swift
check_blob bde85b6d83a45aed64d4f43ff6b7dfce542dcc41 Sources/remotely/RemoteControls.swift
check_blob ec948bd99fb9d1654e4e0a1d0a4e7ec7c1099283 Sources/remotely/RemoteView.swift
check_blob ee4669d87bfe96c135fda28c82724290a6ea2e22 Sources/remotely/RemotelyMain.swift
check_blob d93f38e70b9a16ab9b3bff2cca2d8a935479e8ce Sources/remotely/WindowDragHandle.swift
check_blob e7864e47764bb0ce1dbfcb356b828dd50af963ef scripts/clean.sh
check_blob 319605928120138692a8d89bddad2d1897e27fde scripts/install.sh
check_blob e9d8ab552797d936534817ee714e79fe9bda78f2 scripts/setup_signing.sh
check_blob 2eae4e438139ad4036726499110b4330c34dd518 Patches/protocol-core-main-content-start.patch
check_blob 1c59d38add16442801622dc8065e24608ddec754 Patches/protocol-core-media-metadata.patch
check_blob 7878503656f60435dc05f062cc7ee2472a529c1f Patches/protocol-core-now-playing-content.patch
check_blob 0e1b6e9863454765854d5e6e51c06477c215ac6a Patches/protocol-core-player-isolation.patch
check_blob 0dd442a39f40caa79f66c79b13f12f154325744e Patches/protocol-core-session-lifecycle.patch
check_blob 7c52d57292c26d6c29d6362ea6d74071f66e3c07 Patches/protocol-core-keyboard-focus.patch
pass "unchanged current-main baseline"

# v1.2.10: verifier responses are allowed to clear Now Playing only if the
# exact playback snapshot/revision that issued the request is still current.
VERIFY_PATCH=Patches/protocol-core-now-playing-verification.patch
[[ -f "$VERIFY_PATCH" ]] || fail "teardown verifier patch missing"
grep -q 'private struct NowPlayingVerificationSnapshot: Equatable' "$VERIFY_PATCH" || fail "verifier snapshot identity missing"
grep -q 'sessionGeneration: playbackQueueRequestGeneration' "$VERIFY_PATCH" || fail "verifier session-generation capture missing"
grep -q 'stateRevision: nowPlayingVerificationRevision' "$VERIFY_PATCH" || fail "verifier state-revision capture missing"
grep -q 'guard self.currentNowPlayingVerificationSnapshot() == snapshot else' "$VERIFY_PATCH" || fail "stale verifier response rejection missing"
grep -q 'state.playbackState != .stopped' "$VERIFY_PATCH" || fail "paused/non-stopped playback protection missing"
grep -q 'guard reportsStopped || reportsEmptyQueue else {' "$VERIFY_PATCH" || fail "verifier teardown evidence gate missing"
grep -q 'nowPlayingTeardownCandidate == snapshot' "$VERIFY_PATCH" || fail "identity-poor teardown confirmation missing"
[[ "$(grep -c 'noteNowPlayingStateAdvanced()' "$VERIFY_PATCH")" -ge 5 ]] || fail "authoritative-state invalidation hooks missing"
grep -q 'request.returnContentItemAssetsInUserCompletion = false' "$VERIFY_PATCH" || fail "verifier must not request content assets"
! sed -n '/public func verifyNowPlayingTeardown()/,/public func seekToPosition/p' "$VERIFY_PATCH" | grep -q 'handleSetState(response)' || fail "teardown verifier still processes healthy SetState replies"
grep -A28 'private func clearVerifiedInactivePlayback()' "$VERIFY_PATCH" | grep -q 'commandsByBundleID.removeValue' || fail "verified teardown does not retire command cache"
grep -A28 'private func clearVerifiedInactivePlayback()' "$VERIFY_PATCH" | grep -q 'skipIntervalsByBundleID.removeValue' || fail "verified teardown does not retire skip cache"
pass "v1.2.10 session-safe teardown verifier"

# The app-close fallback itself is deliberately retained. The current visible
# Now Playing surface performs one lightweight verifier pass every two seconds.
grep -q 'private var nowPlayingVerificationTimer: Timer?' Sources/remotely/AppleTVService.swift || fail "Now Playing verification timer missing"
grep -Fq 'let shouldRun = (remotePresented || miniRemotePresented) && isConnected' Sources/remotely/AppleTVService.swift || fail "verifier visibility/connection gate changed"
grep -q 'withTimeInterval: 2.0, repeats: true' Sources/remotely/AppleTVService.swift || fail "two-second app-close verification cadence missing"
grep -q 'manager.mrpManager.verifyNowPlayingTeardown()' Sources/remotely/AppleTVService.swift || fail "service no longer invokes teardown verifier"
grep -q 'stopNowPlayingVerificationTimer()' Sources/remotely/AppleTVService.swift || fail "verifier timer shutdown path missing"
pass "app-close Now Playing cleanup"

# Fix #2 is intentionally NOT part of v1.2.10. Keep its explicit queue reply
# behavior at the current-main baseline so this release remains one isolated fix.
grep -Fq 'if self.playbackQueueRequestGeneration == generation {' Patches/protocol-core-session-lifecycle.patch || fail "existing queue generation bookkeeping missing"
if grep -A14 'let generation = playbackQueueRequestGeneration' Patches/protocol-core-session-lifecycle.patch | grep -Fq 'guard self.playbackQueueRequestGeneration == generation else { return }'; then
  fail "v1.2.10 accidentally includes the separate stale queue-reply fix"
fi
pass "fix isolation"

# Existing build/runtime contracts relied on by the current application.
grep -q 'protocol-core-now-playing-verification.patch' "$SCRIPT_DIR/build.sh" || fail "verifier patch build integration missing"
grep -q 'private struct NowPlayingVerificationSnapshot: Equatable' "$SCRIPT_DIR/build.sh" || fail "build does not verify v1.2.10 verifier identity"
grep -q 'guard self.currentNowPlayingVerificationSnapshot() == snapshot else' "$SCRIPT_DIR/build.sh" || fail "build does not verify stale verifier rejection"
grep -q 'nowPlayingTeardownCandidate == snapshot' "$SCRIPT_DIR/build.sh" || fail "build does not verify teardown confirmation"
grep -q 'protocol-core-keyboard-focus.patch' "$SCRIPT_DIR/build.sh" || fail "keyboard-focus patch integration missing"
grep -q 'protocol-core-session-lifecycle.patch' "$SCRIPT_DIR/build.sh" || fail "session-lifecycle patch integration missing"
grep -q 'protocol-core-main-content-start.patch' "$SCRIPT_DIR/build.sh" || fail "main-content patch integration missing"
grep -q 'protocol-core-media-metadata.patch' "$SCRIPT_DIR/build.sh" || fail "media-metadata patch integration missing"
grep -q 'deviceInfo.name = "remotely"' "$SCRIPT_DIR/build.sh" || fail "remotely MRP client identity patch missing"
grep -q 'com.local.remotely.credentials' "$SCRIPT_DIR/build.sh" || fail "remotely Keychain namespace patch missing"
grep -Fq 'run_step 1 validate_sources' "$SCRIPT_DIR/build.sh" || fail "build no longer validates source"
grep -Fq 'run_step 2 fetch_external_dependencies' "$SCRIPT_DIR/build.sh" || fail "build dependency stage missing"
grep -Fq 'run_step 3 build_release_app' "$SCRIPT_DIR/build.sh" || fail "release build stage missing"
grep -Fq 'run_step 4 sign_application' "$SCRIPT_DIR/build.sh" || fail "signing stage missing"
grep -Fq 'run_step 5 install_and_launch' "$SCRIPT_DIR/build.sh" || fail "install/launch stage missing"
pass "build integration"

# High-value UI behavior remains pinned by the byte baseline above; these names
# make failures easier to diagnose if that baseline is deliberately moved later.
grep -q 'manager.mrpManager.refreshNowPlaying()' Sources/remotely/AppleTVService.swift || fail "one-shot Now Playing refresh path missing"
grep -q 'scheduleNowPlayingRefresh(after:' Sources/remotely/AppleTVService.swift || fail "post-command Now Playing refresh path missing"
grep -q 'manager.mrpManager.sendSkip(.skipBackward, interval: 10)' Sources/remotely/AppleTVService.swift || fail "native rewind sender missing"
grep -q 'manager.mrpManager.sendSkip(.skipForward, interval: 10)' Sources/remotely/AppleTVService.swift || fail "native forward sender missing"
grep -q 'NowPlayingMetadata(state: state)' Sources/remotely/RemoteView.swift || fail "full Remote metadata view missing"
grep -q 'NowPlayingMetadata(state: state)' Sources/remotely/MiniRemoteView.swift || fail "MiniRemote metadata view missing"
grep -q 'manager.keyboardFocused' Sources/remotely/AppleTVService.swift || fail "protocol-driven keyboard focus bridge missing"
grep -q 'manager.fetchApps()' Sources/remotely/AppleTVService.swift || fail "Apps fetch bridge missing"
pass "runtime behavior contracts"

if find . -path './Vendor' -prune -o -type f \( -name '*.orig' -o -name '*.rej' \) -print | grep -q .; then
  fail "source archive contains patch backup/reject artifacts"
fi
pass "source hygiene"

echo "Source validation complete: PASS"
