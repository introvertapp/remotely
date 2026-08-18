#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

fail() { echo "FAIL: $1" >&2; exit 1; }

for script in build.sh clean.sh install.sh setup_signing.sh validate_source.sh; do
  [[ -x "$SCRIPT_DIR/$script" ]] || fail "scripts/$script missing or not executable"
done
if find "$ROOT_DIR" -maxdepth 1 -type f -name '*.sh' -print -quit | grep -q .; then
  fail "shell scripts must live under scripts/"
fi

[[ -f Package.swift ]] || fail "Package.swift missing"
[[ -f Resources/Info.plist ]] || fail "Info.plist missing"
[[ -f Resources/AppIcon.icns ]] || fail "AppIcon.icns missing"
[[ -f Sources/remotely/AppleTVService.swift ]] || fail "AppleTVService missing"
[[ -f Sources/remotely/PreferencesView.swift ]] || fail "PreferencesView missing"

[[ -f Sources/remotely/RemotelyMain.swift ]] || fail "RemotelyMain missing"
[[ "$(find Sources -mindepth 1 -maxdepth 1 -type d -print)" == "Sources/remotely" ]] || fail "first-party source directory must be Sources/remotely only"
grep -q 'enum RemotelyMain' Sources/remotely/RemotelyMain.swift || fail "remotely application entry-point name missing"
grep -q '<string>com.local.remotely</string>' Resources/Info.plist || fail "remotely bundle identifier missing"
grep -q 'name: "remotely"' Package.swift || fail "Swift package name is not remotely"
grep -q 'path: "Sources/remotely"' Package.swift || fail "Swift target source path is not remotely-owned"

# Application source must remain native. Documentation may mention the retired
# Python stack, but executable source must not import or invoke it.
if grep -RniE '(^|[^A-Za-z])(python|pyatv|pyobjc|py2app|pip)([^A-Za-z]|$)' Sources "$SCRIPT_DIR/build.sh" Resources; then
  fail "Python-era runtime reference found in native executable/build source"
fi

grep -q 'static let panelWidth: CGFloat = 360' Sources/remotely/AppConstants.swift || fail "widened panel width missing"
grep -q 'static let panelHeight: CGFloat = 720' Sources/remotely/AppConstants.swift || fail "panel height must be 720"
grep -q 'static let keyboardPanelHeight: CGFloat = 770' Sources/remotely/AppConstants.swift || fail "keyboard-expanded panel height must be 770"
grep -q 'static let cornerRadius: CGFloat = 34' Sources/remotely/AppConstants.swift || fail "corner radius changed"
grep -q 'static let longPressSeconds: Double = 0.65' Sources/remotely/AppConstants.swift || fail "long press threshold changed"
grep -q '<string>remotely</string>' Resources/Info.plist || fail "remotely bundle name missing"
grep -q '<string>1.2.12</string>' Resources/Info.plist || fail "v1.2.12 bundle version missing"
awk '/<key>CFBundleVersion<\/key>/{getline; if ($0 ~ /<string>19<\/string>/) found=1} END{exit found ? 0 : 1}' Resources/Info.plist || fail "v1.2.12 build number 19 missing"
grep -q 'PROTOCOL_CORE_REF="052d9a9a0416d577119316ea813aa3b822b408e5"' "$SCRIPT_DIR/build.sh" || fail "pinned protocol-core revision missing"
grep -q '<key>CFBundleIconFile</key>' Resources/Info.plist || fail "app icon declaration missing"
grep -q '<key>LSUIElement</key>' Resources/Info.plist || fail "LSUIElement missing"
grep -q '_companion-link._tcp' Resources/Info.plist || fail "Companion Bonjour declaration missing"
grep -q 'case apps = 1' Sources/remotely/AppModel.swift || fail "Apps panel mode missing"
grep -q 'case preferences = 2' Sources/remotely/AppModel.swift || fail "Preferences panel mode missing"
grep -q 'static let autoSkipOpeningContent = "autoSkipOpeningContent"' Sources/remotely/AppModel.swift || fail "opening-content preference key missing"
grep -q '@Published var autoSkipOpeningContent: Bool' Sources/remotely/AppModel.swift || fail "opening-content preference state missing"
grep -q 'Auto-skip tv ads and pre-roll sequences' Sources/remotely/PreferencesView.swift || fail "opening-content preference toggle missing"
grep -q 'func setAutoSkipOpeningContentEnabled(_ enabled: Bool)' Sources/remotely/AppleTVService.swift || fail "opening-content service bridge missing"
grep -q 'manager.mrpManager.autoSkipOpeningContentEnabled = enabled' Sources/remotely/AppleTVService.swift || fail "opening-content core preference bridge missing"
grep -q 'protocol-core-main-content-start.patch' "$SCRIPT_DIR/build.sh" || fail "main-content protocol patch integration missing"
grep -q 'protocol-core-media-metadata.patch' "$SCRIPT_DIR/build.sh" || fail "supplemental media-metadata protocol patch integration missing"
[[ -f Patches/protocol-core-media-metadata.patch ]] || fail "supplemental media-metadata patch missing"
grep -q 'protocol-core-session-lifecycle.patch' "$SCRIPT_DIR/build.sh" || fail "MRP session-lifecycle protocol patch integration missing"
[[ -f Patches/protocol-core-session-lifecycle.patch ]] || fail "MRP session-lifecycle patch missing"
grep -q 'protocol-core-mrp-recovery.patch' "$SCRIPT_DIR/build.sh" || fail "MRP recovery protocol patch integration missing"
[[ -f Patches/protocol-core-mrp-recovery.patch ]] || fail "MRP recovery patch missing"
grep -q 'private var mrpConnectionGeneration: UInt64 = 0' Patches/protocol-core-mrp-recovery.patch || fail "MRP recovery generation guard missing"
grep -q 'private var mrpReconnectScheduled = false' Patches/protocol-core-mrp-recovery.patch || fail "MRP single-flight reconnect guard missing"
grep -q 'private func scheduleMRPReconnect(for generation: UInt64)' Patches/protocol-core-mrp-recovery.patch || fail "MRP persistent recovery scheduler missing"
grep -q 'self.mrpConnectionGeneration == generation' Patches/protocol-core-mrp-recovery.patch || fail "MRP stale reconnect rejection missing"
grep -q 'case 3: delay = 20' Patches/protocol-core-mrp-recovery.patch || fail "MRP reconnect backoff missing"
grep -q 'default: delay = 30' Patches/protocol-core-mrp-recovery.patch || fail "MRP reconnect backoff cap missing"
grep -q 'case 46:' Patches/protocol-core-session-lifecycle.patch || fail "SetNowPlayingClient lifecycle handling missing from patch"
grep -q 'case 47:' Patches/protocol-core-session-lifecycle.patch || fail "SetNowPlayingPlayer lifecycle handling missing from patch"
grep -q 'case 53:' Patches/protocol-core-session-lifecycle.patch || fail "RemoveClient lifecycle handling missing from patch"
grep -q 'case 54:' Patches/protocol-core-session-lifecycle.patch || fail "RemovePlayer lifecycle handling missing from patch"
[[ "$(grep -c 'firstLengthDelimitedField(number: 1, in: payload).flatMap' Patches/protocol-core-session-lifecycle.patch)" -ge 4 ]] || fail "lifecycle wrapper payload decoding missing from patch"
grep -q 'try merged.merge(serializedData: serialized, partial: true)' Patches/protocol-core-session-lifecycle.patch || fail "same-item protobuf metadata merge missing from patch"
grep -q 'private func clearCurrentPlaybackSnapshot()' Patches/protocol-core-session-lifecycle.patch || fail "playback session reset helper missing from patch"
grep -q 'currentPlayerIdentifier' Patches/protocol-core-session-lifecycle.patch || fail "player identity tracking missing from patch"
grep -q 'explicitlySelectedBundleID' Patches/protocol-core-session-lifecycle.patch || fail "explicit now-playing client selector missing from patch"
grep -q 'lifecycleAllowsActivation' Patches/protocol-core-session-lifecycle.patch || fail "lifecycle-over-heuristic activation gate missing from patch"
grep -Fq 'guard self.playbackQueueRequestGeneration == generation else { return }' Patches/protocol-core-session-lifecycle.patch || fail "stale playback-queue response rejection missing from patch"
grep -q 'explicitlySelectedBundleID == bundleID || currentPlayerBundleID == bundleID' Patches/protocol-core-session-lifecycle.patch || fail "SetNowPlayingPlayer must not activate an unrelated client"
grep -q 'if !removeClient, let playerID' Patches/protocol-core-session-lifecycle.patch || fail "RemovePlayer active-player identity guard missing"
grep -q 'Some third-party players use Stopped as a' Patches/protocol-core-session-lifecycle.patch || fail "transient stopped queue-retention correction missing"
grep -q 'if pbState == .playing, nowPlaying == nil, !contentItems.isEmpty' Patches/protocol-core-session-lifecycle.patch || fail "retained queue resume path missing"
# v1.2.5 preserves the two-second stale-card correction without allowing
# periodic queue requests to overwrite healthy third-party playback state.
grep -q 'protocol-core-now-playing-verification.patch' "$SCRIPT_DIR/build.sh" || fail "teardown-only Now Playing verification patch integration missing"
[[ -f Patches/protocol-core-now-playing-verification.patch ]] || fail "teardown-only Now Playing verification patch missing"
grep -q 'public func verifyNowPlayingTeardown()' Patches/protocol-core-now-playing-verification.patch || fail "teardown-only core verifier API missing"
grep -q 'nowPlayingVerificationPending' Patches/protocol-core-now-playing-verification.patch || fail "single-flight verifier guard missing"
grep -q 'nowPlayingVerificationGeneration' Patches/protocol-core-now-playing-verification.patch || fail "verifier request-generation guard missing"
grep -q 'let sessionGeneration = playbackQueueRequestGeneration' Patches/protocol-core-now-playing-verification.patch || fail "verifier playback-session generation capture missing"
grep -q 'self.playbackQueueRequestGeneration == sessionGeneration' Patches/protocol-core-now-playing-verification.patch || fail "verifier stale-session response rejection missing"
grep -q 'self.currentPlayerBundleID == sessionBundleID' Patches/protocol-core-now-playing-verification.patch || fail "verifier bundle ownership guard missing"
grep -q 'self.currentPlayerIdentifier == sessionPlayerID' Patches/protocol-core-now-playing-verification.patch || fail "verifier player ownership guard missing"
grep -q 'guard reportsStopped || reportsEmptyQueue else { return }' Patches/protocol-core-now-playing-verification.patch || fail "verifier is not restricted to stopped/empty playback"
grep -q 'state.playbackState == .playing { return }' Patches/protocol-core-now-playing-verification.patch || fail "verifier playing-state protection missing"
grep -q 'request.returnContentItemAssetsInUserCompletion = false' Patches/protocol-core-now-playing-verification.patch || fail "verifier must suppress content-item assets"
! grep -A35 'public func verifyNowPlayingTeardown()' Patches/protocol-core-now-playing-verification.patch | grep -q 'handleSetState(response)' || fail "teardown verifier still routes healthy responses through SetState"
grep -A28 'private func clearVerifiedInactivePlayback()' Patches/protocol-core-now-playing-verification.patch | grep -q 'commandsByBundleID.removeValue' || fail "verified teardown must retire stale per-client command cache"
grep -A28 'private func clearVerifiedInactivePlayback()' Patches/protocol-core-now-playing-verification.patch | grep -q 'skipIntervalsByBundleID.removeValue' || fail "verified teardown must retire stale per-client skip interval cache"
grep -q 'RemoveClient is authoritative for the lifetime of that client' Patches/protocol-core-session-lifecycle.patch || fail "confirmed RemoveClient cache retirement missing"
grep -q 'private var nowPlayingVerificationTimer: Timer?' Sources/remotely/AppleTVService.swift || fail "visible stale-session verification timer missing"
grep -Fq 'let shouldRun = (remotePresented || miniRemotePresented) && isConnected' Sources/remotely/AppleTVService.swift || fail "stale-session verifier is not visibility/connection gated"
grep -q 'withTimeInterval: 2.0, repeats: true' Sources/remotely/AppleTVService.swift || fail "stale-session verification cadence must remain two seconds"
grep -q 'manager.mrpManager.verifyNowPlayingTeardown()' Sources/remotely/AppleTVService.swift || fail "service does not invoke teardown-only verifier"
grep -q 'stopNowPlayingVerificationTimer()' Sources/remotely/AppleTVService.swift || fail "stale-session verifier shutdown path missing"
# Existing event-driven and explicit refresh paths must remain available for
# populating metadata; the verifier is never a replacement path.
grep -q 'manager.mrpManager.refreshNowPlaying()' Sources/remotely/AppleTVService.swift || fail "one-shot Now Playing refresh path missing"
grep -q 'scheduleNowPlayingRefresh(after:' Sources/remotely/AppleTVService.swift || fail "post-command one-shot refresh path missing"
grep -q 'nowPlayingSeasonNumber' Sources/remotely/AppleTVService.swift || fail "structured season metadata bridge missing"
grep -q 'nowPlayingEpisodeNumber' Sources/remotely/AppleTVService.swift || fail "structured episode metadata bridge missing"
grep -q 'nowPlayingEpisodeTitle' Sources/remotely/AppleTVService.swift || fail "structured episode-title metadata bridge missing"
grep -q '"artist", "trackArtistName", "subtitle"' Sources/remotely/AppleTVService.swift || fail "generic creator/channel metadata fallback missing"
grep -q 'formattedSeasonEpisode' Sources/remotely/AppleTVService.swift || fail "structured season/episode formatter missing"
grep -q 'Text("Preferences")' Sources/remotely/PreferencesView.swift || fail "Preferences heading missing"
[[ -f Sources/remotely/AppleTVLogoView.swift ]] || fail "shared Apple TV logo view missing"
grep -q 'Image(systemName: "apple.logo")' Sources/remotely/AppleTVLogoView.swift || fail "Apple TV logo mark missing"
grep -q 'Text("tv")' Sources/remotely/AppleTVLogoView.swift || fail "Apple TV logo text missing"
grep -q 'AppConstants.controlBackground' Sources/remotely/AppleTVLogoView.swift || fail "Apple TV logo tile does not use Remote control background styling"
grep -q 'AppConstants.controlBorder' Sources/remotely/AppleTVLogoView.swift || fail "Apple TV logo tile does not use Remote control border styling"
grep -q 'AppleTVLogoTile(size: 72, selected:' Sources/remotely/PreferencesView.swift || fail "shared Apple TV logo tile missing from Preferences"
grep -q 'ScrollView(.horizontal, showsIndicators: false)' Sources/remotely/PreferencesView.swift || fail "Apple TV device icon strip missing"
grep -q 'ForEach(service.devices)' Sources/remotely/PreferencesView.swift || fail "Apple TV device icon list missing"
grep -q 'service.chooseDevice(device.id)' Sources/remotely/PreferencesView.swift || fail "Apple TV icon selection action missing"
grep -q 'Text(device.name)' Sources/remotely/PreferencesView.swift || fail "Apple TV device name label missing"
if grep -q 'Picker("", selection:' Sources/remotely/PreferencesView.swift; then
  fail "legacy Apple TV dropdown remains in Preferences"
fi
grep -q 'NSMenuItem(' Sources/remotely/AppController.swift || fail "menu items missing"
grep -q 'title: "Preferences…"' Sources/remotely/AppController.swift || fail "Preferences menu title missing"
grep -q 'title: "Remote"' Sources/remotely/AppController.swift || fail "Remote menu title missing"
grep -q 'keyEquivalent: "r"' Sources/remotely/AppController.swift || fail "Command-R shortcut missing"
grep -q 'remote.keyEquivalentModifierMask = \[.command\]' Sources/remotely/AppController.swift || fail "Remote command modifier missing"
grep -q 'openRemoteFromMenu' Sources/remotely/AppController.swift || fail "Remote menu action missing"
grep -q 'rotation3DEffect' Sources/remotely/PanelRootView.swift || fail "card-flip 3D rotation missing"

grep -q 'title: "Apps"' Sources/remotely/AppController.swift || fail "Apps menu title missing"
grep -q 'keyEquivalent: "a"' Sources/remotely/AppController.swift || fail "Command-A shortcut missing"
grep -q 'apps.keyEquivalentModifierMask = \[.command\]' Sources/remotely/AppController.swift || fail "Apps command modifier missing"
grep -q 'openAppsFromMenu' Sources/remotely/AppController.swift || fail "Apps menu action missing"
grep -q 'case .apps:' Sources/remotely/PanelRootView.swift || fail "Apps card face missing"
grep -q 'AppsView(service: model.remote)' Sources/remotely/PanelRootView.swift || fail "Apps view integration missing"
[[ -f Sources/remotely/AppsView.swift ]] || fail "AppsView missing"
grep -q 'Text("Apps")' Sources/remotely/AppsView.swift || fail "Apps heading missing"
grep -q 'service.refreshApps()' Sources/remotely/AppsView.swift || fail "Apps refresh-on-open missing"
grep -q 'service.launchApp(app)' Sources/remotely/AppsView.swift || fail "App launch UI action missing"
grep -q 'struct RemoteApp' Sources/remotely/AppleTVService.swift || fail "RemoteApp model missing"
grep -q 'manager.fetchApps()' Sources/remotely/AppleTVService.swift || fail "core app fetch bridge missing"
grep -q 'manager.installedApps' Sources/remotely/AppleTVService.swift || fail "core installed-app bridge missing"
grep -q 'manager.launchApp(bundleID: app.bundleID)' Sources/remotely/AppleTVService.swift || fail "core app-launch bridge missing"
grep -q 'GridItem(.flexible(), spacing: 12)' Sources/remotely/AppsView.swift || fail "two-column Apps grid missing"
grep -q '.aspectRatio(5.0 / 3.0, contentMode: .fit)' Sources/remotely/AppsView.swift || fail "rectangular 5:3 app tiles missing"
grep -q 'GeometryReader { geometry in' Sources/remotely/AppsView.swift || fail "artwork overlay must not control tile geometry"
grep -q '.aspectRatio(contentMode: .fill)' Sources/remotely/AppsView.swift || fail "third-party Apps artwork must fill landscape tiles"
grep -q 'private func builtInSymbol(for app: RemoteApp)' Sources/remotely/AppsView.swift || fail "system-app generic artwork mapping missing"
grep -q 'app.bundleID.hasPrefix("com.apple.")' Sources/remotely/AppsView.swift || fail "Apple system-app fallback missing"
# v1.2.1 Apps launcher custom ordering retained in the maintenance rollback.
grep -q '@State private var isEditing = false' Sources/remotely/AppsView.swift || fail "Apps edit-mode state missing"
grep -q 'LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)' Sources/remotely/AppsView.swift || fail "Apps long-press edit gesture missing"
grep -q 'DragGesture(' Sources/remotely/AppsView.swift || fail "Apps reorder drag gesture missing"
grep -q 'SpatialTapGesture(coordinateSpace: .named(Self.coordinateSpaceName))' Sources/remotely/AppsView.swift || fail "Apps empty-area save/dismiss gesture missing"
grep -q 'private static let appOrderDefaultsKeyPrefix = "appsOrder."' Sources/remotely/AppsView.swift || fail "Apps persisted-order namespace missing"
grep -q 'UserDefaults.standard.set(' Sources/remotely/AppsView.swift || fail "Apps custom order persistence missing"
! grep -q '@State private var isWiggling' Sources/remotely/AppsView.swift || fail "obsolete shared Apps wiggle state remains"
! grep -q 'repeatForever' Sources/remotely/AppsView.swift || fail "Apps edit animation still uses uncancellable repeatForever state"
grep -q 'private struct AppTileWiggleModifier: ViewModifier' Sources/remotely/AppsView.swift || fail "Apps stable wiggle modifier missing"
grep -Fq '.phaseAnimator([false, true])' Sources/remotely/AppsView.swift || fail "Apps phase-based wiggle animation missing"
[[ -f Sources/remotely/AppArtworkLoader.swift ]] || fail "optional App Store artwork loader missing"
grep -q 'fetchAppArtworkDefaultsKey = "fetchAppArtworkFromAppStore"' Sources/remotely/AppConstants.swift || fail "app artwork preference key missing"
grep -q '@AppStorage(AppConstants.fetchAppArtworkDefaultsKey) private var fetchAppArtwork = false' Sources/remotely/PreferencesView.swift || fail "disabled-by-default artwork preference missing"
grep -q 'Fetch app artwork from App Store' Sources/remotely/PreferencesView.swift || fail "App Store artwork toggle missing"
grep -q 'guard enabled else { return }' Sources/remotely/AppArtworkLoader.swift || fail "artwork loader is not gated by opt-in"
grep -q 'https://itunes.apple.com/lookup' Sources/remotely/AppArtworkLoader.swift || fail "Apple App Store lookup endpoint missing"
grep -q 'URLQueryItem(name: "bundleId", value: bundleID)' Sources/remotely/AppArtworkLoader.swift || fail "bundle-ID artwork lookup missing"
grep -q 'if fetchAppArtwork, let image = artworkLoader.image' Sources/remotely/AppsView.swift || fail "artwork display preference gate missing"
grep -q 'flipDegrees = 90 \* direction' Sources/remotely/PanelRootView.swift || fail "card-flip first half missing"
grep -q 'flipDegrees = -90 \* direction' Sources/remotely/PanelRootView.swift || fail "card-flip face swap missing"
grep -q 'keyEquivalent: ","' Sources/remotely/AppController.swift || fail "Command-comma shortcut missing"
grep -q 'keyEquivalent: "q"' Sources/remotely/AppController.swift || fail "Command-Q shortcut missing"
grep -q 'preferences.keyEquivalentModifierMask = \[.command\]' Sources/remotely/AppController.swift || fail "Preferences command modifier missing"
grep -q 'quit.keyEquivalentModifierMask = \[.command\]' Sources/remotely/AppController.swift || fail "Quit command modifier missing"
grep -q 'NSApp.mainMenu = mainMenu' Sources/remotely/AppController.swift || fail "application main menu shortcut routing missing"
grep -q 'statusItem.menu = self.contextMenu' Sources/remotely/AppController.swift || fail "native status-item context menu placement missing"
grep -q 'if service.isPairing' Sources/remotely/PreferencesView.swift || fail "conditional pairing section missing"
! grep -q 'onPairingRequired' Sources/remotely/AppleTVService.swift || fail "obsolete one-shot pairing presentation callback remains"
grep -q 'installPairingPresentation' Sources/remotely/AppController.swift || fail "automatic Preferences pairing presentation missing"
grep -Fq 'remoteService.$isPairing' Sources/remotely/AppController.swift || fail "pairing presentation does not observe durable published state"
grep -q 'AnyCancellable' Sources/remotely/AppController.swift || fail "pairing state subscription storage missing"
grep -q 'self.model.mode = .preferences' Sources/remotely/AppController.swift || fail "pairing state does not switch panel to Preferences"
grep -q 'self.showPanel()' Sources/remotely/AppController.swift || fail "pairing state does not surface the panel"
grep -q 'Text(versionLabel)' Sources/remotely/PreferencesView.swift || fail "Preferences version footer missing"
grep -q 'CFBundleShortVersionString' Sources/remotely/PreferencesView.swift || fail "dynamic app version lookup missing"
grep -q 'deviceInfo.name = "remotely"' "$SCRIPT_DIR/build.sh" || fail "remotely Apple TV client name patch missing"
grep -q 'ForEach(0..<4' Sources/remotely/PreferencesView.swift || fail "four-box PIN UI missing"
grep -q 'sanitized.count == 4' Sources/remotely/PreferencesView.swift || fail "four-digit auto-submit missing"
grep -q 'Remove Paired Device' Sources/remotely/PreferencesView.swift || fail "remove paired device control missing"
grep -q 'com.local.remotely.credentials' Sources/remotely/AppleTVService.swift || fail "remotely Keychain namespace missing from service cleanup"
grep -q 'com.local.remotely.credentials' "$SCRIPT_DIR/build.sh" || fail "remotely Keychain namespace missing from protocol-core patch"
grep -q 'SecItemDelete' Sources/remotely/AppleTVService.swift || fail "Keychain deletion path missing"
grep -q 'func removeSelectedPairedDevice()' Sources/remotely/AppleTVService.swift || fail "selected-device pairing removal missing"
grep -q 'kSecAttrAccount as String: account' Sources/remotely/AppleTVService.swift || fail "pairing removal is not scoped by selected device account"
if grep -q 'removePersistentDomain' Sources/remotely/AppleTVService.swift; then fail "broad persistent-domain pairing reset still present"; fi
if grep -q 'deleteKeychainItems(service:' Sources/remotely/AppleTVService.swift; then fail "broad Keychain service deletion still present"; fi
grep -q 'selectedDeviceStatusText' Sources/remotely/PreferencesView.swift || fail "Preferences does not render selected-device status"
grep -q 'canConnectSelectedDevice' Sources/remotely/PreferencesView.swift || fail "Preferences Connect enabled-state guard missing"
grep -q 'canPairSelectedDevice' Sources/remotely/PreferencesView.swift || fail "Preferences Pair enabled-state guard missing"
grep -q 'canRemoveSelectedPairing' Sources/remotely/PreferencesView.swift || fail "Preferences selected pairing removal guard missing"
if grep -q 'Text("Apple TV")' Sources/remotely/PreferencesView.swift; then fail "removed Apple TV Preferences heading still present"; fi
if grep -Rni 'Choose the Apple TV this remote should control' Sources; then
  fail "removed Preferences helper text still present"
fi
if grep -Rni 'Complete Pairing' Sources; then
  fail "manual pairing submit button still present"
fi

grep -q '.frame(width: 316, height: 316)' Sources/remotely/RemoteView.swift || fail "square clickpad frame missing"
grep -q 'struct RemoteNowPlaying' Sources/remotely/AppleTVService.swift || fail "now-playing service snapshot missing"
grep -q 'manager.mrpManager.nowPlaying' Sources/remotely/AppleTVService.swift || fail "MRP now-playing bridge missing"
grep -q 'manager.mrpManager.seekToPosition' Sources/remotely/AppleTVService.swift || fail "MRP seek bridge missing"
grep -q 'func rewind10()' Sources/remotely/AppleTVService.swift || fail "10-second rewind missing"
grep -q 'func forward10()' Sources/remotely/AppleTVService.swift || fail "10-second forward missing"
grep -q 'state?.isPlaying == true ? "pause.fill" : "play.fill"' Sources/remotely/RemoteView.swift || fail "state-aware play/pause icon missing"
grep -q 'struct NowPlayingTimeline' Sources/remotely/NowPlayingShared.swift || fail "shared draggable Now Playing timeline missing"
if grep -q 'struct VolumeLevelMeter' Sources/remotely/RemoteView.swift; then fail "removed Now Playing volume meter still present"; fi
grep -q 'symbol: "gobackward.10"' Sources/remotely/RemoteView.swift || fail "rewind 10 icon missing"
grep -q 'symbol: "goforward.10"' Sources/remotely/RemoteView.swift || fail "forward 10 icon missing"
grep -q 'parseCombinedTVTitle' Sources/remotely/AppleTVService.swift || fail "local TV metadata parsing missing"
grep -q 'cleanedMediaSegment' Sources/remotely/AppleTVService.swift || fail "robust TV metadata segment parsing missing"
grep -q 'parsed.episodeTitle ?? cleanSecondary' Sources/remotely/AppleTVService.swift || fail "TV secondary-metadata fallback missing"
grep -q '\[\^A-Za-z0-9\]{0,6}' Sources/remotely/AppleTVService.swift || fail "separator-tolerant season/episode parsing missing"
grep -q '\.padding(12)' Sources/remotely/RemoteView.swift || fail "MiniRemote-style Now Playing padding missing"
grep -q 'HStack(alignment: .top, spacing: 12)' Sources/remotely/RemoteView.swift || fail "MiniRemote-style Now Playing artwork gutter missing"
if grep -q 'volumeEstimate' Sources/remotely/AppleTVService.swift; then fail "removed volume estimation code still present"; fi
grep -q 'size: CGSize(width: 42, height: 42)' Sources/remotely/RemoteView.swift || fail "25-percent header control sizing missing"
grep -q 'size: CGSize(width: 57, height: 57)' Sources/remotely/RemoteView.swift || fail "25-percent play/home sizing missing"
grep -q 'size: CGSize(width: 70.13, height: 70.13)' Sources/remotely/RemoteView.swift || fail "15-percent smaller back sizing missing"


grep -q '@State private var showingDeviceSelector = false' Sources/remotely/RemoteView.swift || fail "Remote Apple TV dropdown state missing"
grep -q '\.popover(isPresented: \$showingDeviceSelector' Sources/remotely/RemoteView.swift || fail "Remote Apple TV dropdown presentation missing"
grep -q 'private struct RemoteDeviceSelector: View' Sources/remotely/RemoteView.swift || fail "Remote Apple TV dropdown content missing"
grep -q 'service.configuredDevices.sorted' Sources/remotely/RemoteView.swift || fail "Remote Apple TV dropdown is not based on configured devices"
grep -q 'localizedCaseInsensitiveCompare' Sources/remotely/RemoteView.swift || fail "Remote Apple TV dropdown is not alphabetically sorted"
grep -q 'AppleTVLogoTile(size: 34, selected: selected' Sources/remotely/RemoteView.swift || fail "Remote Apple TV dropdown does not reuse the Preferences logo"
grep -q 'service.selectAndConnectDevice(device.id)' Sources/remotely/RemoteView.swift || fail "Remote Apple TV dropdown does not connect selected device"
grep -q 'func selectAndConnectDevice(_ id: String)' Sources/remotely/AppleTVService.swift || fail "direct Remote device-switch bridge missing"
grep -q 'manager.connectedDeviceID == id' Sources/remotely/AppleTVService.swift || fail "already-connected device guard missing"
grep -q 'manager.connect(to: device)' Sources/remotely/AppleTVService.swift || fail "device switch does not use protocol connect lifecycle"
grep -q '@Published private(set) var configuredDevices: \[RemoteDevice\] = \[\]' Sources/remotely/AppleTVService.swift || fail "configured Apple TV snapshot missing"
grep -q 'kSecAttrAccount as String' Sources/remotely/AppleTVService.swift || fail "configured Apple TV Keychain account lookup missing"
if grep -q 'showPreferences' Sources/remotely/RemoteView.swift Sources/remotely/PanelRootView.swift; then
  fail "Remote Apple TV selector still routes to Preferences"
fi
grep -q '.frame(height: 24)' Sources/remotely/RemoteView.swift || fail "MiniRemote-style Now Playing timeline height missing"
grep -q '.frame(height: 38)' Sources/remotely/RemoteView.swift || fail "MiniRemote-style Now Playing playback height missing"
grep -q '.frame(maxWidth: .infinity, alignment: .bottom)' Sources/remotely/RemoteView.swift || fail "Now Playing bottom-aligned playback row missing"

grep -q 'symbol: "speaker.wave.1.fill"' Sources/remotely/RemoteView.swift || fail "volume-down wave icon missing"
grep -q 'symbol: "speaker.wave.3.fill"' Sources/remotely/RemoteView.swift || fail "volume-up wave icon missing"
! grep -q 'symbol: "speaker.minus.fill"' Sources/remotely/RemoteView.swift || fail "legacy minus volume icon remains"
! grep -q 'symbol: "speaker.plus.fill"' Sources/remotely/RemoteView.swift || fail "legacy plus volume icon remains"
echo "Native UI/source invariants: PASS"

grep -q '.package(name: "ProtocolCore", path: "Vendor/ProtocolCore")' Package.swift || fail "top-level protocol engine is not neutral local-vendored"
grep -q 'RUNTIME_MANIFEST' "$SCRIPT_DIR/build.sh" || fail "runtime-only SwiftProtobuf manifest preparation missing"
if grep -q 'protoc-artifactbundle' Package.swift; then
  fail "top-level Package.swift references protoc binary artifact"
fi

echo "Runtime-only SwiftProtobuf build preparation: PASS"

grep -q '.frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)' Sources/remotely/RemoteView.swift || fail "Remote Apple TV selector pill missing"
grep -q 'glyphSize: 24.86' Sources/remotely/RemoteView.swift || fail "15-percent smaller back glyph missing"

# v1.9 real-time trackpad/Magic Mouse clickpad integration.
[[ -f Sources/remotely/ClickpadSwipeCapture.swift ]] || fail "ClickpadSwipeCapture bridge missing"
grep -q 'NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)' Sources/remotely/ClickpadSwipeCapture.swift || fail "precise scroll event monitor missing"
grep -q 'event.hasPreciseScrollingDeltas' Sources/remotely/ClickpadSwipeCapture.swift || fail "precise-input gate missing"
grep -q 'event.isDirectionInvertedFromDevice' Sources/remotely/ClickpadSwipeCapture.swift || fail "Natural Scrolling normalization missing"
grep -q 'private let sensitivity: CGFloat = 0.25' Sources/remotely/ClickpadSwipeCapture.swift || fail "gesture sensitivity baseline missing"
grep -q 'case .ended, .cancelled:' Sources/remotely/ClickpadSwipeCapture.swift || fail "gesture end handling missing"
grep -q 'onEnded?(cumulativeTranslation, releaseVelocity)' Sources/remotely/ClickpadSwipeCapture.swift || fail "release velocity forwarding missing"
grep -q 'ClickpadSwipeCapture(' Sources/remotely/RemoteView.swift || fail "clickpad gesture overlay missing"
grep -q '.allowsHitTesting(false)' Sources/remotely/RemoteView.swift || fail "click-through gesture overlay missing"
grep -q 'manager.touchBegan(referenceSize: referenceSize)' Sources/remotely/AppleTVService.swift || fail "touch begin service bridge missing"
grep -q 'manager.touchMoved(translation: translation)' Sources/remotely/AppleTVService.swift || fail "touch move service bridge missing"
grep -q 'manager.touchEnded(translation: translation, velocity: velocity)' Sources/remotely/AppleTVService.swift || fail "touch end service bridge missing"
grep -q 'public func touchBegan(referenceSize: CGSize)' "$SCRIPT_DIR/build.sh" || fail "core touch begin API guard missing"
grep -q 'public func touchMoved(translation: CGPoint)' "$SCRIPT_DIR/build.sh" || fail "core touch move API guard missing"
grep -q 'public func touchEnded(translation: CGPoint, velocity: CGPoint)' "$SCRIPT_DIR/build.sh" || fail "core touch end API guard missing"

echo "Trackpad clickpad gesture invariants: PASS"

# stable /Applications installation workflow.
[[ -x "$SCRIPT_DIR/install.sh" ]] || fail "install.sh missing or not executable"
grep -q 'DESTINATION_APP="\$DESTINATION_DIR/remotely.app"' "$SCRIPT_DIR/install.sh" || fail "stable /Applications destination missing"
grep -q 'EXPECTED_BUNDLE_ID="com.local.remotely"' "$SCRIPT_DIR/install.sh" || fail "installer bundle-ID guard missing"
grep -q 'codesign --verify --deep --strict "\$SOURCE_APP"' "$SCRIPT_DIR/install.sh" || fail "pre-install code-signature verification missing"
grep -q '/usr/bin/ditto "\$SOURCE_APP" "\$DESTINATION_APP"' "$SCRIPT_DIR/install.sh" || fail "app-bundle copy path missing"
grep -q 'codesign --verify --deep --strict "\$DESTINATION_APP"' "$SCRIPT_DIR/install.sh" || fail "post-install code-signature verification missing"
grep -q '/usr/bin/open "\$DESTINATION_APP"' "$SCRIPT_DIR/install.sh" || fail "installed application launch missing"
grep -q 'PREVIOUS_BUNDLE_ID=' "$SCRIPT_DIR/install.sh" || fail "generic previous bundle-ID migration state missing"
grep -q '/usr/bin/defaults export "$PREVIOUS_BUNDLE_ID" -' "$SCRIPT_DIR/install.sh" || fail "preferences-domain export migration missing"
grep -q '/usr/bin/defaults import "$EXPECTED_BUNDLE_ID"' "$SCRIPT_DIR/install.sh" || fail "preferences-domain import migration missing"
grep -Fq 'run_step 5 install_and_launch' "$SCRIPT_DIR/build.sh" || fail "build does not install and launch as part of the main pipeline"

echo "Stable /Applications installation invariants: PASS"

# panel-presentation stability retained in v1.9.33.
grep -q 'private var panelPresented = false' Sources/remotely/AppController.swift || fail "explicit panel presentation state missing"
grep -q 'func applicationDidResignActive' Sources/remotely/AppController.swift || fail "panel deactivation reset missing"
grep -q 'NSApp.currentEvent?.type == .rightMouseUp' Sources/remotely/AppController.swift || fail "status click nil-event fallback missing"
grep -q 'panel.orderFrontRegardless()' Sources/remotely/AppController.swift || fail "deterministic panel front ordering missing"
grep -q 'remoteService.refreshNowPlaying()' Sources/remotely/AppController.swift || fail "Remote presentation Now Playing refresh missing"

echo "Panel presentation invariants: PASS"

# Basic transport is a remotely-level capability while connected. Optional
# per-client SupportedCommands advertising must never disable standard playback UI.
! grep -q 'canSkipBackward\|canSkipForward' Sources/remotely/AppleTVService.swift Sources/remotely/RemoteView.swift Sources/remotely/MiniRemoteView.swift || fail "legacy advertised skip-capability UI gate remains"
! grep -q 'supportedCommands.contains(.previousTrack)\|supportedCommands.contains(.nextTrack)\|supportedCommands.contains(.skipBackward)\|supportedCommands.contains(.skipForward)' Sources/remotely/AppleTVService.swift || fail "basic transport still depends on advertised SupportedCommands"
grep -q 'manager.mrpManager.sendCommand(.previousTrack)' Sources/remotely/AppleTVService.swift || fail "unconditional previous-track sender missing"
grep -q 'manager.mrpManager.sendCommand(.nextTrack)' Sources/remotely/AppleTVService.swift || fail "unconditional next-track sender missing"
grep -q 'manager.mrpManager.sendSkip(.skipBackward, interval: 10)' Sources/remotely/AppleTVService.swift || fail "native 10-second backward skip missing"
grep -q 'manager.mrpManager.sendSkip(.skipForward, interval: 10)' Sources/remotely/AppleTVService.swift || fail "native 10-second forward skip missing"
grep -q 'enabled: service.isConnected' Sources/remotely/RemoteView.swift || fail "Remote basic transport is not connection-gated"
grep -q 'enabled: service.isConnected' Sources/remotely/MiniRemoteView.swift || fail "MiniRemote basic transport is not connection-gated"
if grep -q 'seek(to: max(0, state.position - 10))' Sources/remotely/AppleTVService.swift; then fail "rewind still synthesizes an absolute seek"; fi
if grep -q 'seek(to: min(state.duration, state.position + 10))' Sources/remotely/AppleTVService.swift; then fail "forward still synthesizes an absolute seek"; fi
if grep -q 'bounded-recovery' Sources/remotely/AppleTVService.swift; then fail "removed duration-driven bounded recovery remains"; fi
if grep -q 'maxNowPlayingRecoveryAttempts' Sources/remotely/AppleTVService.swift; then fail "removed recovery-attempt budget remains"; fi
if grep -q 'nowPlayingRecoveryInterval' Sources/remotely/AppleTVService.swift; then fail "removed duration-recovery throttle remains"; fi
if grep -q 'companion-connected-immediate' Sources/remotely/AppleTVService.swift; then fail "removed Companion immediate queue refresh remains"; fi
if grep -q 'companion-connected-delayed' Sources/remotely/AppleTVService.swift; then fail "removed Companion delayed queue refresh remains"; fi
if grep -q 'service.refreshNowPlaying()' Sources/remotely/RemoteView.swift; then fail "RemoteView still issues a duplicate onAppear queue refresh"; fi
grep -q 'public func sendSkip(_ command: MediaCommand, interval: Float = 15)' "$SCRIPT_DIR/build.sh" || fail "build does not guard native interval skip API"
grep -q "case skipForward' \"\$media_command\"" "$SCRIPT_DIR/build.sh" || fail "build does not guard skipForward enum case"
grep -q "case skipBackward' \"\$media_command\"" "$SCRIPT_DIR/build.sh" || fail "build does not guard skipBackward enum case"

echo "native skip / recovery-removal invariants: PASS"

# stabilization removes diagnostic-only source/logging machinery.
[[ ! -f Sources/remotely/NowPlayingDiagnosticLog.swift ]] || fail "diagnostic file logger remains in stabilization source"
[[ ! -f Patches/protocol-core-now-playing-diagnostics.patch ]] || fail "diagnostic core patch remains in stabilization source"
[[ ! -f collect_diagnostics.sh ]] || fail "diagnostic collection helper remains in stabilization source"
if grep -RniE 'NowPlayingDiagnosticLog|diagnosticHandler|diagnosticReason:|service-queue-refresh|core-now-playing shape=' Sources "$SCRIPT_DIR/build.sh" Patches; then
  fail "diagnostic-only instrumentation remains in stabilization source"
fi

echo "diagnostic cleanup invariants: PASS"

# retains v1.9.5 valid Now Playing state when text metadata is temporarily absent.
[[ -f Patches/protocol-core-now-playing-content.patch ]] || fail "protocol-core content-validity patch missing"
grep -q 'let hasTextContent =' Patches/protocol-core-now-playing-content.patch || fail "textual-content validity predicate missing"
grep -q 'meta.hasSubtitle' Patches/protocol-core-now-playing-content.patch || fail "subtitle validity signal missing"
grep -q 'let hasPlaybackContent =' Patches/protocol-core-now-playing-content.patch || fail "playback-content validity predicate missing"
grep -q 'meta.hasDuration' Patches/protocol-core-now-playing-content.patch || fail "duration validity signal missing"
grep -q 'meta.hasElapsedTime' Patches/protocol-core-now-playing-content.patch || fail "elapsed-time validity signal missing"
grep -q 'meta.hasPlaybackRate' Patches/protocol-core-now-playing-content.patch || fail "playback-rate validity signal missing"
grep -q 'item.hasArtworkData' Patches/protocol-core-now-playing-content.patch || fail "artwork validity signal missing"
grep -q 'let hasContent = hasTextContent || hasPlaybackContent' Patches/protocol-core-now-playing-content.patch || fail "combined Now Playing validity predicate missing"
grep -Fq 'Text(state?.title ?? (state == nil ? "Nothing Playing" : "Now Playing"))' Sources/remotely/NowPlayingShared.swift || fail "degraded Now Playing title fallback missing"
grep -q 'Applying Now Playing content-validity correction' "$SCRIPT_DIR/build.sh" || fail "build does not apply the content-validity correction"

echo "missing-text Now Playing invariants: PASS"

#  isolate MRP state by media client so unrelated Apple TV players cannot
# overwrite the active player's commands, playback state, queue, or content.
[[ -f Patches/protocol-core-player-isolation.patch ]] || fail "protocol-core player-isolation patch missing"
grep -q 'private var commandsByBundleID:' Patches/protocol-core-player-isolation.patch || fail "per-client command cache patch missing"
grep -q 'private var skipIntervalsByBundleID:' Patches/protocol-core-player-isolation.patch || fail "per-client skip-interval cache patch missing"
grep -q 'private var currentPlayerBundleID:' Patches/protocol-core-player-isolation.patch || fail "active client selector patch missing"
grep -q 'private func activatePlayer(bundleID: String)' Patches/protocol-core-player-isolation.patch || fail "player activation patch missing"
grep -q 'if isPlaying {' Patches/protocol-core-player-isolation.patch || fail "playing-client activation rule missing"
grep -q 'currentPlayerBundleID == nil && hasQueueItems' Patches/protocol-core-player-isolation.patch || fail "initial queue activation rule missing"
grep -q 'guard shouldApplyPlaybackState else { return }' Patches/protocol-core-player-isolation.patch || fail "inactive playback-state guard missing"
grep -q 'bundleID != currentPlayerBundleID' Patches/protocol-core-player-isolation.patch || fail "inactive content-update guard missing"
grep -q 'Applying MRP player-state isolation correction' "$SCRIPT_DIR/build.sh" || fail "build does not apply player-isolation correction"
grep -q 'commandsByBundleID' "$SCRIPT_DIR/build.sh" || fail "build does not verify per-client command cache"
grep -q 'currentPlayerBundleID' "$SCRIPT_DIR/build.sh" || fail "build does not verify selected media client"

echo "MRP player isolation invariants: PASS"

# Explicit lifecycle ownership and same-item metadata retention. Modern tvOS
# publishes now-playing client/player selection/removal separately from SetState;
# partial queue updates for an unchanged item must not erase descriptive fields.
grep -q 'handleSetNowPlayingClient' Patches/protocol-core-session-lifecycle.patch || fail "SetNowPlayingClient handler missing"
grep -q 'handleSetNowPlayingPlayer' Patches/protocol-core-session-lifecycle.patch || fail "SetNowPlayingPlayer handler missing"
grep -q 'handleRemoveClient' Patches/protocol-core-session-lifecycle.patch || fail "RemoveClient handler missing"
grep -q 'handleRemovePlayer' Patches/protocol-core-session-lifecycle.patch || fail "RemovePlayer handler missing"
grep -q 'mergeWithCachedItemIfSame' Patches/protocol-core-session-lifecycle.patch || fail "same-item queue merge helper missing"
grep -q 'applyPlaybackQueue' Patches/protocol-core-session-lifecycle.patch || fail "queue merge application missing"
grep -q 'requestNowPlayingForLifecycleChange' Patches/protocol-core-session-lifecycle.patch || fail "lifecycle refresh request missing"
grep -q 'explicitlySelectedBundleID == nil || explicitlySelectedBundleID == bundleID' Patches/protocol-core-session-lifecycle.patch || fail "background playing-client reactivation guard missing"
grep -q 'Applying MRP session lifecycle and partial-metadata correction' "$SCRIPT_DIR/build.sh" || fail "build does not apply session-lifecycle correction"

echo "MRP session lifecycle / metadata retention invariants: PASS"

# Keyboard Search: Companion text-input focus drives a live RTI field
# above the clickpad. Every edit is mirrored immediately; only tvOS focus-end
# dismisses the field. The panel grows only while Remote shows this protocol UI.
[[ -f Patches/protocol-core-keyboard-focus.patch ]] || fail "protocol-core keyboard-focus patch missing"
grep -q '_tiStarted' Patches/protocol-core-keyboard-focus.patch || fail "Companion _tiStarted handling missing from keyboard patch"
grep -q '_tiStopped' Patches/protocol-core-keyboard-focus.patch || fail "Companion _tiStopped handling missing from keyboard patch"
grep -q 'private func updateTextInputFocus(from content: OPACK.Value?)' Patches/protocol-core-keyboard-focus.patch || fail "keyboard focus helper missing from core patch"
grep -q 'self?.sentText = result.currentText' Patches/protocol-core-keyboard-focus.patch || fail "keyboard text-session synchronization missing from core patch"
grep -q 'Applying Companion keyboard-focus correction' "$SCRIPT_DIR/build.sh" || fail "build does not apply Companion keyboard-focus correction"
grep -Fq 'self?.updateTextInputFocus(from: response["_c"])' "$SCRIPT_DIR/build.sh" || fail "build does not verify initial Companion keyboard focus snapshot"
grep -q '@Published private(set) var keyboardInputRequested = false' Sources/remotely/AppleTVService.swift || fail "keyboard visibility bridge missing"
grep -q 'manager.keyboardFocused' Sources/remotely/AppleTVService.swift || fail "Keyboard Search is not driven by protocol focus state"
grep -q 'func updateKeyboardText(_ text: String)' Sources/remotely/AppleTVService.swift || fail "live keyboard text bridge missing"
grep -q 'manager.updateRemoteText(text)' Sources/remotely/AppleTVService.swift || fail "live keyboard text is not forwarded through Companion RTI"
if grep -q 'submitKeyboardText' Sources/remotely/AppleTVService.swift Sources/remotely/RemoteView.swift; then
  fail "submit-on-Return Keyboard Search behavior remains"
fi
if grep -q 'suppressKeyboardInputUntilFocusEnds' Sources/remotely/AppleTVService.swift; then
  fail "local keyboard dismissal suppression remains; tvOS must own field lifetime"
fi
grep -q 'if service.keyboardInputRequested' Sources/remotely/RemoteView.swift || fail "conditional keyboard field presentation missing"
grep -q 'TextField("Search", text: \$keyboardText)' Sources/remotely/RemoteView.swift || fail "Keyboard Search text field missing"
grep -q '\.frame(width: AppConstants.panelContentWidth, height: 42)' Sources/remotely/RemoteView.swift || fail "Keyboard Search field does not use widened panel content width"
grep -q '\.fill(AppConstants.controlBackground)' Sources/remotely/RemoteView.swift || fail "Keyboard Search field does not use Remote control fill"
grep -q '\.stroke(AppConstants.controlBorder, lineWidth: 0.8)' Sources/remotely/RemoteView.swift || fail "Keyboard Search field does not use Remote control border"
grep -q '\.focused(\$keyboardFieldFocused)' Sources/remotely/RemoteView.swift || fail "Keyboard Search field focus binding missing"
grep -q '\.onChange(of: keyboardText)' Sources/remotely/RemoteView.swift || fail "Keyboard Search does not mirror edits live"
grep -q 'service.updateKeyboardText(text)' Sources/remotely/RemoteView.swift || fail "Keyboard Search live edit is not forwarded"
grep -q '\.onSubmit {' Sources/remotely/RemoteView.swift || fail "Keyboard Search Return focus-preservation handler missing"
if grep -qE 'keyboard.*(Button|button)|search.*(Button|button)' Sources/remotely/RemoteView.swift; then
  fail "manual Keyboard Search button/toggle found; field must be protocol-driven only"
fi
grep -q 'private var desiredPanelHeight: CGFloat' Sources/remotely/AppController.swift || fail "dynamic keyboard panel geometry missing"
grep -q 'AppConstants.remotePanelHeight' Sources/remotely/AppController.swift || fail "dynamic Remote panel height calculation missing"
grep -q 'topEdge - height' Sources/remotely/AppController.swift || fail "dynamic panel resize does not preserve dragged top edge"
grep -q 'onKeyboardInputVisibilityChanged' Sources/remotely/AppController.swift || fail "AppKit shell is not notified of keyboard visibility changes"
grep -q 'onModeChanged' Sources/remotely/AppModel.swift || fail "panel mode geometry callback missing"
grep -q '@ObservedObject private var remote: AppleTVService' Sources/remotely/PanelRootView.swift || fail "panel root does not observe keyboard visibility"
grep -q 'AppConstants.remotePanelHeight' Sources/remotely/PanelRootView.swift || fail "panel root does not adopt dynamic Remote height"

echo "Keyboard Search invariants: PASS"

# energy stabilization: first-party state synchronization is event-driven.
# There must be no permanent 5 Hz service poll; only a 1 Hz playback-clock timer
# may exist, and AppController must explicitly stop it when Remote is not visible.
if grep -q 'pollTimer' Sources/remotely/AppleTVService.swift; then
  fail "legacy continuous service poll remains"
fi
if grep -q 'withTimeInterval: 0.20' Sources/remotely/AppleTVService.swift; then
  fail "legacy 5 Hz state timer remains"
fi
grep -q 'import Observation' Sources/remotely/AppleTVService.swift || fail "Observation framework bridge missing"
grep -q 'withObservationTracking {' Sources/remotely/AppleTVService.swift || fail "event-driven core observation missing"
grep -q 'private func observeManagerState()' Sources/remotely/AppleTVService.swift || fail "Companion/discovery observation missing"
grep -q 'private func observeMRPState()' Sources/remotely/AppleTVService.swift || fail "MRP observation missing"
grep -q 'private func refreshManagerSnapshot()' Sources/remotely/AppleTVService.swift || fail "manager snapshot refresh missing"
grep -q 'private func refreshMRPSnapshot()' Sources/remotely/AppleTVService.swift || fail "MRP snapshot refresh missing"
grep -q 'func setRemotePresentation(isVisible: Bool)' Sources/remotely/AppleTVService.swift || fail "Remote visibility energy gate missing"
grep -q 'withTimeInterval: 1.0' Sources/remotely/AppleTVService.swift || fail "visible timeline 1 Hz cadence missing"
grep -q 'timer.tolerance = 0.25' Sources/remotely/AppleTVService.swift || fail "timeline timer tolerance missing"
grep -q '(remotePresented || miniRemotePresented)' Sources/remotely/AppleTVService.swift || fail "timeline timer is not main/MiniRemote presentation gated"
grep -q 'nowPlaying?.isPlaying == true' Sources/remotely/AppleTVService.swift || fail "timeline timer is not playback gated"
grep -q 'updateRemotePresentationState()' Sources/remotely/AppController.swift || fail "AppKit Remote visibility propagation missing"
grep -q 'let remoteVisible = panelPresented && model.mode == .remote' Sources/remotely/AppController.swift || fail "Remote timer visibility is not scoped to visible Remote face"
if grep -q 'refreshPublishedState' Sources/remotely/AppleTVService.swift; then
  fail "legacy monolithic polling snapshot remains"
fi

echo "event-driven energy invariants: PASS"

# discovery-status correction: core discovery runs continuously, while
# the Preferences Scan label is only a transient user-action acknowledgement.
! grep -q '@Published private(set) var isScanning' Sources/remotely/AppleTVService.swift || fail "app-owned persistent scan flag should not mirror continuous core discovery"
! grep -q '_ = manager.isScanning' Sources/remotely/AppleTVService.swift || fail "continuous core discovery state should not drive Preferences scan progress"
grep -q 'scheduleScanStatusReset()' Sources/remotely/AppleTVService.swift || fail "manual scan status reset missing"
grep -q 'self.statusText == "Scanning…"' Sources/remotely/AppleTVService.swift || fail "scan status reset must not overwrite newer connection status"
grep -q 'Self.displayStatus(rawStatus)' Sources/remotely/AppleTVService.swift || fail "scan status reset must return to actual connection state"
echo "discovery status invariants: PASS"

# active-device persistence regression guard.
! grep -R -q 'persistSelection' Sources/remotely || fail "stale persistSelection reference remains after device-state separation"
echo "active-device persistence invariants: PASS"

# build hygiene: patch backup files must never reach SwiftPM.
grep -q "find \"\$CORE_DIR\" -type f -name '\\*.orig' -delete" "$SCRIPT_DIR/build.sh" || fail "build does not remove .orig patch backups"
grep -q "find \"\$CORE_DIR\" -type f -name '\\*.rej' -print -quit" "$SCRIPT_DIR/build.sh" || fail "build does not reject .rej patch artifacts"
grep -q 'Could not remove patch backup artifacts' "$SCRIPT_DIR/build.sh" || fail "build does not verify .orig cleanup"
if find . -path './Vendor' -prune -o -type f -name '*.orig' -print | grep -q .; then fail "source archive contains .orig patch artifact"; fi

echo "patch-artifact cleanup invariants: PASS"

grep -q 'var remoteDeviceID: String?' Sources/remotely/AppleTVService.swift || fail "active Remote device identity bridge missing"
grep -q 'var remoteDeviceName: String' Sources/remotely/AppleTVService.swift || fail "active Remote device name bridge missing"
grep -q 'connectedDeviceID ?? selectedDeviceID' Sources/remotely/AppleTVService.swift || fail "Remote device identity does not prefer live connection"
grep -q 'Text(service.remoteDeviceName)' Sources/remotely/RemoteView.swift || fail "Remote header is not using live connected device name"
grep -q 'service.remoteDeviceID == device.id' Sources/remotely/RemoteView.swift || fail "Remote dropdown selection is not using live connected identity"
! grep -A8 'func chooseDevice' Sources/remotely/AppleTVService.swift | grep -q 'persistConnectedDevice' || fail "Preferences selection must not persist as a connected device"

# Stable local code-signing invariants. Successive remotely builds must share a
# designated requirement instead of using ad-hoc, build-specific identities.
grep -Fq 'SIGNING_IDENTITY_NAME="${REMOTELY_SIGNING_IDENTITY:-remotely Local Signing}"' "$SCRIPT_DIR/build.sh" || { echo "Stable remotely signing identity is not configured." >&2; exit 1; }
[[ -x "$SCRIPT_DIR/setup_signing.sh" ]] || { echo "setup_signing.sh is missing or not executable." >&2; exit 1; }
grep -Fq 'security find-identity -v -p codesigning' "$SCRIPT_DIR/build.sh" || { echo "Stable signing identity lookup is missing." >&2; exit 1; }
grep -Fq 'Provisioning the local signing identity...' "$SCRIPT_DIR/build.sh" || { echo "build.sh does not automatically provision the signing identity." >&2; exit 1; }
grep -Fq 'REMOTELY_SIGNING_IDENTITY="$SIGNING_IDENTITY_NAME" "$SCRIPT_DIR/setup_signing.sh"' "$SCRIPT_DIR/build.sh" || { echo "build.sh is not invoking setup_signing.sh with the configured identity." >&2; exit 1; }
grep -Fq 'openssl pkcs12 -export' "$SCRIPT_DIR/setup_signing.sh" || { echo "Signing identity PKCS#12 creation is missing." >&2; exit 1; }
grep -Fq 'security import "$P12_FILE"' "$SCRIPT_DIR/setup_signing.sh" || { echo "Signing identity Keychain import is missing." >&2; exit 1; }
grep -Fq -- '-T /usr/bin/codesign' "$SCRIPT_DIR/setup_signing.sh" || { echo "codesign private-key ACL authorization is missing." >&2; exit 1; }
grep -Fq 'security add-trusted-cert' "$SCRIPT_DIR/setup_signing.sh" || { echo "Self-signed certificate trust fallback is missing." >&2; exit 1; }
grep -Fq 'codesign --force --deep --sign "$signing_identity_hash" "$APP"' "$SCRIPT_DIR/build.sh" || { echo "Stable signing invocation is missing." >&2; exit 1; }
if grep -Fq 'codesign --force --deep --sign - ' "$SCRIPT_DIR/build.sh"; then
  echo "Ad-hoc signing must not be reintroduced." >&2
  exit 1
fi
grep -Fq 'designated_requirement' "$SCRIPT_DIR/build.sh" || { echo "Designated-requirement verification is missing." >&2; exit 1; }
grep -Fq '*cdhash*' "$SCRIPT_DIR/build.sh" || { echo "Build-specific cdhash rejection is missing." >&2; exit 1; }
echo "Stable local code-signing invariants: PASS"

# Single-command build/install pipeline with a fixed six-row Terminal.app
# dashboard. Every task row is exactly 53 columns, all rows are visible from the
# start, real progress rewrites only the matching row, and the cursor stays
# hidden until the dashboard is complete. No timer-driven/fabricated progress.
grep -Fq 'STAGE_LABELS=(' "$SCRIPT_DIR/build.sh" || fail "fixed build-stage labels missing"
for stage in \
  "Checking environment" \
  "Validating source" \
  "Fetching dependencies" \
  "Building release" \
  "Signing application" \
  "Installing & launching"; do
  grep -Fq "$stage" "$SCRIPT_DIR/build.sh" || fail "build stage missing: $stage"
done
grep -Fq 'BAR_WIDTH=24' "$SCRIPT_DIR/build.sh" || fail "fixed 24-cell progress bar missing"
grep -Fq 'LABEL_WIDTH=22' "$SCRIPT_DIR/build.sh" || fail "fixed build label width missing"
grep -Fq 'DASHBOARD_LINES=${#STAGE_LABELS[@]}' "$SCRIPT_DIR/build.sh" || fail "fixed dashboard row count missing"
grep -Fq 'show_initial_dashboard()' "$SCRIPT_DIR/build.sh" || fail "initial all-task dashboard renderer missing"
grep -Fq 'progress_line "$i" 0 pending >&3' "$SCRIPT_DIR/build.sh" || fail "pending task rows are not pre-rendered"
grep -Fq "printf '\\033[%dA\\r%s\\033[%dB\\r'" "$SCRIPT_DIR/build.sh" || fail "fixed-row Terminal.app repaint missing"
grep -Fq "printf '\\033[?25l' >&3" "$SCRIPT_DIR/build.sh" || fail "build cursor hide sequence missing"
grep -Fq "printf '\\033[?25h' >&3" "$SCRIPT_DIR/build.sh" || fail "build cursor restore sequence missing"
grep -Fq 'trap cleanup_terminal EXIT INT TERM' "$SCRIPT_DIR/build.sh" || fail "cursor restore trap missing"
! grep -Fq '\\033[2K' "$SCRIPT_DIR/build.sh" || fail "line-clear repaint sequence should not be needed"
! grep -Fq 'sleep 0.25' "$SCRIPT_DIR/build.sh" || fail "timer-driven progress remains"
! grep -Fq 'kill -0 "$pid"' "$SCRIPT_DIR/build.sh" || fail "background polling progress remains"
! grep -Fq 'STAGE_TICK_DIVISORS' "$SCRIPT_DIR/build.sh" || fail "fabricated time-based progress divisors remain"
grep -Fq 'git_progress_filter' "$SCRIPT_DIR/build.sh" || fail "Git transfer progress parser missing"
grep -Fq 'fetch --progress --depth 1' "$SCRIPT_DIR/build.sh" || fail "Git fetch native progress missing"
grep -Fq 'clone --progress --depth 1' "$SCRIPT_DIR/build.sh" || fail "Git clone native progress missing"
grep -Fq 'swift_build_progress_filter' "$SCRIPT_DIR/build.sh" || fail "SwiftPM build progress parser missing"
grep -Fq 'if [[ "$line" =~ \[([0-9]+)/([0-9]+)\] ]]' "$SCRIPT_DIR/build.sh" || fail "SwiftPM current/total counter parser missing"
grep -Fq 'seen * 90 / total_sections' "$SCRIPT_DIR/build.sh" || fail "validation-section progress missing"
grep -Fq 'report_progress 70' "$SCRIPT_DIR/build.sh" || fail "concrete stage checkpoint progress missing"
grep -Fq 'REMOTELY_BUILD_PIPELINE=1 "$SCRIPT_DIR/install.sh"' "$SCRIPT_DIR/build.sh" || fail "build does not invoke stable installer"
grep -Fq '__REMOTELY_PROGRESS__:' "$SCRIPT_DIR/install.sh" || fail "installer progress checkpoints missing"
grep -Fq 'prepare_install_authorization' "$SCRIPT_DIR/build.sh" || fail "install authorization preflight missing"
grep -Fq 'show_initial_dashboard' "$SCRIPT_DIR/build.sh" || fail "all-task dashboard is not shown before build stages"
grep -Fq 'run_step 0 preflight_environment' "$SCRIPT_DIR/build.sh" || fail "build pipeline preflight stage missing"
grep -Fq 'run_step 1 validate_sources' "$SCRIPT_DIR/build.sh" || fail "build does not run source validation automatically"
grep -Fq 'run_step 2 fetch_external_dependencies' "$SCRIPT_DIR/build.sh" || fail "dependency preparation stage missing"
grep -Fq 'run_step 3 build_release_app' "$SCRIPT_DIR/build.sh" || fail "release build stage missing"
grep -Fq 'run_step 4 sign_application' "$SCRIPT_DIR/build.sh" || fail "signing stage missing"
grep -Fq 'run_step 5 install_and_launch' "$SCRIPT_DIR/build.sh" || fail "install/launch stage missing"
grep -Fq 'LOG_FILE="$LOG_DIR/build.log"' "$SCRIPT_DIR/build.sh" || fail "persistent compact-build log path missing"
grep -Fq 'tail -n 35 "$LOG_FILE"' "$SCRIPT_DIR/build.sh" || fail "failure log-tail reporting missing"
echo "integrated build/live progress invariants: PASS"

grep -Fq '#!/bin/bash' "$SCRIPT_DIR/build.sh" || fail "build.sh must use the stable /bin/bash interpreter"
! grep -Eq 'local[[:space:]]+status=' "$SCRIPT_DIR/build.sh" || fail "build runner uses zsh-reserved status variable"
grep -Fq 'local step_exit_code=0' "$SCRIPT_DIR/build.sh" || fail "build runner exit-code variable missing"
grep -Fq -- '--self-test-progress' "$SCRIPT_DIR/build.sh" || fail "build progress runtime self-test mode missing"

progress_file="$(mktemp "${TMPDIR:-/tmp}/remotely-progress-selftest.XXXXXX")"
initial_dashboard="$(mktemp "${TMPDIR:-/tmp}/remotely-progress-dashboard.XXXXXX")"
if ! "$SCRIPT_DIR/build.sh" --self-test-progress > "$progress_file" 2>&1; then
  rm -f "$progress_file" "$initial_dashboard"
  fail "build progress runtime self-test failed"
fi
[[ "$(LC_ALL=C tr -cd '\n' < "$progress_file" | wc -c | tr -d ' ')" == "6" ]] || { rm -f "$progress_file" "$initial_dashboard"; fail "progress self-test must create exactly six physical task rows"; }
LC_ALL=C grep -Fq $'\033[?25l' "$progress_file" || { rm -f "$progress_file" "$initial_dashboard"; fail "progress self-test did not hide the cursor"; }
LC_ALL=C grep -Fq $'\033[?25h' "$progress_file" || { rm -f "$progress_file" "$initial_dashboard"; fail "progress self-test did not restore the cursor"; }
[[ "$(LC_ALL=C grep -Fo $'\033[?25l' "$progress_file" | wc -l | tr -d ' ')" == "1" ]] || { rm -f "$progress_file" "$initial_dashboard"; fail "progress self-test hid the cursor more than once"; }
[[ "$(LC_ALL=C grep -Fo $'\033[?25h' "$progress_file" | wc -l | tr -d ' ')" == "1" ]] || { rm -f "$progress_file" "$initial_dashboard"; fail "progress self-test restored the cursor more than once"; }
# Skip the six-byte cursor-hide sequence, then capture the six rows printed at launch.
dd if="$progress_file" of="$initial_dashboard" bs=1 skip=6 count=324 2>/dev/null
awk 'length($0) != 53 { exit 1 }' "$initial_dashboard" || { rm -f "$progress_file" "$initial_dashboard"; fail "initial progress dashboard rows are not fixed at 53 columns"; }
for stage in "Self-test one" "Self-test two" "Self-test three" "Self-test four" "Self-test five" "Self-test six"; do
  [[ "$(grep -Fc "$stage" "$initial_dashboard" | tr -d ' ')" == "1" ]] || { rm -f "$progress_file" "$initial_dashboard"; fail "initial dashboard did not list stage exactly once: $stage"; }
done
for bar in \
  '[####--------------------]' \
  '[##########--------------]' \
  '[################--------]' \
  '[#######################-]' \
  '[########################]'; do
  grep -Fq "$bar" "$progress_file" || { rm -f "$progress_file" "$initial_dashboard"; fail "progress self-test did not render intermediate bar: $bar"; }
done
[[ "$(grep -Fo '[########################]' "$progress_file" | wc -l | tr -d ' ')" == "6" ]] || { rm -f "$progress_file" "$initial_dashboard"; fail "progress self-test did not finish all six tasks with a full bar"; }
LC_ALL=C grep -Fq $'\033[6A' "$progress_file" || { rm -f "$progress_file" "$initial_dashboard"; fail "progress self-test did not update the first dashboard row in place"; }
LC_ALL=C grep -Fq $'\033[1A' "$progress_file" || { rm -f "$progress_file" "$initial_dashboard"; fail "progress self-test did not update the final dashboard row in place"; }
rm -f "$progress_file" "$initial_dashboard"
echo "build fixed-dashboard progress runtime self-test: PASS"

# local-signing transport compatibility and quiet dependency checkout.
grep -q 'P12_PASSWORD="$(openssl rand -hex 24)"' "$SCRIPT_DIR/setup_signing.sh" || fail "random non-empty PKCS12 password missing"
grep -q -- '-keypbe PBE-SHA1-3DES' "$SCRIPT_DIR/setup_signing.sh" || fail "PKCS12 key compatibility algorithm missing"
grep -q -- '-certpbe PBE-SHA1-3DES' "$SCRIPT_DIR/setup_signing.sh" || fail "PKCS12 certificate compatibility algorithm missing"
grep -q -- '-macalg sha1' "$SCRIPT_DIR/setup_signing.sh" || fail "PKCS12 MAC compatibility algorithm missing"
grep -q -- '-P "$P12_PASSWORD"' "$SCRIPT_DIR/setup_signing.sh" || fail "Keychain import does not use generated PKCS12 password"
grep -q 'advice.detachedHead=false' "$SCRIPT_DIR/build.sh" || fail "detached-HEAD advice suppression missing"
grep -Fq 'basicConstraints = critical,CA:TRUE,pathlen:0' "$SCRIPT_DIR/setup_signing.sh" || fail "local signing certificate is not generated as a Self Signed Root"
grep -Fq -- '-r trustRoot' "$SCRIPT_DIR/setup_signing.sh" || fail "self-signed root is not trusted with trustRoot"
grep -Fq -- '-p codeSign' "$SCRIPT_DIR/setup_signing.sh" || fail "local trust is not scoped to Code Signing"
! grep -Fq -- '-r trustAsRoot' "$SCRIPT_DIR/setup_signing.sh" || fail "invalid trustAsRoot fallback remains"
grep -Fq 'Found incomplete remotely signing identity; repairing Code Signing trust...' "$SCRIPT_DIR/setup_signing.sh" || fail "failed-setup signing identity repair path missing"
echo "signing transport / root-trust / quiet checkout invariants: PASS"

# configurable presentation + exclusive MiniRemote invariants.
grep -q 'static let allowPanelDragging = "allowPanelDragging"' Sources/remotely/AppModel.swift || fail "main-panel drag preference key missing"
grep -q 'panel.isMovableByWindowBackground = false' Sources/remotely/AppController.swift || fail "background window dragging must remain disabled"
grep -q 'preferenceToggle("Allow window dragging from top edge"' Sources/remotely/PreferencesView.swift || fail "top-edge window drag toggle missing"
grep -q 'SMAppService.mainApp' Sources/remotely/AppModel.swift || fail "launch-at-login main app service missing"
grep -q 'try service.register()' Sources/remotely/AppModel.swift || fail "launch-at-login register path missing"
grep -q 'try service.unregister()' Sources/remotely/AppModel.swift || fail "launch-at-login unregister path missing"
grep -q '"Launch remotely at login"' Sources/remotely/PreferencesView.swift || fail "launch-at-login toggle missing"
grep -q 'preferenceToggle("Show Now Playing"' Sources/remotely/PreferencesView.swift || fail "Now Playing visibility toggle missing"
grep -q 'if showNowPlaying {' Sources/remotely/RemoteView.swift || fail "Now Playing block is not conditionally rendered"
grep -q 'remoteWithoutNowPlayingHeight' Sources/remotely/AppConstants.swift || fail "compact Remote height missing"
[[ -f Sources/remotely/MiniRemoteView.swift ]] || fail "MiniRemoteView missing"
grep -q 'MiniRemoteView(' Sources/remotely/PanelRootView.swift || fail "MiniRemote is not integrated as the primary Remote face"
grep -q 'preferenceToggle("Use MiniRemote"' Sources/remotely/PreferencesView.swift || fail "MiniRemote mode Preferences toggle missing"
grep -q 'title: "MiniRemote"' Sources/remotely/AppController.swift || fail "MiniRemote menu item missing"
grep -q 'keyEquivalent: "m"' Sources/remotely/AppController.swift || fail "MiniRemote Command-M shortcut missing"
grep -q 'model.useMiniRemote.toggle()' Sources/remotely/AppController.swift || fail "MiniRemote menu shortcut does not toggle presentation mode"
grep -q 'presentingMiniRemote' Sources/remotely/AppController.swift || fail "exclusive MiniRemote presentation state missing"
grep -q 'model.useMiniRemote && !remoteService.keyboardInputRequested' Sources/remotely/AppController.swift || fail "MiniRemote keyboard-search fallback missing"
grep -q 'model.useMiniRemote && !remote.keyboardInputRequested' Sources/remotely/PanelRootView.swift || fail "MiniRemote SwiftUI keyboard-search fallback missing"
grep -q 'remoteVisible && !presentingMiniRemote && model.showNowPlaying' Sources/remotely/AppController.swift || fail "full Remote presentation is not exclusive of MiniRemote"
grep -q 'remoteVisible && presentingMiniRemote' Sources/remotely/AppController.swift || fail "MiniRemote presentation gate missing"
! grep -q 'private var miniPanel:' Sources/remotely/AppController.swift || fail "obsolete second MiniRemote panel remains"
! grep -q 'buildMiniPanel()' Sources/remotely/AppController.swift || fail "obsolete MiniRemote panel builder remains"
! grep -q 'showMiniRemote()' Sources/remotely/AppController.swift || fail "obsolete independent MiniRemote show path remains"
! grep -q 'hideMiniRemote()' Sources/remotely/AppController.swift || fail "obsolete independent MiniRemote hide path remains"
grep -q 'setMiniRemotePresentation(isVisible:' Sources/remotely/AppleTVService.swift || fail "MiniRemote timeline presentation gate missing"
grep -q '(remotePresented || miniRemotePresented)' Sources/remotely/AppleTVService.swift || fail "timeline timer does not include MiniRemote presentation"
grep -q 'static let alwaysOnTop = "alwaysOnTop"' Sources/remotely/AppModel.swift || fail "Always-on-top preference key missing"
grep -q '@Published var alwaysOnTop: Bool' Sources/remotely/AppModel.swift || fail "Always-on-top persisted state missing"
grep -q 'preferenceToggle("Always on top", isOn: \$model.alwaysOnTop)' Sources/remotely/PreferencesView.swift || fail "Always-on-top Preferences toggle missing"
grep -q 'title: "Always on top"' Sources/remotely/AppController.swift || fail "Always-on-top context menu item missing"
grep -q 'keyEquivalent: "t"' Sources/remotely/AppController.swift || fail "Always-on-top Command-T shortcut missing"
grep -q 'model.alwaysOnTop.toggle()' Sources/remotely/AppController.swift || fail "Always-on-top menu item does not toggle persisted state"
grep -q 'panel.hidesOnDeactivate = !enabled' Sources/remotely/AppController.swift || fail "Always-on-top mode does not disable deactivate hiding"
grep -q 'guard panel != nil, !model.alwaysOnTop else { return }' Sources/remotely/AppController.swift || fail "Always-on-top mode does not survive app deactivation"
grep -q 'if model.alwaysOnTop {' Sources/remotely/AppController.swift || fail "status-item persistent-mode behavior missing"
grep -q 'if enabled && !self.panelPresented' Sources/remotely/AppController.swift || fail "enabling Always on top does not surface a hidden Remote"
grep -q 'speaker.wave.1.fill' Sources/remotely/MiniRemoteView.swift || fail "MiniRemote volume-down control missing"
grep -q 'gobackward.10' Sources/remotely/MiniRemoteView.swift || fail "MiniRemote rewind control missing"
grep -q 'goforward.10' Sources/remotely/MiniRemoteView.swift || fail "MiniRemote forward control missing"
grep -q 'play.fill' Sources/remotely/MiniRemoteView.swift || fail "MiniRemote play/pause control missing"
grep -q '<string>1.2.12</string>' Resources/Info.plist || fail "v1.2.12 bundle version missing"
echo "configurable presentation / login item / exclusive MiniRemote invariants: PASS"
# MiniRemote layout: timeline labels must not clip and controls remain
# vertically separated from the timeline.
grep -q 'static let miniRemoteHeight: CGFloat = 190' Sources/remotely/AppConstants.swift || fail "MiniRemote height missing"
grep -q 'frame(minWidth: 46, alignment: .leading)' Sources/remotely/NowPlayingShared.swift || fail "shared elapsed-time width missing"
grep -q 'frame(minWidth: 52, alignment: .trailing)' Sources/remotely/NowPlayingShared.swift || fail "shared remaining-time width missing"
grep -q 'Spacer().frame(height: 11)' Sources/remotely/MiniRemoteView.swift || fail "MiniRemote timeline/control spacing missing"
echo "MiniRemote layout invariants: PASS"

# timeline parity + card-flip midpoint stability.
! sed -n '/struct NowPlayingTimeline:/,/^}/p' Sources/remotely/NowPlayingShared.swift | grep -q 'Circle()' || fail "shared timeline playhead returned"
grep -q 'DispatchQueue.main.asyncAfter(deadline: .now() + 0.36)' Sources/remotely/AppController.swift || fail "post-flip panel geometry delay missing"
! grep -q 'DispatchQueue.main.asyncAfter(deadline: .now() + 0.18)' Sources/remotely/AppController.swift || fail "midpoint panel geometry mutation remains"
! sed -n '/\.onAppear {/,/        }/p' Sources/remotely/PreferencesView.swift | grep -q 'service.scan()' || fail "Preferences still restarts discovery during flip"
! sed -n '/\.onAppear {/,/        }/p' Sources/remotely/PreferencesView.swift | grep -q 'model.refreshLaunchAtLoginStatus()' || fail "Preferences still republishes login-item state during flip"
echo "timeline / card-flip midpoint invariants: PASS"

# prewarmed two-slot card flip.
grep -q '@State private var secondaryMode: PanelMode?' Sources/remotely/PanelRootView.swift || fail "secondary prewarm face slot missing"
grep -q 'let prewarmDelay = 0.04' Sources/remotely/PanelRootView.swift || fail "destination face prewarm delay missing"
grep -q 'secondaryMode = newMode' Sources/remotely/PanelRootView.swift || fail "destination face is not staged before flip"
grep -q 'showingSecondary.toggle()' Sources/remotely/PanelRootView.swift || fail "midpoint face-slot swap missing"
grep -q 'midpointTransaction.disablesAnimations = true' Sources/remotely/PanelRootView.swift || fail "midpoint swap may animate implicitly"
grep -q '\.opacity(visible ? 1 : 0.001)' Sources/remotely/PanelRootView.swift || fail "hidden prewarm face is not renderable"
grep -q '\.compositingGroup()' Sources/remotely/PanelRootView.swift || fail "face compositing isolation missing"
echo "prewarmed two-slot flip invariants: PASS"

# Preferences layout + hidden Remote input isolation.
grep -q 'private func preferenceToggle' Sources/remotely/PreferencesView.swift || fail "shared trailing-aligned Preferences toggle row missing"
grep -q 'VStack(spacing: 0)' Sources/remotely/PreferencesView.swift || fail "Preferences outer footer layout missing"
grep -q 'let clickpadInputEnabled: Bool' Sources/remotely/RemoteView.swift || fail "Remote clickpad activity gate missing"
grep -q 'isEnabled: clickpadInputEnabled' Sources/remotely/RemoteView.swift || fail "clickpad swipe capture is not gated by active face"
grep -q 'setCaptureEnabled' Sources/remotely/ClickpadSwipeCapture.swift || fail "AppKit swipe monitor enable/disable lifecycle missing"
grep -q 'let interactive = visible && !isFlipping' Sources/remotely/PanelRootView.swift || fail "card-face interaction state is not propagated"
echo "Preferences / hidden-input isolation invariants: PASS"


# Now Playing drag isolation + overflow metadata behavior.
[[ -f Sources/remotely/OverflowMarqueeText.swift ]] || fail "overflow marquee component missing"
grep -q 'measuredTextWidth - geometry.size.width' Sources/remotely/OverflowMarqueeText.swift || fail "marquee overflow measurement missing"
grep -q 'Task.sleep(for: .milliseconds(900))' Sources/remotely/OverflowMarqueeText.swift || fail "marquee endpoint pause missing"
grep -q 'OverflowMarqueeText(' Sources/remotely/NowPlayingShared.swift || fail "shared episode-title marquee missing"
grep -q 'NowPlayingMetadata(state: state)' Sources/remotely/RemoteView.swift || fail "full Remote shared metadata integration missing"
grep -q 'NowPlayingMetadata(state: state)' Sources/remotely/MiniRemoteView.swift || fail "MiniRemote shared metadata integration missing"
grep -q 'NowPlayingTimeline(' Sources/remotely/RemoteView.swift || fail "full Remote shared timeline integration missing"
grep -q 'NowPlayingTimeline(' Sources/remotely/MiniRemoteView.swift || fail "MiniRemote shared timeline integration missing"
grep -q 'onSeek: service.seek(to:)' Sources/remotely/MiniRemoteView.swift || fail "MiniRemote timeline seek integration missing"
grep -q 'DragGesture(minimumDistance: 0, coordinateSpace: .local)' Sources/remotely/NowPlayingShared.swift || fail "shared timeline drag gesture missing"
! sed -n '/struct NowPlayingTimeline:/,/^}/p' Sources/remotely/NowPlayingShared.swift | grep -q 'Circle()' || fail "shared timeline playhead returned"
echo "Now Playing drag isolation / marquee invariants: PASS"


# MiniRemote metadata parity.
grep -q 'if let seasonEpisode = state?.seasonEpisode' Sources/remotely/NowPlayingShared.swift || fail "shared season/episode line missing"
grep -q 'if let episodeTitle = state?.episodeTitle' Sources/remotely/NowPlayingShared.swift || fail "shared episode-title line missing"
grep -q 'text: episodeTitle' Sources/remotely/NowPlayingShared.swift || fail "shared episode-title marquee is not bound directly to episode title"
! grep -q 'private var detailText' Sources/remotely/MiniRemoteView.swift || fail "MiniRemote still combines season/episode and episode title"
! grep -q 'joined(separator: " · ")' Sources/remotely/MiniRemoteView.swift || fail "MiniRemote metadata fields are still flattened"
grep -q '.frame(height: 56, alignment: .topLeading)' Sources/remotely/MiniRemoteView.swift || fail "MiniRemote three-line metadata region missing"
grep -q '.frame(height: 56, alignment: .topLeading)' Sources/remotely/RemoteView.swift || fail "full Remote three-line metadata region missing"
echo "MiniRemote metadata parity invariants: PASS"

# Now Playing metadata breathing room.
grep -q 'VStack(alignment: .leading, spacing: 4)' Sources/remotely/NowPlayingShared.swift || fail "shared metadata spacing missing"
grep -q '.frame(height: 56, alignment: .topLeading)' Sources/remotely/MiniRemoteView.swift || fail "MiniRemote metadata region height missing"
grep -q '.frame(height: 56, alignment: .topLeading)' Sources/remotely/RemoteView.swift || fail "full Remote metadata region height missing"
grep -q 'Spacer().frame(height: 11)' Sources/remotely/MiniRemoteView.swift || fail "MiniRemote timeline/control rebalance missing"
echo "Now Playing metadata spacing invariants: PASS"

# top-edge-only dragging + shared Now Playing geometry.
[[ -f Sources/remotely/WindowDragHandle.swift ]] || fail "top-edge drag handle component missing"
grep -q 'window.performDrag(with: event)' Sources/remotely/WindowDragHandle.swift || fail "top-edge drag handle does not initiate AppKit window drag"
grep -q 'windowDragHandleHeight: CGFloat = 12' Sources/remotely/AppConstants.swift || fail "top-edge drag strip height missing"
grep -q 'WindowDragHandle(isEnabled: !isFlipping)' Sources/remotely/PanelRootView.swift || fail "top-edge drag strip is not integrated across card faces"
grep -q 'panel.isMovableByWindowBackground = false' Sources/remotely/AppController.swift || fail "window background can still drag panel"
! grep -Rqs 'onWindowDragExclusionChanged' Sources/remotely || fail "obsolete hover-based window drag exclusions remain"
! grep -q 'panelDragExcluded' Sources/remotely/AppController.swift || fail "obsolete panel drag exclusion state remains"
grep -q 'static let panelWidth: CGFloat = 360' Sources/remotely/AppConstants.swift || fail "full panel was not widened to MiniRemote width"
grep -q 'static let panelContentWidth: CGFloat = panelWidth - 24' Sources/remotely/AppConstants.swift || fail "widened full-Remote content width missing"
grep -q '.frame(width: AppConstants.panelContentWidth, height: 190)' Sources/remotely/RemoteView.swift || fail "full Remote Now Playing does not use MiniRemote-height geometry"
grep -q '.frame(width: 82, height: 166)' Sources/remotely/RemoteView.swift || fail "full Remote Now Playing artwork does not match MiniRemote geometry"
grep -q 'frame(minWidth: 52, alignment: .trailing)' Sources/remotely/NowPlayingShared.swift || fail "hour-long remaining-time field can regress to wrapping"
grep -q '.fixedSize(horizontal: true, vertical: false)' Sources/remotely/NowPlayingShared.swift || fail "timeline time labels are not forced to one line"
grep -q '<string>1.2.12</string>' Resources/Info.plist || fail "v1.2.12 bundle version missing"
echo "top-edge dragging / shared Now Playing invariants: PASS"
