import Foundation
import CoreGraphics
import Observation
import Security
import ItsytvCore

struct RemoteDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
}

struct RemoteApp: Identifiable, Hashable {
    let bundleID: String
    let name: String

    var id: String { bundleID }
}

/// App-owned snapshot of the Apple TV MRP now-playing state. Keeping this type
/// local prevents SwiftUI from depending directly on the protocol package.
struct RemoteNowPlaying: Equatable {
    let artworkData: Data?
    let duration: TimeInterval
    let position: TimeInterval
    let isPlaying: Bool
    let title: String?
    let seasonEpisode: String?
    let episodeTitle: String?
}

/// The only application file that knows about the underlying Apple TV protocol
/// package. UI code talks exclusively to this service so the transport can be
/// replaced later without rewriting the app shell or remote UI.
@MainActor
final class AppleTVService: ObservableObject {
    @Published private(set) var devices: [RemoteDevice] = []
    @Published private(set) var configuredDevices: [RemoteDevice] = []
    /// Device highlighted in Preferences. This is a staging selection only;
    /// choosing a device here must not imply that the active protocol session
    /// has switched until Connect/Pair is explicitly requested.
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var selectedDeviceName: String

    /// Device identity reported by the protocol manager for the current live
    /// session. Remote UI uses these values instead of the Preferences staging
    /// selection so its label can never disagree with the device being controlled.
    @Published private(set) var connectedDeviceID: String?
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var statusText = "Ready"
    @Published private(set) var isPairing = false
    @Published private(set) var isConnected = false
    @Published private(set) var nowPlaying: RemoteNowPlaying?
    @Published private(set) var apps: [RemoteApp] = []
    @Published private(set) var keyboardInputRequested = false

    /// Notifies the AppKit shell when the Remote needs extra vertical space
    /// for tvOS keyboard input. The protocol focus state remains owned here.
    var onKeyboardInputVisibilityChanged: ((Bool) -> Void)?

    private let manager = AppleTVManager()
    private var deviceMap: [String: AppleTVDevice] = [:]
    private var timelineTimer: Timer?
    private var nowPlayingVerificationTimer: Timer?
    private var remotePresented = false
    private var miniRemotePresented = false
    private var isShuttingDown = false
    private var startupReconnectDeviceID: String?
    private let defaults = UserDefaults.standard

    private enum KeychainService {
        static let current = "com.local.remotely.credentials"
    }

    private enum DefaultsKey {
        static let selectedID = "selectedAppleTVIdentifier"
        static let selectedName = "selectedAppleTVName"
    }

    init() {
        let persistedSelectedDeviceID = defaults.string(forKey: DefaultsKey.selectedID)
        selectedDeviceID = persistedSelectedDeviceID
        selectedDeviceName = defaults.string(forKey: DefaultsKey.selectedName) ?? "Choose Apple TV"
        connectedDeviceID = nil
        connectedDeviceName = nil
        startupReconnectDeviceID = persistedSelectedDeviceID

        manager.startScanning()

        // Reconnect the exact device this app last confirmed as connected. The
        // Bonjour snapshot may not exist yet at init time, so refreshManagerSnapshot
        // consumes this one-shot target as soon as that device is discovered.

        // The protocol core is Observation-based. Track its actual state
        // changes instead of rebuilding every app snapshot five times per
        // second while remotely is idle. Each observation is one-shot and is
        // re-armed before the corresponding snapshot is refreshed.
        observeManagerState()
        observeMRPState()
        refreshManagerSnapshot()
        refreshMRPSnapshot()
    }


    var hasConfiguredDevice: Bool {
        selectedDeviceID != nil || connectedDeviceID != nil || !configuredDevices.isEmpty
    }

    /// Preferences actions are scoped to the device highlighted in Preferences,
    /// not whichever Apple TV happens to own the live Remote session.
    var selectedDeviceIsPaired: Bool {
        guard let selectedDeviceID else { return false }
        return configuredDevices.contains { $0.id == selectedDeviceID }
    }

    var selectedDeviceIsConnected: Bool {
        guard let selectedDeviceID else { return false }
        return isConnected && connectedDeviceID == selectedDeviceID
    }

    var canConnectSelectedDevice: Bool {
        selectedDeviceID != nil && selectedDeviceIsPaired && !selectedDeviceIsConnected && !isPairing
    }

    var canPairSelectedDevice: Bool {
        selectedDeviceID != nil && !selectedDeviceIsPaired && !isPairing
    }

    var canRemoveSelectedPairing: Bool {
        selectedDeviceID != nil && selectedDeviceIsPaired && !isPairing
    }

    var selectedDeviceStatusText: String {
        if statusText == "Scanning…" {
            return statusText
        }
        guard selectedDeviceID != nil else {
            return "Select an Apple TV."
        }
        if isPairing {
            return "Pairing…"
        }
        if statusText.hasPrefix("Connecting to ") {
            return "Connecting…"
        }
        if selectedDeviceIsConnected {
            return "Connected"
        }
        return selectedDeviceIsPaired ? "Disconnected" : "Not Paired"
    }

    /// Identity presented by the Remote card. Prefer the protocol-confirmed
    /// connected device; during a connection transition fall back to the target
    /// selected by the user.
    var remoteDeviceID: String? {
        connectedDeviceID ?? selectedDeviceID
    }

    var remoteDeviceName: String {
        if let connectedDeviceName, !connectedDeviceName.isEmpty {
            return connectedDeviceName
        }
        return selectedDeviceName
    }

    func scan() {
        // DeviceDiscovery is a continuous Bonjour browser. Its core
        // `isScanning` flag means that discovery is running, not that this
        // manual refresh is still pending. Show a brief acknowledgement for
        // the user-requested refresh, then fall back to the real connection
        // state even when Bonjour returns the same device list and therefore
        // produces no observable state change.
        statusText = "Scanning…"
        manager.refreshScanning()
        scheduleScanStatusReset()
    }


    /// A manual Preferences refresh restarts the already-running Bonjour
    /// browser but has no completion state in the protocol core. If discovery
    /// returns an identical device set there may be no Observation callback at
    /// all, so never leave the UI status parked on "Scanning…" waiting for an
    /// event that is not guaranteed to occur.
    private func scheduleScanStatusReset() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, !self.isShuttingDown, self.statusText == "Scanning…" else { return }
            let rawStatus = String(describing: self.manager.connectionStatus)
            self.statusText = Self.displayStatus(rawStatus)
        }
    }

    func chooseDevice(_ id: String?) {
        selectedDeviceID = id
        guard let id, let device = deviceMap[id] else {
            selectedDeviceName = "Choose Apple TV"
            return
        }
        selectedDeviceName = device.name
    }

    func connectSelected() {
        guard let device = selectedCoreDevice else {
            statusText = "Select an Apple TV first."
            return
        }
        guard selectedDeviceIsPaired else {
            statusText = "Pair \(device.name) before connecting."
            return
        }
        guard !selectedDeviceIsConnected else { return }
        selectedDeviceName = device.name
        statusText = "Connecting to \(device.name)…"
        startupReconnectDeviceID = nil
        manager.connect(to: device)
    }


    /// Select an Apple TV from the Remote card and immediately make it the
    /// active connection. AppleTVManager.connect(to:) begins by tearing down
    /// any existing Companion/MRP session, so switching devices is atomic from
    /// remotely's point of view and never leaves two active sessions behind.
    func selectAndConnectDevice(_ id: String) {
        guard let device = deviceMap[id] else {
            statusText = "Apple TV is not currently available."
            return
        }

        let alreadyConnected = isConnected && manager.connectedDeviceID == id

        if selectedDeviceID != id {
            selectedDeviceID = id
        }
        if selectedDeviceName != device.name {
            selectedDeviceName = device.name
        }

        guard !alreadyConnected else { return }

        statusText = "Connecting to \(device.name)…"
        startupReconnectDeviceID = nil
        manager.connect(to: device)
    }

    /// Pairing is initiated automatically by AppleTVManager when the selected
    /// Apple TV has no stored credentials. Keeping a separate Pair button
    /// preserves the current UI while making the flow explicit to the user.
    func pairSelected() {
        guard let device = selectedCoreDevice else {
            statusText = "Select an Apple TV first."
            return
        }
        guard !selectedDeviceIsPaired else { return }
        selectedDeviceName = device.name
        statusText = "Starting pairing with \(device.name)…"
        startupReconnectDeviceID = nil
        manager.connect(to: device)
    }

    func submitPIN(_ pin: String) {
        let digits = pin.filter(\.isNumber)
        guard !digits.isEmpty else {
            statusText = "Enter the PIN shown on the Apple TV."
            return
        }
        manager.submitPIN(digits)
    }

    /// Remove pairing data only for the Apple TV currently selected in
    /// Preferences. Credentials are stored as one generic-password Keychain
    /// item per device ID, so deleting one account must never affect another
    /// paired Apple TV.
    func removeSelectedPairedDevice() {
        guard let deviceID = selectedDeviceID,
              let device = deviceMap[deviceID] else {
            statusText = "Select an Apple TV first."
            return
        }
        guard selectedDeviceIsPaired else { return }

        let removingActiveConnection = connectedDeviceID == deviceID
        if removingActiveConnection {
            manager.disconnect()
        }

        let keychainStatus = Self.deleteKeychainItem(
            service: KeychainService.current,
            account: deviceID
        )
        guard keychainStatus == errSecSuccess || keychainStatus == errSecItemNotFound else {
            statusText = "Could not remove pairing data for \(device.name) (error \(keychainStatus))."
            return
        }

        // Our persisted selection represents the last successfully connected
        // device. Clear it only when it points at the device being forgotten;
        // unrelated app preferences and other paired-device credentials remain.
        if defaults.string(forKey: DefaultsKey.selectedID) == deviceID {
            defaults.removeObject(forKey: DefaultsKey.selectedID)
            defaults.removeObject(forKey: DefaultsKey.selectedName)
        }

        if removingActiveConnection {
            connectedDeviceID = nil
            connectedDeviceName = nil
            isConnected = false
            isPairing = false
            setKeyboardInputRequested(false)
        }

        refreshManagerSnapshot()
        statusText = "Pairing data removed for \(device.name)."
    }

    @discardableResult
    private static func deleteKeychainItem(service: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary)
    }


    private static func configuredDeviceIDs(service: String) -> Set<String> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }
        return Set(items.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    // MARK: - Apps

    func refreshApps() {
        guard isConnected else {
            if !apps.isEmpty { apps = [] }
            return
        }
        manager.fetchApps()
    }

    func launchApp(_ app: RemoteApp) {
        guard isConnected else { return }
        manager.launchApp(bundleID: app.bundleID)
    }

    // MARK: - Remote commands

    func mute() {
        manager.toggleMute()
    }

    func volumeDown() {
        manager.pressButton(.volumeDown)
    }

    func volumeUp() {
        manager.pressButton(.volumeUp)
    }

    func up() {
        manager.pressButton(.up)
    }

    func down() {
        manager.pressButton(.down)
    }

    func left() {
        manager.pressButton(.left)
    }

    func right() {
        manager.pressButton(.right)
    }

    func select() {
        manager.pressButton(.select)
    }

    // MARK: - Keyboard input

    /// Mirror the local text field into the active tvOS Companion RTI session.
    /// The protocol core sends only the required delta/replace operation, so
    /// every edit can be forwarded as it occurs without a separate submit step.
    func updateKeyboardText(_ text: String) {
        guard isConnected, keyboardInputRequested else { return }
        manager.updateRemoteText(text)
    }

    // MARK: - Clickpad touch streaming

    /// Begin a continuous Apple TV touch gesture. The reference size is larger
    /// than the visible clickpad, matching the motion profile used by the native
    /// protocol core and keeping trackpad travel comfortable on macOS.
    func touchBegan(referenceSize: CGSize) {
        guard isConnected else { return }
        manager.touchBegan(referenceSize: referenceSize)
    }

    /// Stream cumulative trackpad translation while the gesture is active.
    func touchMoved(translation: CGPoint) {
        guard isConnected else { return }
        manager.touchMoved(translation: translation)
    }

    /// Finish the gesture with release velocity so the protocol core can apply
    /// the same inertial continuation used by its native touch implementation.
    func touchEnded(translation: CGPoint, velocity: CGPoint) {
        guard isConnected else { return }
        manager.touchEnded(translation: translation, velocity: velocity)
    }

    func back() {
        manager.pressButton(.menu)
    }

    func home() {
        manager.pressButton(.home)
    }

    func homeHold() {
        manager.pressButton(.home, action: .hold)
    }

    func playPause() {
        manager.pressButton(.playPause)
        scheduleNowPlayingRefresh(after: 0.30)
    }

    func playPauseHold() {
        manager.pressButton(.playPause, action: .hold)
    }

    /// Basic transport commands are a remotely capability, not an app-advertised
    /// UI capability. Some tvOS clients omit or fail to republish SupportedCommands
    /// even though the standard MRP commands work. Always send the command when
    /// invoked and let the active receiver handle or ignore it.
    func previousTrack() {
        manager.mrpManager.sendCommand(.previousTrack)
        scheduleNowPlayingRefresh(after: 0.45)
    }

    func nextTrack() {
        manager.mrpManager.sendCommand(.nextTrack)
        scheduleNowPlayingRefresh(after: 0.45)
    }

    func rewind10() {
        manager.mrpManager.sendSkip(.skipBackward, interval: 10)
        scheduleNowPlayingRefresh(after: 0.30)
    }

    func forward10() {
        manager.mrpManager.sendSkip(.skipForward, interval: 10)
        scheduleNowPlayingRefresh(after: 0.30)
    }

    /// Enable or disable the protocol core's opt-in opening-content seek.
    /// The core remains responsible for extracting Apple's AVKit boundary and
    /// enforcing the one-shot/new-playback safety gates.
    func setAutoSkipOpeningContentEnabled(_ enabled: Bool) {
        manager.mrpManager.autoSkipOpeningContentEnabled = enabled
    }

    func seek(to position: TimeInterval) {
        guard position.isFinite else { return }
        manager.mrpManager.seekToPosition(max(0, position))
        scheduleNowPlayingRefresh(after: 0.30)
    }

    /// Re-request the current playback queue once when Remote is presented.
    /// This is a snapshot refresh, not a duration-recovery loop: some tvOS apps
    /// legitimately publish playable content before duration/elapsed metadata.
    func refreshNowPlaying() {
        requestNowPlayingRefresh()
    }

    private func requestNowPlayingRefresh() {
        manager.mrpManager.refreshNowPlaying()
    }

    private func scheduleNowPlayingRefresh(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.requestNowPlayingRefresh()
        }
    }

    /// Mirrors the validated v0.9.4 behavior:
    /// - connected/awake: short press opens Control Center via held Home
    /// - unavailable/asleep: short press sends Wake
    func powerPress() {
        if isConnected {
            manager.pressButton(.home, action: .hold)
        } else {
            manager.pressButton(.wake)
        }
    }

    /// Long power press sleeps the Apple TV. If it is currently unreachable,
    /// treat the same action as Wake instead of queuing a sleep for later.
    func powerHold() {
        if isConnected {
            manager.pressButton(.sleep)
        } else {
            manager.pressButton(.wake)
        }
    }

    /// Tell the service whether a Now Playing surface is actually on screen.
    /// Normal MRP pushes remain the source of active metadata. A separate
    /// foreground verifier only checks whether a previously displayed session
    /// has become definitively inactive without publishing its teardown event.
    func setRemotePresentation(isVisible: Bool) {
        guard remotePresented != isVisible else { return }
        remotePresented = isVisible
        updateTimelineTimer()
        updateNowPlayingVerificationTimer()
    }

    func setMiniRemotePresentation(isVisible: Bool) {
        guard miniRemotePresented != isVisible else { return }
        miniRemotePresented = isVisible
        updateTimelineTimer()
        updateNowPlayingVerificationTimer()
    }

    func shutdown() {
        isShuttingDown = true
        remotePresented = false
        miniRemotePresented = false
        stopTimelineTimer()
        stopNowPlayingVerificationTimer()
        manager.stopScanning()
        manager.disconnect()
    }

    // MARK: - State bridge

    private var selectedCoreDevice: AppleTVDevice? {
        guard let selectedDeviceID else { return nil }
        return deviceMap[selectedDeviceID]
    }

    /// Observe app/session/discovery state exposed by the protocol manager.
    /// `withObservationTracking` notifications are one-shot, so re-arm first
    /// when a change arrives; the following refresh then reads the latest state.
    private func observeManagerState() {
        guard !isShuttingDown else { return }

        withObservationTracking {
            _ = manager.discoveredDevices
            _ = manager.connectedDeviceName
            _ = manager.connectedDeviceID
            _ = manager.connectionStatus
            _ = manager.keyboardFocused
            _ = manager.installedApps
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isShuttingDown else { return }
                self.observeManagerState()
                self.refreshManagerSnapshot()
            }
        }
    }

    /// MRP changes independently from the Companion manager. Observe only the
    /// state remotely renders so playback pushes do not also rebuild discovery
    /// and Apps snapshots.
    private func observeMRPState() {
        guard !isShuttingDown else { return }

        withObservationTracking {
            _ = manager.mrpManager.nowPlaying
            _ = manager.mrpManager.nowPlayingSeriesName
            _ = manager.mrpManager.nowPlayingSeasonNumber
            _ = manager.mrpManager.nowPlayingEpisodeNumber
            _ = manager.mrpManager.nowPlayingEpisodeTitle
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isShuttingDown else { return }
                self.observeMRPState()
                self.refreshMRPSnapshot()
            }
        }
    }

    private func refreshManagerSnapshot() {
        var map: [String: AppleTVDevice] = [:]
        let summaries = manager.discoveredDevices.map { device -> RemoteDevice in
            map[device.id] = device
            return RemoteDevice(id: device.id, name: device.name, host: device.host)
        }
        .sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.host < $1.host : order == .orderedAscending
        }

        deviceMap = map
        if devices != summaries {
            devices = summaries
        }

        if let startupReconnectDeviceID,
           let device = map[startupReconnectDeviceID] {
            self.startupReconnectDeviceID = nil
            statusText = "Connecting to \(device.name)…"
            manager.connect(to: device)
        }

        // Remote-card switching is intentionally limited to Apple TVs that
        // already have remotely-owned pairing credentials. Preferences still
        // shows every discovered device so new Apple TVs can be paired there.
        let configuredIDs = Self.configuredDeviceIDs(service: KeychainService.current)
        let configured = summaries.filter { configuredIDs.contains($0.id) }
        if configuredDevices != configured {
            configuredDevices = configured
        }

        let rawStatus = String(describing: manager.connectionStatus)
        let lower = rawStatus.lowercased()
        let pairingNow = lower.hasPrefix("pairing")
        let connectedNow = lower.hasPrefix("connected")

        // Keep Preferences selection and active Remote identity independent.
        // A click in Preferences only stages a target. The Remote identity moves
        // only after the protocol manager confirms an actual connected device.
        let coreConnectedID = connectedNow ? manager.connectedDeviceID : nil
        let coreConnectedName = connectedNow ? manager.connectedDeviceName : nil
        if connectedDeviceID != coreConnectedID {
            connectedDeviceID = coreConnectedID
        }
        if connectedDeviceName != coreConnectedName {
            connectedDeviceName = coreConnectedName
        }

        if let coreConnectedID,
           let coreConnectedName,
           !coreConnectedName.isEmpty {
            persistConnectedDevice(id: coreConnectedID, name: coreConnectedName)
        } else if selectedDeviceName == "Choose Apple TV",
                  let selectedDeviceID,
                  let device = map[selectedDeviceID] {
            // Preserve the persisted last-connected label before the first live
            // connection is established, without treating discovery as a connect.
            selectedDeviceName = device.name
        }
        if isPairing != pairingNow {
            isPairing = pairingNow
        }
        if isConnected != connectedNow {
            isConnected = connectedNow
        }
        let displayStatus = Self.displayStatus(rawStatus)
        if statusText != displayStatus {
            statusText = displayStatus
        }

        // Companion text-input focus is the source of truth for Keyboard
        // Search. Do not infer this from the active app or Remote UI state.
        let coreKeyboardFocusedNow = connectedNow && manager.keyboardFocused
        setKeyboardInputRequested(coreKeyboardFocusedNow)

        refreshAppsSnapshot()
        updateTimelineTimer()
        updateNowPlayingVerificationTimer()

    }

    private func refreshMRPSnapshot() {
        // MRP already requests the initial playback queue as part of session
        // initialization. A missing duration is valid protocol state, so there
        // is no duration-driven retry loop.
        refreshNowPlayingSnapshot()
        updateTimelineTimer()
    }

    private func setKeyboardInputRequested(_ requested: Bool) {
        guard keyboardInputRequested != requested else { return }
        keyboardInputRequested = requested
        onKeyboardInputVisibilityChanged?(requested)
    }

    private func refreshAppsSnapshot() {
        let snapshot = manager.installedApps
            .map { RemoteApp(bundleID: $0.bundleID, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if apps != snapshot {
            apps = snapshot
        }
    }

    private func refreshNowPlayingSnapshot() {
        guard let state = manager.mrpManager.nowPlaying else {
            if nowPlaying != nil { nowPlaying = nil }
            return
        }

        let rawTitle = Self.reflectedString(
            in: state,
            preferredLabels: ["title", "displayTitle", "name"]
        )
        // Standard MRP `artist` is also the natural creator/channel line for
        // non-TV video sources such as YouTube. Keep this source-agnostic: the
        // renderer consumes one normalized secondary line instead of knowing
        // which app published it.
        let secondary = Self.reflectedString(
            in: state,
            preferredLabels: [
                "artist", "trackArtistName", "subtitle", "secondaryTitle",
                "channelName", "creatorName"
            ]
        )
        let album = Self.reflectedString(
            in: state,
            preferredLabels: ["album", "albumName", "seriesName", "showName"]
        )
        let metadata = Self.parseMediaMetadata(
            rawTitle: rawTitle,
            secondary: secondary,
            album: album,
            explicitSeriesName: manager.mrpManager.nowPlayingSeriesName,
            seasonNumber: manager.mrpManager.nowPlayingSeasonNumber,
            episodeNumber: manager.mrpManager.nowPlayingEpisodeNumber,
            explicitEpisodeTitle: manager.mrpManager.nowPlayingEpisodeTitle
        )

        let snapshot = RemoteNowPlaying(
            artworkData: state.artworkData,
            duration: max(0, state.duration ?? 0),
            position: max(0, state.currentPosition),
            isPlaying: state.isPlaying,
            title: metadata.title,
            seasonEpisode: metadata.seasonEpisode,
            episodeTitle: metadata.episodeTitle
        )

        if nowPlaying != snapshot {
            nowPlaying = snapshot
        }
    }

    /// Every two seconds while a Now Playing surface is visible, ask only
    /// whether the previously displayed playback session is still alive. Core
    /// deliberately ignores healthy/partial verifier responses, so this timer
    /// cannot replace healthy third-party metadata or transport state. It exists only
    /// to clear a stale card when tvOS confirms stopped or empty playback.
    private func updateNowPlayingVerificationTimer() {
        let shouldRun = (remotePresented || miniRemotePresented) && isConnected

        if shouldRun {
            guard nowPlayingVerificationTimer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.verifyVisibleNowPlayingTeardown()
                }
            }
            timer.tolerance = 0.35
            nowPlayingVerificationTimer = timer
        } else {
            stopNowPlayingVerificationTimer()
        }
    }

    private func stopNowPlayingVerificationTimer() {
        nowPlayingVerificationTimer?.invalidate()
        nowPlayingVerificationTimer = nil
    }

    private func verifyVisibleNowPlayingTeardown() {
        guard (remotePresented || miniRemotePresented), isConnected else {
            updateNowPlayingVerificationTimer()
            return
        }
        manager.mrpManager.verifyNowPlayingTeardown()
    }

    /// Advance only the visible playback clock between protocol pushes. The
    /// timer does not exist while the panel is hidden, playback is paused, or
    /// duration is unavailable. A one-second cadence is sufficient for the
    /// displayed whole-second timeline and avoids background SwiftUI churn.
    private func updateTimelineTimer() {
        let shouldRun = (remotePresented || miniRemotePresented)
            && isConnected
            && nowPlaying?.isPlaying == true
            && (nowPlaying?.duration ?? 0) > 0

        if shouldRun {
            guard timelineTimer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshVisibleTimelinePosition()
                }
            }
            timer.tolerance = 0.25
            timelineTimer = timer
        } else {
            stopTimelineTimer()
        }
    }

    private func stopTimelineTimer() {
        timelineTimer?.invalidate()
        timelineTimer = nil
    }

    private func refreshVisibleTimelinePosition() {
        guard (remotePresented || miniRemotePresented), isConnected,
              let current = nowPlaying, current.isPlaying, current.duration > 0,
              let coreState = manager.mrpManager.nowPlaying else {
            updateTimelineTimer()
            return
        }

        let position = min(current.duration, max(0, coreState.currentPosition))
        guard abs(position - current.position) >= 0.5 else { return }

        nowPlaying = RemoteNowPlaying(
            artworkData: current.artworkData,
            duration: current.duration,
            position: position,
            isPlaying: current.isPlaying,
            title: current.title,
            seasonEpisode: current.seasonEpisode,
            episodeTitle: current.episodeTitle
        )
    }

    private struct ParsedMediaMetadata {
        let title: String?
        let seasonEpisode: String?
        let episodeTitle: String?
    }

    /// Normalize Now Playing metadata globally rather than branching on the
    /// source app. Structured TV fields from MediaRemote take priority when
    /// available; combined title parsing remains a compatibility fallback; and
    /// otherwise the standard artist/subtitle becomes the generic secondary
    /// line (for example a YouTube channel or music artist).
    private static func parseMediaMetadata(
        rawTitle: String?,
        secondary: String?,
        album: String?,
        explicitSeriesName: String?,
        seasonNumber: Int?,
        episodeNumber: Int?,
        explicitEpisodeTitle: String?
    ) -> ParsedMediaMetadata {
        let cleanSecondary = cleaned(secondary)
        let cleanAlbum = cleaned(album)
        let cleanSeries = cleaned(explicitSeriesName)
        let cleanEpisodeTitle = cleaned(explicitEpisodeTitle)
        let structuredSeasonEpisode = formattedSeasonEpisode(
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        )

        // AVKit publishes Apple TV episode details as structured MediaRemote
        // metadata instead of embedding them in the primary title. Treat those
        // protocol fields as authoritative whenever at least one is present.
        if cleanSeries != nil || structuredSeasonEpisode != nil || cleanEpisodeTitle != nil {
            return ParsedMediaMetadata(
                title: cleanSeries ?? cleaned(rawTitle) ?? cleanAlbum,
                seasonEpisode: structuredSeasonEpisode,
                episodeTitle: cleanEpisodeTitle ?? cleanSecondary
            )
        }

        // Other tvOS apps can still publish a combined title such as
        // "Show - S2 · E2 - Episode". Preserve that well-tested fallback.
        if let rawTitle, let parsed = parseCombinedTVTitle(rawTitle) {
            return ParsedMediaMetadata(
                title: parsed.title ?? cleanAlbum,
                seasonEpisode: parsed.seasonEpisode,
                episodeTitle: parsed.episodeTitle ?? cleanSecondary
            )
        }

        return ParsedMediaMetadata(
            title: cleaned(rawTitle) ?? cleanAlbum,
            seasonEpisode: nil,
            episodeTitle: cleanSecondary
        )
    }

    private static func formattedSeasonEpisode(
        seasonNumber: Int?,
        episodeNumber: Int?
    ) -> String? {
        let season = seasonNumber.flatMap { $0 > 0 ? $0 : nil }
        let episode = episodeNumber.flatMap { $0 > 0 ? $0 : nil }

        switch (season, episode) {
        case let (season?, episode?): return "S\(season) · E\(episode)"
        case let (season?, nil): return "S\(season)"
        case let (nil, episode?): return "E\(episode)"
        case (nil, nil): return nil
        }
    }

    private static func parseCombinedTVTitle(_ title: String) -> ParsedMediaMetadata? {
        // Match the season/episode marker independently of the separators
        // around it. tvOS apps have been observed using middle dots, bullets,
        // dashes and plain whitespace here, so accepting a short run of any
        // non-alphanumeric separator is more reliable than matching one exact
        // punctuation form.
        let markerPattern = #"(?i)S\s*(\d+)\s*[^A-Za-z0-9]{0,6}\s*E\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: markerPattern) else { return nil }
        let fullRange = NSRange(title.startIndex..<title.endIndex, in: title)
        guard let match = regex.firstMatch(in: title, range: fullRange), match.numberOfRanges == 3 else {
            return nil
        }

        func capture(_ index: Int) -> String? {
            guard let swiftRange = Range(match.range(at: index), in: title) else { return nil }
            return cleaned(String(title[swiftRange]))
        }

        guard let season = capture(1), let episode = capture(2) else { return nil }

        let nsTitle = title as NSString
        let beforeRange = NSRange(location: 0, length: match.range.location)
        let afterStart = match.range.location + match.range.length
        let afterRange = NSRange(location: afterStart, length: max(0, nsTitle.length - afterStart))

        let show = cleanedMediaSegment(nsTitle.substring(with: beforeRange))
        let episodeTitle = cleanedMediaSegment(nsTitle.substring(with: afterRange))

        // The important part is that a recognized S#/E# marker must never be
        // left embedded in the title row. Episode text may legitimately live
        // in a separate MRP subtitle field, so it is optional here.
        return ParsedMediaMetadata(
            title: show,
            seasonEpisode: "S\(season) · E\(episode)",
            episodeTitle: episodeTitle
        )
    }

    private static func cleanedMediaSegment(_ value: String) -> String? {
        let separatorCharacters = CharacterSet(charactersIn: "-–—|:·•")
            .union(.whitespacesAndNewlines)
        let result = value.trimmingCharacters(in: separatorCharacters)
        return result.isEmpty ? nil : result
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// The pinned protocol core's now-playing model has changed field names
    /// over time. Read optional textual metadata defensively so remotely's UI
    /// does not depend on those implementation details.
    private static func reflectedString(
        in value: Any,
        preferredLabels: [String],
        depth: Int = 0
    ) -> String? {
        guard depth <= 2 else { return nil }
        let labels = Set(preferredLabels.map { $0.lowercased() })
        let mirror = Mirror(reflecting: value)

        for child in mirror.children {
            let label = normalizedReflectionLabel(child.label)
            if let label, labels.contains(label), let string = unwrapString(child.value) {
                return cleaned(string)
            }
        }

        for child in mirror.children {
            let label = normalizedReflectionLabel(child.label) ?? ""
            if label.contains("metadata") || label.contains("info") || label.contains("playing") {
                if let result = reflectedString(in: child.value, preferredLabels: preferredLabels, depth: depth + 1) {
                    return result
                }
            }
        }
        return nil
    }

    private static func unwrapString(_ value: Any) -> String? {
        if let value = value as? String { return value }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional, let child = mirror.children.first {
            return unwrapString(child.value)
        }
        return nil
    }

    private static func normalizedReflectionLabel(_ label: String?) -> String? {
        guard let label else { return nil }
        return label
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            .lowercased()
    }

    private static func displayStatus(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("connected") { return "Connected" }
        if lower.hasPrefix("connecting") { return "Connecting…" }
        if lower.hasPrefix("pairing") { return "Pairing required. Enter the PIN shown on Apple TV." }
        if lower.hasPrefix("disconnected") { return "Disconnected" }
        if lower.hasPrefix("error") {
            // Preserve the associated error text without depending on the
            // protocol package's enum implementation details.
            return raw
                .replacingOccurrences(of: "error(\"", with: "")
                .replacingOccurrences(of: "\")", with: "")
                .replacingOccurrences(of: "error(", with: "")
                .replacingOccurrences(of: ")", with: "")
        }
        return raw
    }

    private func persistConnectedDevice(id: String, name: String) {
        defaults.set(id, forKey: DefaultsKey.selectedID)
        defaults.set(name, forKey: DefaultsKey.selectedName)
    }
}
