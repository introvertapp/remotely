import Foundation
import os.log
import SwiftProtobuf

private let log = CoreLog(category: "MRP")
private let autoSkipLog = Logger(subsystem: "com.local.remotely", category: "AutoSkip")
private let diagnoseAutoSkip = ProcessInfo.processInfo.arguments.contains("--diagnose-auto-skip")

/// Orchestrates the MRP protocol lifecycle: connect via AirPlay tunnel, subscribe
/// to now-playing updates, and send media commands.
///
/// Transport encryption is handled by AirPlayMRPTunnel at the AirPlay layer.
/// MRP-level pair-verify is NOT needed when tunneled over AirPlay (pyatv confirms
/// the MRP service has no credentials in this case).
@Observable
public final class MRPManager {
    public var nowPlaying: NowPlayingState?
    public var supportedCommands: Set<MediaCommand> = []
    /// Preferred skip intervals per command, as reported by the active app.
    public var preferredSkipIntervals: [MediaCommand: Double] = [:]
    public var activeAppBundleID: String?
    public var autoSkipOpeningContentEnabled = false

    /// Supplemental local MediaRemote metadata normalized independently of the
    /// source app. Apple TV publishes structured TV fields in preserved
    /// nowPlayingInfoData; other apps can continue using standard title/artist
    /// fields without any bundle-specific policy in remotely.
    public var nowPlayingSeriesName: String?
    public var nowPlayingSeasonNumber: Int?
    public var nowPlayingEpisodeNumber: Int?
    public var nowPlayingEpisodeTitle: String?
    public var onDisconnect: ((Error?) -> Void)?
    public var onReady: (() -> Void)?
    public var onKeyboardFocusChange: ((Bool) -> Void)?
    public var isConnected: Bool { tunnel != nil }

    private var tunnel: AirPlayMRPTunnel?
    private var credentials: HAPCredentials?

    /// Pending response handlers keyed by identifier string
    private var pendingResponses: [String: (MRP_ProtocolMessage?) -> Void] = [:]
    private let responseLock = NSLock()

    /// Playback queue content items and current location (from setStateMessage)
    private var contentItems: [MRP_ContentItem] = []
    private var queueLocation: UInt32 = 0
    private var currentPlaybackState: MRP_PlaybackState.Enum?
    private var artworkRequestPending = false
    private var playbackQueueRequestGeneration: UInt64 = 0
    private var nowPlayingVerificationPending = false
    private var nowPlayingVerificationGeneration: UInt64 = 0
    private var currentContentIdentifier: String?
    private var artworkUnavailable = false

    /// Supported-command state is reported independently for several MRP
    /// clients (e.g. Infuse, Music, AirPlay, Netflix). Keep those capabilities
    /// isolated so a background client's SetState cannot overwrite the controls
    /// for the client that actually owns the active playback queue.
    private var commandsByBundleID: [String: Set<MediaCommand>] = [:]
    private var skipIntervalsByBundleID: [String: [MediaCommand: Double]] = [:]
    private var currentPlayerBundleID: String?
    private var currentPlayerIdentifier: String?
    /// Once tvOS publishes SetNowPlayingClient/Player, that explicit lifecycle
    /// selection outranks heuristic `.playing` SetState messages from background
    /// clients. Nil preserves compatibility with older senders that omit it.
    private var explicitlySelectedBundleID: String?
    private var autoSkipOpeningCompletedKeys: Set<String> = []
    private var autoSkipOpeningPendingKeys: Set<String> = []

    public init() {}

    // MARK: - Connection lifecycle

    public func connect(host: String, port: UInt16, credentials: HAPCredentials) {
        log.info("MRP connect: \(host):\(port)")
        disconnect()

        self.credentials = credentials

        let tunnel = AirPlayMRPTunnel()
        self.tunnel = tunnel

        tunnel.onDisconnect = { [weak self] error in
            if let error {
                log.error("MRP disconnected: \(error.localizedDescription)")
            } else {
                log.info("MRP disconnected")
            }
            DispatchQueue.main.async {
                self?.tunnel = nil
                self?.nowPlaying = nil
                self?.supportedCommands = []
                self?.preferredSkipIntervals = [:]
                self?.commandsByBundleID = [:]
                self?.skipIntervalsByBundleID = [:]
                self?.currentPlayerBundleID = nil
                self?.currentPlayerIdentifier = nil
                self?.explicitlySelectedBundleID = nil
                self?.currentPlaybackState = nil
                self?.nowPlayingVerificationGeneration &+= 1
                self?.nowPlayingVerificationPending = false
                self?.autoSkipOpeningCompletedKeys.removeAll()
                self?.autoSkipOpeningPendingKeys.removeAll()
                self?.activeAppBundleID = nil
                self?.nowPlayingSeriesName = nil
                self?.nowPlayingSeasonNumber = nil
                self?.nowPlayingEpisodeNumber = nil
                self?.nowPlayingEpisodeTitle = nil
                self?.onDisconnect?(error)
            }
        }

        tunnel.onMessage = { [weak self] message in
            self?.handleMessage(message)
        }

        tunnel.onReady = { [weak self] in
            log.info("MRP tunnel ready")
            self?.startMRPSession()
        }

        tunnel.connect(host: host, port: port, credentials: credentials)
    }

    public func disconnect() {
        tunnel?.disconnect()
        tunnel = nil
        credentials = nil
        responseLock.lock()
        pendingResponses.removeAll()
        responseLock.unlock()
        contentItems = []
        queueLocation = 0
        currentPlaybackState = nil
        artworkRequestPending = false
        playbackQueueRequestGeneration &+= 1
        artworkUnavailable = false
        currentContentIdentifier = nil
        nowPlaying = nil
        supportedCommands = []
        preferredSkipIntervals = [:]
        commandsByBundleID = [:]
        skipIntervalsByBundleID = [:]
        currentPlayerBundleID = nil
        currentPlayerIdentifier = nil
        explicitlySelectedBundleID = nil
        nowPlayingVerificationGeneration &+= 1
        nowPlayingVerificationPending = false
        autoSkipOpeningCompletedKeys.removeAll()
        autoSkipOpeningPendingKeys.removeAll()
        activeAppBundleID = nil
        nowPlayingSeriesName = nil
        nowPlayingSeasonNumber = nil
        nowPlayingEpisodeNumber = nil
        nowPlayingEpisodeTitle = nil
    }

    // MARK: - Media commands

    public func sendCommand(_ command: MediaCommand) {
        var sendCmd = MRP_SendCommandMessage()
        sendCmd.command = command.mrpCommand

        var message = MRP_ProtocolMessage()
        message.type = .sendCommandMessage
        message.MRP_sendCommandMessage = sendCmd

        tunnel?.send(message)
    }

    /// Send a skip command with a time interval in seconds.
    public func sendSkip(_ command: MediaCommand, interval: Float = 15) {
        var options = MRP_CommandOptions()
        options.skipInterval = interval

        var sendCmd = MRP_SendCommandMessage()
        sendCmd.command = command.mrpCommand
        sendCmd.options = options

        var message = MRP_ProtocolMessage()
        message.type = .sendCommandMessage
        message.MRP_sendCommandMessage = sendCmd

        tunnel?.send(message)
    }

    /// Send a raw HID event (usage page + usage code + down/up).
    ///
    /// This is used for hardware-level key events like mute that are not
    /// part of the media command set. The binary format matches what pyatv
    /// sends via `SEND_HID_EVENT_MESSAGE`.
    public func sendHidEvent(usagePage: UInt16, usage: UInt16, down: Bool) {
        guard tunnel != nil else {
            log.error("sendHidEvent: no MRP tunnel")
            return
        }

        // Hardcoded mach AbsoluteTime (device does not care about the value)
        let absTime = Data([0x43, 0x89, 0x22, 0xcf, 0x08, 0x02, 0x00, 0x00])

        // Binary layout must exactly match pyatv's send_hid_event format (35 bytes)
        let padding = Data([
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00
        ])

        var payload = Data()
        payload.append(UInt8(usagePage >> 8))
        payload.append(UInt8(usagePage & 0xFF))
        payload.append(UInt8(usage >> 8))
        payload.append(UInt8(usage & 0xFF))
        payload.append(UInt8(0x00))
        payload.append(UInt8(down ? 0x01 : 0x00))

        let trailer = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])

        let eventData = absTime + padding + payload + trailer
        log.error("sendHidEvent: page=\(usagePage) usage=\(usage) down=\(down) bytes=\(eventData.count) hex=\(eventData.map { String(format: "%02x", $0) }.joined())")

        var event = MRP_SendHIDEventMessage()
        event.hidEventData = eventData

        var message = MRP_ProtocolMessage()
        message.type = .sendHidEventMessage
        message.uniqueIdentifier = UUID().uuidString.uppercased()
        message.MRP_sendHIDEventMessage = event

        tunnel?.send(message)
    }

    /// Toggle mute on/off via HDMI-CEC.
    ///
    /// Sends USB HID Consumer usage page (0x0C) mute key (0xE2),
    /// followed by a GENERIC_MESSAGE flush to reset protocol state.
    /// Without the flush, subsequent button presses can break.
    public func toggleMute() {
        log.error("toggleMute called, tunnel connected: \(tunnel != nil)")
        sendHidEvent(usagePage: 0x000C, usage: 0x00E2, down: true)
        sendHidEvent(usagePage: 0x000C, usage: 0x00E2, down: false)

        // Flush: send a GENERIC_MESSAGE and wait for response.
        // This prevents protocol state corruption after HID events.
        var flush = MRP_ProtocolMessage()
        flush.type = .genericMessage
        sendAndReceive(&flush) { _ in
            log.error("toggleMute flush complete")
        }
    }

    /// Set volume directly (0.0 = muted, 1.0 = max).
    public func setVolume(_ level: Float) {
        var vol = MRP_SetVolumeMessage()
        vol.volume = level

        var message = MRP_ProtocolMessage()
        message.type = .setVolumeMessage
        message.MRP_setVolumeMessage = vol

        let connected = self.tunnel != nil
        log.info("MRP setVolume: \(level), tunnel: \(connected), hasExt: \(message.hasMRP_setVolumeMessage)")
        tunnel?.send(message)
    }

    /// Re-request the playback queue to get fresh elapsed time (e.g. after returning from background).
    public func refreshNowPlaying() {
        guard tunnel != nil else { return }
        sendPlaybackQueueRequest()
    }

    /// Lightweight foreground verification used only to detect an inactive
    /// playback session that failed to publish its normal teardown event.
    ///
    /// This deliberately does not feed a healthy response through handleSetState:
    /// third-party apps can return partial/ambiguous queue snapshots to explicit
    /// requests, and treating those snapshots as authoritative could erase
    /// otherwise-valid artwork, timeline and transport state. Normal MRP pushes
    /// and explicit one-shot refreshes remain the only paths that populate or
    /// replace active playback metadata.
    public func verifyNowPlayingTeardown() {
        guard tunnel != nil, !nowPlayingVerificationPending else { return }

        var request = MRP_PlaybackQueueRequestMessage()
        request.location = 0
        request.length = 1
        request.includeMetadata = true
        request.returnContentItemAssetsInUserCompletion = false

        var msg = MRP_ProtocolMessage()
        msg.type = .playbackQueueRequestMessage
        msg.MRP_playbackQueueRequestMessage = request

        // Bind this probe to the exact playback session that existed when it
        // was sent. A client/player switch invalidates playbackQueueRequestGeneration,
        // so a delayed teardown reply from the previous app can never clear the
        // newer session. The verifier generation separately prevents a callback
        // from an invalidated connection/probe from changing current pending state.
        nowPlayingVerificationGeneration &+= 1
        let verificationGeneration = nowPlayingVerificationGeneration
        let sessionGeneration = playbackQueueRequestGeneration
        let sessionBundleID = currentPlayerBundleID
        let sessionPlayerID = currentPlayerIdentifier
        nowPlayingVerificationPending = true
        sendAndReceive(&msg) { [weak self] response in
            guard let self else { return }
            guard self.nowPlayingVerificationGeneration == verificationGeneration else { return }
            self.nowPlayingVerificationPending = false
            guard self.playbackQueueRequestGeneration == sessionGeneration,
                  self.currentPlayerBundleID == sessionBundleID,
                  self.currentPlayerIdentifier == sessionPlayerID else { return }
            guard let response, response.hasMRP_setStateMessage else { return }
            self.handleNowPlayingTeardownVerification(
                response.MRP_setStateMessage,
                expectedBundleID: sessionBundleID,
                expectedPlayerID: sessionPlayerID
            )
        }
    }

    public func seekToPosition(_ position: Double) {
        var options = MRP_CommandOptions()
        options.playbackPosition = position

        var sendCmd = MRP_SendCommandMessage()
        sendCmd.command = .seekToPlaybackPosition
        sendCmd.options = options

        var message = MRP_ProtocolMessage()
        message.type = .sendCommandMessage
        message.MRP_sendCommandMessage = sendCmd

        tunnel?.send(message)
    }

    // MARK: - Send and receive

    /// Send a message and wait for a response matched by identifier.
    /// If no response arrives within 5 seconds, the handler fires with nil.
    private func sendAndReceive(
        _ message: inout MRP_ProtocolMessage,
        completion: @escaping (MRP_ProtocolMessage?) -> Void
    ) {
        let identifier = UUID().uuidString.uppercased()
        message.identifier = identifier

        responseLock.lock()
        pendingResponses[identifier] = { response in
            completion(response)
        }
        responseLock.unlock()

        let typeDesc = String(describing: message.type)
        log.info("MRP send: \(typeDesc)")
        tunnel?.send(message)

        // Timeout after 5 seconds
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.responseLock.lock()
            let handler = self.pendingResponses.removeValue(forKey: identifier)
            self.responseLock.unlock()
            if let handler {
                log.warning("MRP timeout: \(typeDesc)")
                handler(nil)
            }
        }
    }

    private func sendFire(_ message: MRP_ProtocolMessage) {
        tunnel?.send(message)
    }

    // MARK: - Message handling

    private func handleMessage(_ message: MRP_ProtocolMessage) {
        // Check for pending response handler by identifier first. Lifecycle
        // notifications are unsolicited, while request responses must retain
        // the existing identifier-based dispatch contract.
        if message.hasIdentifier {
            let id = message.identifier
            responseLock.lock()
            let handler = pendingResponses.removeValue(forKey: id)
            responseLock.unlock()
            if let handler {
                handler(message)
                return
            }
        }

        // The pinned protocol schema names SetNowPlayingClient/Player but does
        // not include their extension payloads, and predates RemoveClient/Player
        // enum cases entirely. SwiftProtobuf preserves those fields on the wire,
        // so inspect the raw type before falling back to generated accessors.
        switch Self.rawProtocolType(of: message) {
        case 46:
            handleSetNowPlayingClient(message)
            return
        case 47:
            handleSetNowPlayingPlayer(message)
            return
        case 53:
            handleRemoveClient(message)
            return
        case 54:
            handleRemovePlayer(message)
            return
        default:
            break
        }

        guard message.hasType else { return }
        switch message.type {
        case .setStateMessage:
            handleSetState(message)
        case .updateContentItemMessage:
            handleUpdateContentItem(message)
        default:
            break
        }
    }

    // MARK: - Session initialization

    private func startMRPSession() {
        sendDeviceInfo { [weak self] _ in
            self?.sendSetConnectionState()
            self?.sendClientUpdatesConfig { _ in
                self?.sendPlaybackQueueRequest()
                self?.tunnel?.startHeartbeat()
                log.info("MRP session initialized")
                self?.onReady?()
            }
        }
    }

    // MARK: - Device info

    private func sendDeviceInfo(completion: @escaping (MRP_ProtocolMessage?) -> Void) {
        guard let credentials else { return }

        var deviceInfo = MRP_DeviceInfoMessage()
        deviceInfo.uniqueIdentifier = credentials.clientID
        deviceInfo.name = "remotely"
        deviceInfo.localizedModelName = "iPhone"
        deviceInfo.applicationBundleIdentifier = "com.apple.TVRemote"
        deviceInfo.applicationBundleVersion = "344.28"
        deviceInfo.protocolVersion = 1
        deviceInfo.lastSupportedMessageType = 108
        deviceInfo.supportsSystemPairing = true
        deviceInfo.allowsPairing = true
        deviceInfo.supportsAcl = true
        deviceInfo.supportsSharedQueue = true
        deviceInfo.supportsExtendedMotion = true
        deviceInfo.sharedQueueVersion = 2
        deviceInfo.systemMediaApplication = "com.apple.TVMusic"
        deviceInfo.deviceClass = .iPhone
        deviceInfo.logicalDeviceCount = 1

        var msg = MRP_ProtocolMessage()
        msg.type = .deviceInfoMessage
        msg.MRP_deviceInfoMessage = deviceInfo

        sendAndReceive(&msg, completion: completion)
    }

    // MARK: - Set connection state

    private func sendSetConnectionState() {
        var connState = MRP_SetConnectionStateMessage()
        connState.state = .connected

        var msg = MRP_ProtocolMessage()
        msg.type = .setConnectionStateMessage
        msg.MRP_setConnectionStateMessage = connState

        sendFire(msg)
    }

    // MARK: - Client updates config

    private func sendClientUpdatesConfig(completion: @escaping (MRP_ProtocolMessage?) -> Void) {
        var config = MRP_ClientUpdatesConfigMessage()
        config.artworkUpdates = true
        config.nowPlayingUpdates = true
        config.volumeUpdates = true
        config.keyboardUpdates = true
        config.outputDeviceUpdates = true

        var msg = MRP_ProtocolMessage()
        msg.type = .clientUpdatesConfigMessage
        msg.MRP_clientUpdatesConfigMessage = config

        sendAndReceive(&msg, completion: completion)
    }

    // MARK: - Now playing updates

    private func bundleIdentifier(from state: MRP_SetStateMessage) -> String? {
        bundleIdentifier(from: state.hasPlayerPath ? state.playerPath : nil)
    }

    private func bundleIdentifier(from update: MRP_UpdateContentItemMessage) -> String? {
        bundleIdentifier(from: update.hasPlayerPath ? update.playerPath : nil)
    }

    private func bundleIdentifier(from path: MRP_PlayerPath?) -> String? {
        guard let path, path.hasClient, path.client.hasBundleIdentifier else {
            return nil
        }
        let bundleID = path.client.bundleIdentifier
        return bundleID.isEmpty ? nil : bundleID
    }

    private func playerIdentifier(from state: MRP_SetStateMessage) -> String? {
        playerIdentifier(from: state.hasPlayerPath ? state.playerPath : nil)
    }

    private func playerIdentifier(from update: MRP_UpdateContentItemMessage) -> String? {
        playerIdentifier(from: update.hasPlayerPath ? update.playerPath : nil)
    }

    private func playerIdentifier(from path: MRP_PlayerPath?) -> String? {
        guard let path, path.hasPlayer, path.player.hasIdentifier else { return nil }
        let playerID = path.player.identifier
        return playerID.isEmpty ? nil : playerID
    }

    private func publishCommands(for bundleID: String) {
        let commands = commandsByBundleID[bundleID] ?? []
        let intervals = skipIntervalsByBundleID[bundleID] ?? [:]
        DispatchQueue.main.async {
            // A newer player may have become active while this publication was
            // waiting for the main actor. Do not let stale work cross players.
            guard self.currentPlayerBundleID == bundleID else { return }
            self.supportedCommands = commands
            self.preferredSkipIntervals = intervals
        }
    }

    /// Clear state that belongs to one concrete playback session. This is used
    /// whenever MRP explicitly changes/removes the active client or player.
    /// Keeping it centralized ensures descriptive metadata cannot survive into
    /// a different app/player while still allowing partial updates for the same
    /// content item to retain fields that tvOS temporarily omits.
    private func clearCurrentPlaybackSnapshot() {
        contentItems = []
        queueLocation = 0
        currentPlaybackState = nil
        artworkRequestPending = false
        playbackQueueRequestGeneration &+= 1
        artworkUnavailable = false
        autoSkipOpeningCompletedKeys.removeAll()
        autoSkipOpeningPendingKeys.removeAll()
        clearDisplayedNowPlaying()
    }

    private func clearDisplayedNowPlaying() {
        currentContentIdentifier = nil
        DispatchQueue.main.async {
            self.nowPlaying = nil
            self.nowPlayingSeriesName = nil
            self.nowPlayingSeasonNumber = nil
            self.nowPlayingEpisodeNumber = nil
            self.nowPlayingEpisodeTitle = nil
        }
    }

    /// Select the active MRP owner. A client switch always starts a new playback
    /// session. Within one client, an explicitly different player identifier is
    /// also a new session; learning an identifier after SetNowPlayingClient is
    /// merely identity refinement and does not clear a queue twice.
    @discardableResult
    private func activatePlayer(bundleID: String, playerID: String? = nil) -> Bool {
        let bundleChanged = currentPlayerBundleID != bundleID
        let knownPlayerChanged =
            !bundleChanged &&
            currentPlayerIdentifier != nil &&
            playerID != nil &&
            currentPlayerIdentifier != playerID
        let sessionChanged = bundleChanged || knownPlayerChanged

        if sessionChanged {
            clearCurrentPlaybackSnapshot()
        }

        currentPlayerBundleID = bundleID
        if let playerID {
            currentPlayerIdentifier = playerID
        } else if bundleChanged {
            currentPlayerIdentifier = nil
        }

        DispatchQueue.main.async {
            self.activeAppBundleID = bundleID
        }
        publishCommands(for: bundleID)
        return sessionChanged
    }

    private func currentOwnerMatches(bundleID: String?, playerID: String? = nil) -> Bool {
        guard let bundleID, bundleID == currentPlayerBundleID else { return false }
        guard let playerID, let currentPlayerIdentifier else { return true }
        return playerID == currentPlayerIdentifier
    }

    private func discardCurrentPlayer(bundleID: String, playerID: String? = nil, removeClient: Bool) {
        // RemoveClient is authoritative for the lifetime of that client. Retire
        // its cached command metadata even when it is not the visible owner, so
        // a later client with the same bundle cannot inherit stale capabilities.
        // This cleanup is independent of current Now Playing ownership.
        if removeClient {
            commandsByBundleID.removeValue(forKey: bundleID)
            skipIntervalsByBundleID.removeValue(forKey: bundleID)
        }

        guard bundleID == currentPlayerBundleID else { return }

        // A client can own several players. RemovePlayer only retires the active
        // player when we can prove the removed identifier is the one selected.
        // If our active identifier is unknown, a specific background-player
        // removal must not destroy an otherwise healthy client session.
        if !removeClient, let playerID {
            guard let currentPlayerIdentifier, currentPlayerIdentifier == playerID else { return }
        }

        clearCurrentPlaybackSnapshot()
        currentPlayerIdentifier = nil

        if removeClient {
            currentPlayerBundleID = nil
            DispatchQueue.main.async {
                self.activeAppBundleID = nil
                self.supportedCommands = []
                self.preferredSkipIntervals = [:]
            }
        } else {
            // Removing the active player does not remove its client. Keep the
            // client selected so a replacement/default player from the same app
            // can repopulate Now Playing without requiring another client event.
            DispatchQueue.main.async {
                self.activeAppBundleID = bundleID
            }
            publishCommands(for: bundleID)
        }
    }

    /// Apply only a conclusive idle result from the periodic verifier. A
    /// non-empty/playing response is intentionally ignored so polling can never
    /// replace a healthy third-party queue.
    private func handleNowPlayingTeardownVerification(
        _ state: MRP_SetStateMessage,
        expectedBundleID: String?,
        expectedPlayerID: String?
    ) {
        let bundleID = bundleIdentifier(from: state)
        let playerID = playerIdentifier(from: state)

        // Some explicit queue replies omit player identity entirely, including
        // the inactive/empty result used to detect an app close. Accept that
        // identity-poor result only because the callback above has already
        // proven the local playback session is unchanged. When tvOS does supply
        // identity, it must agree with the session that originated this probe.
        if let expectedBundleID, let bundleID, bundleID != expectedBundleID { return }
        if let expectedPlayerID, let playerID, playerID != expectedPlayerID { return }

        // An explicit Playing state outranks a temporarily empty queue response.
        if state.hasPlaybackState && state.playbackState == .playing { return }

        let reportsStopped = state.hasPlaybackState && state.playbackState == .stopped
        let reportsEmptyQueue = state.hasPlaybackQueue && state.playbackQueue.contentItems.isEmpty
        guard reportsStopped || reportsEmptyQueue else { return }

        log.info("MRP verifier confirmed inactive Now Playing session")
        clearVerifiedInactivePlayback()
    }

    private func clearVerifiedInactivePlayback() {
        let retiredBundleID = currentPlayerBundleID
        clearCurrentPlaybackSnapshot()

        if let retiredBundleID {
            commandsByBundleID.removeValue(forKey: retiredBundleID)
            skipIntervalsByBundleID.removeValue(forKey: retiredBundleID)
        }
        currentPlayerBundleID = nil
        currentPlayerIdentifier = nil
        explicitlySelectedBundleID = nil

        DispatchQueue.main.async {
            self.activeAppBundleID = nil
            self.supportedCommands = []
            self.preferredSkipIntervals = [:]
        }
    }

    // MARK: - Explicit MRP now-playing lifecycle

    private func handleSetNowPlayingClient(_ message: MRP_ProtocolMessage) {
        guard let payload = Self.extensionPayload(number: 50, from: message),
              let client = Self.firstLengthDelimitedField(number: 1, in: payload).flatMap({ try? MRP_NowPlayingClient(serializedData: $0) }),
              client.hasBundleIdentifier,
              !client.bundleIdentifier.isEmpty else { return }

        explicitlySelectedBundleID = client.bundleIdentifier
        let changed = activatePlayer(bundleID: client.bundleIdentifier)
        log.info("MRP now-playing client: \(client.bundleIdentifier) changed=\(changed)")
        requestNowPlayingForLifecycleChange()
    }

    private func handleSetNowPlayingPlayer(_ message: MRP_ProtocolMessage) {
        guard let payload = Self.extensionPayload(number: 51, from: message),
              let path = Self.firstLengthDelimitedField(number: 1, in: payload).flatMap({ try? MRP_PlayerPath(serializedData: $0) }),
              let bundleID = bundleIdentifier(from: path) else { return }

        let playerID = playerIdentifier(from: path)
        // SetNowPlayingPlayer selects a player *within* a client; it does not
        // make that client the active Now Playing application. Background
        // clients legitimately publish player changes, so only refine the
        // player identity when this bundle is already the selected/active client.
        guard explicitlySelectedBundleID == bundleID || currentPlayerBundleID == bundleID else {
            log.info("MRP player selection ignored for inactive client: \(bundleID) player=\(playerID ?? "nil")")
            return
        }
        let changed = activatePlayer(bundleID: bundleID, playerID: playerID)
        log.info("MRP now-playing player: \(bundleID) player=\(playerID ?? "nil") changed=\(changed)")
        requestNowPlayingForLifecycleChange()
    }

    private func handleRemoveClient(_ message: MRP_ProtocolMessage) {
        guard let payload = Self.extensionPayload(number: 57, from: message),
              let client = Self.firstLengthDelimitedField(number: 1, in: payload).flatMap({ try? MRP_NowPlayingClient(serializedData: $0) }),
              client.hasBundleIdentifier,
              !client.bundleIdentifier.isEmpty else { return }

        log.info("MRP remove client: \(client.bundleIdentifier)")
        if explicitlySelectedBundleID == client.bundleIdentifier {
            explicitlySelectedBundleID = nil
        }
        discardCurrentPlayer(bundleID: client.bundleIdentifier, removeClient: true)
    }

    private func handleRemovePlayer(_ message: MRP_ProtocolMessage) {
        guard let payload = Self.extensionPayload(number: 58, from: message),
              let path = Self.firstLengthDelimitedField(number: 1, in: payload).flatMap({ try? MRP_PlayerPath(serializedData: $0) }),
              let bundleID = bundleIdentifier(from: path) else { return }

        let playerID = playerIdentifier(from: path)
        log.info("MRP remove player: \(bundleID) player=\(playerID ?? "nil")")
        discardCurrentPlayer(bundleID: bundleID, playerID: playerID, removeClient: false)
    }

    private func requestNowPlayingForLifecycleChange() {
        // The lifecycle message selects ownership but carries no playback queue.
        // Request a fresh queue immediately rather than waiting for an unrelated
        // playback event to shake stale UI state loose. The pending guard prevents
        // duplicate artwork/queue requests while tvOS is already answering one.
        requestArtworkIfNeeded()
    }

    private func handleSetState(_ message: MRP_ProtocolMessage) {
        guard message.hasMRP_setStateMessage else { return }
        let state = message.MRP_setStateMessage
        let bundleID = bundleIdentifier(from: state)
        let playerID = playerIdentifier(from: state)

        var parsedCommands: Set<MediaCommand>?
        var parsedIntervals: [MediaCommand: Double] = [:]

        if state.hasSupportedCommands {
            let infos = state.supportedCommands.supportedCommands
                .filter { $0.hasEnabled && $0.enabled && $0.hasCommand }
            let cmds = infos.compactMap { MediaCommand($0.command) }
            parsedCommands = Set(cmds)

            for info in infos {
                if let cmd = MediaCommand(info.command), !info.preferredIntervals.isEmpty {
                    log.info("MRP cmd \(String(describing: cmd)): preferredIntervals=\(info.preferredIntervals)")
                    parsedIntervals[cmd] = info.preferredIntervals.first
                }
            }
            if !parsedIntervals.isEmpty {
                log.info("MRP skip intervals: \(parsedIntervals.map { "\($0.key): \($0.value)s" }.joined(separator: ", "))")
            }

            if let bundleID {
                commandsByBundleID[bundleID] = parsedCommands ?? []
                skipIntervalsByBundleID[bundleID] = parsedIntervals
            }
        }

        let hasQueueItems = state.hasPlaybackQueue && !state.playbackQueue.contentItems.isEmpty
        let isPlaying = state.hasPlaybackState && state.playbackState == .playing

        if let bundleID {
            let lifecycleAllowsActivation =
                explicitlySelectedBundleID == nil || explicitlySelectedBundleID == bundleID
            if lifecycleAllowsActivation {
                if isPlaying {
                    activatePlayer(bundleID: bundleID, playerID: playerID)
                } else if currentPlayerBundleID == nil && hasQueueItems {
                    activatePlayer(bundleID: bundleID, playerID: playerID)
                }
            }
        }

        // If the current player's command set arrived in this message, publish
        // it now. Command sets from all other clients remain cached but cannot
        // replace the active player's transport capabilities.
        if let bundleID, currentPlayerBundleID == bundleID, state.hasSupportedCommands {
            publishCommands(for: bundleID)
        } else if bundleID == nil, currentPlayerBundleID == nil, let parsedCommands {
            // Compatibility fallback for a SetState lacking a player path.
            DispatchQueue.main.async {
                self.supportedCommands = parsedCommands
                self.preferredSkipIntervals = parsedIntervals
            }
        }

        let ownsPlayback = bundleID.map { currentOwnerMatches(bundleID: $0, playerID: playerID) }
            ?? (currentPlayerBundleID == nil)
        guard ownsPlayback else { return }

        if state.hasPlaybackState {
            currentPlaybackState = state.playbackState
        }
        if state.hasPlaybackQueue {
            applyPlaybackQueue(state.playbackQueue)
        }

        if currentPlaybackState == .stopped {
            // Keep the queue so transient stops can recover on the next Playing
            // event. Metadata updates alone must not make a stopped item visible.
            clearDisplayedNowPlaying()
            return
        }

        if state.hasPlaybackQueue {
            updateNowPlayingFromContentItems()
            maybeAutoSkipOpeningContent()
        }
        if state.hasPlaybackState {
            let pbState = state.playbackState
            if !state.hasPlaybackQueue,
               pbState == .playing || pbState == .paused,
               nowPlaying == nil, !contentItems.isEmpty {
                updateNowPlayingFromContentItems()
            }

            DispatchQueue.main.async {
                if var current = self.nowPlaying {
                    // Snapshot current position before changing rate
                    current.elapsedTime = current.currentPosition
                    current.playbackRate = (pbState == .playing) ? 1 : 0
                    current.timestamp = Date()
                    self.nowPlaying = current
                } else if pbState == .playing {
                    self.requestArtworkIfNeeded()
                }
            }
        }
    }

    // MARK: - Opening-content auto-skip

    /// Apple TV's AVKit player publishes an authoritative main-content start
    /// time in opaque MediaRemote metadata. When the user opts in, seek to that
    /// destination once for a newly started playback item. This deliberately
    /// does not try to classify advertisements, recaps, logos, or other opening
    /// segments; Apple owns that segmentation and supplies the final boundary.
    private func maybeAutoSkipOpeningContent() {
        guard autoSkipOpeningContentEnabled, currentPlaybackState != .stopped,
              !contentItems.isEmpty else { return }

        let location = min(Int(queueLocation), contentItems.count - 1)
        let item = contentItems[location]
        guard item.hasMetadata else { return }

        let metadata = item.metadata
        guard let target = Self.mainContentStartTime(from: metadata),
              target.isFinite,
              target > 1 else {
            if diagnoseAutoSkip {
                autoSkipLog.notice("Playback item has no usable main-content marker.")
            }
            return
        }

        let position = metadata.hasElapsedTime ? metadata.elapsedTime : 0
        guard position.isFinite,
              position >= 0,
              position <= 10,
              position + 0.75 < target else {
            if diagnoseAutoSkip {
                autoSkipLog.notice("Main-content marker at \(target, privacy: .public)s, outside the opening window at \(position, privacy: .public)s.")
            }
            return
        }

        let key: String
        if item.hasIdentifier, !item.identifier.isEmpty {
            key = item.identifier
        } else if metadata.hasContentIdentifier, !metadata.contentIdentifier.isEmpty {
            key = metadata.contentIdentifier
        } else {
            // Without a stable playback identity we cannot safely enforce the
            // one-shot guarantee across repeated metadata publications.
            return
        }

        guard !autoSkipOpeningCompletedKeys.contains(key),
              !autoSkipOpeningPendingKeys.contains(key) else { return }

        autoSkipOpeningPendingKeys.insert(key)

        // Let the new AVKit item settle before sending the seek. Re-check all
        // safety conditions after the delay so an item switch, preference
        // change, or user seek cannot be overridden by stale scheduled work.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self else { return }
            self.autoSkipOpeningPendingKeys.remove(key)

            guard self.autoSkipOpeningContentEnabled,
                  self.currentPlaybackState != .stopped,
                  !self.contentItems.isEmpty else { return }

            let currentLocation = min(Int(self.queueLocation), self.contentItems.count - 1)
            let currentItem = self.contentItems[currentLocation]
            guard currentItem.hasMetadata else { return }

            let currentMetadata = currentItem.metadata
            let currentKey: String
            if currentItem.hasIdentifier, !currentItem.identifier.isEmpty {
                currentKey = currentItem.identifier
            } else if currentMetadata.hasContentIdentifier, !currentMetadata.contentIdentifier.isEmpty {
                currentKey = currentMetadata.contentIdentifier
            } else {
                return
            }

            guard currentKey == key,
                  let currentTarget = Self.mainContentStartTime(from: currentMetadata),
                  currentTarget.isFinite,
                  currentTarget > 1 else { return }

            let currentPosition = currentMetadata.hasElapsedTime ? currentMetadata.elapsedTime : position
            guard currentPosition.isFinite,
                  currentPosition >= 0,
                  currentPosition <= 10,
                  currentPosition + 0.75 < currentTarget else { return }

            self.autoSkipOpeningCompletedKeys.insert(key)
            if diagnoseAutoSkip {
                autoSkipLog.notice("Sending opening-content seek from \(currentPosition, privacy: .public)s to \(currentTarget, privacy: .public)s.")
            }
            self.seekToPosition(currentTarget)
        }
    }

    /// Field 67 is unknown to the generated schema. Same-item updates append
    /// unknown fields, so the first archive can predate the opening marker.
    static func mainContentStartTime(from metadata: MRP_ContentItemMetadata) -> Double? {
        lengthDelimitedFields(number: 67, in: metadata.unknownFields.data)
            .reversed()
            .lazy
            .compactMap { findMainContentStartTime(in: decodeNowPlayingInfoArchive($0)) }
            .first
    }

    private struct SupplementalMediaMetadata {
        let seriesName: String?
        let seasonNumber: Int?
        let episodeNumber: Int?
        let episodeTitle: String?
    }

    /// Decode structured MediaRemote fields without tying the result to a
    /// particular source application. AVKit currently uses these keys for TV
    /// metadata, while apps that do not publish them simply return nil here.
    private func supplementalMediaMetadata(from metadata: MRP_ContentItemMetadata) -> SupplementalMediaMetadata {
        guard let root = Self.nowPlayingInfoArchive(from: metadata) else {
            return SupplementalMediaMetadata(
                seriesName: nil,
                seasonNumber: nil,
                episodeNumber: nil,
                episodeTitle: nil
            )
        }

        return SupplementalMediaMetadata(
            seriesName: Self.stringValue(forKeys: [
                "mdta/com.apple.hls.series-title",
                "avkt/com.apple.avkit.seriesName"
            ], in: root),
            seasonNumber: Self.integerValue(
                forKey: "avkt/com.apple.avkit.seasonNumber",
                in: root
            ),
            episodeNumber: Self.integerValue(
                forKey: "avkt/com.apple.avkit.episodeNumber",
                in: root
            ),
            episodeTitle: Self.stringValue(
                forKeys: [
                    "mdta/com.apple.hls.episode-title",
                    "avkt/com.apple.avkit.episodeTitle"
                ],
                in: root
            )
        )
    }

    private static func nowPlayingInfoArchive(from metadata: MRP_ContentItemMetadata) -> Any? {
        guard let archive = firstLengthDelimitedField(number: 67, in: metadata.unknownFields.data) else { return nil }
        return decodeNowPlayingInfoArchive(archive)
    }

    private static func decodeNowPlayingInfoArchive(_ archive: Data) -> Any? {
        guard archive.starts(with: Data("bplist00".utf8)) else { return nil }
        return try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(archive)
    }

    private static func stringValue(forKeys keys: [String], in value: Any?) -> String? {
        for key in keys {
            if let rawValue = findValue(forKey: key, in: value) {
                if let text = rawValue as? String {
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty { return cleaned }
                }
                if let number = rawValue as? NSNumber {
                    return number.stringValue
                }
            }
        }
        return nil
    }

    private static func integerValue(forKey key: String, in value: Any?) -> Int? {
        guard let rawValue = findValue(forKey: key, in: value) else { return nil }
        if let number = rawValue as? NSNumber { return number.intValue }
        if let text = rawValue as? String { return Int(text) }
        return nil
    }

    private static func findValue(forKey wantedKey: String, in value: Any?) -> Any? {
        guard let value else { return nil }

        if let dictionary = value as? NSDictionary {
            for (rawKey, rawValue) in dictionary {
                if let key = rawKey as? String, key == wantedKey {
                    return rawValue
                }
                if let nested = findValue(forKey: wantedKey, in: rawValue) {
                    return nested
                }
            }
            return nil
        }

        if let array = value as? NSArray {
            for item in array {
                if let nested = findValue(forKey: wantedKey, in: item) {
                    return nested
                }
            }
        }

        return nil
    }

    private static func findMainContentStartTime(in value: Any?) -> Double? {
        guard let value else { return nil }

        if let dictionary = value as? NSDictionary {
            for (rawKey, rawValue) in dictionary {
                if let key = rawKey as? String,
                   key == "avkt/TVRMainContentStartTime" {
                    if let number = rawValue as? NSNumber {
                        return number.doubleValue
                    }
                    if let text = rawValue as? String, let number = Double(text) {
                        return number
                    }
                }

                if let nested = findMainContentStartTime(in: rawValue) {
                    return nested
                }
            }
            return nil
        }

        if let array = value as? NSArray {
            for item in array {
                if let nested = findMainContentStartTime(in: item) {
                    return nested
                }
            }
        }

        return nil
    }

    /// Recover a raw ProtocolMessage type even when the pinned generated enum
    /// predates that value (notably RemoveClient=53 and RemovePlayer=54).
    private static func rawProtocolType(of message: MRP_ProtocolMessage) -> UInt64? {
        guard let serialized = try? message.serializedData(partial: true) else {
            return message.hasType ? UInt64(message.type.rawValue) : nil
        }
        return firstVarintField(number: 1, in: serialized)
    }

    /// Recover an extension payload omitted by the pinned generated schema.
    private static func extensionPayload(number: Int, from message: MRP_ProtocolMessage) -> Data? {
        guard let serialized = try? message.serializedData(partial: true) else { return nil }
        return firstLengthDelimitedField(number: number, in: serialized)
    }

    private static func firstVarintField(number wanted: Int, in data: Data) -> UInt64? {
        var index = 0

        while index < data.count {
            guard let tag = readVarint(data, index: &index) else { return nil }
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)

            switch wireType {
            case 0:
                guard let value = readVarint(data, index: &index) else { return nil }
                if fieldNumber == wanted { return value }

            case 1:
                guard index + 8 <= data.count else { return nil }
                index += 8

            case 2:
                guard let rawLength = readVarint(data, index: &index),
                      rawLength <= UInt64(Int.max) else { return nil }
                let length = Int(rawLength)
                guard index + length <= data.count else { return nil }
                index += length

            case 5:
                guard index + 4 <= data.count else { return nil }
                index += 4

            default:
                return nil
            }
        }

        return nil
    }

    /// Minimal protobuf wire reader used for preserved private metadata and
    /// lifecycle extensions absent from the pinned generated protocol schema.
    private static func firstLengthDelimitedField(number wanted: Int, in data: Data) -> Data? {
        lengthDelimitedFields(number: wanted, in: data, limit: 1).first
    }

    private static func lengthDelimitedFields(number wanted: Int, in data: Data, limit: Int = .max) -> [Data] {
        var index = 0
        var fields: [Data] = []

        while index < data.count {
            guard let tag = readVarint(data, index: &index) else { break }
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)

            switch wireType {
            case 0:
                guard readVarint(data, index: &index) != nil else { return fields }

            case 1:
                guard index + 8 <= data.count else { return fields }
                index += 8

            case 2:
                guard let rawLength = readVarint(data, index: &index),
                      rawLength <= UInt64(data.count - index) else { return fields }
                let length = Int(rawLength)
                if fieldNumber == wanted {
                    fields.append(data.subdata(in: index..<(index + length)))
                    if fields.count == limit { return fields }
                }
                index += length

            case 5:
                guard index + 4 <= data.count else { return fields }
                index += 4

            default:
                return fields
            }
        }

        return fields
    }

    private static func readVarint(_ data: Data, index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0

        while index < data.count && shift < 64 {
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return value
            }
            shift += 7
        }

        return nil
    }

    // MARK: - Content item updates

    /// Merge an update into a cached item only when identity is already known to
    /// be the same. Protobuf merge semantics preserve fields omitted by partial
    /// tvOS updates while replacing fields explicitly present in the update.
    /// This prevents ad/recap timing updates from erasing episode metadata.
    private func mergedContentItem(_ update: MRP_ContentItem, with existing: MRP_ContentItem) -> MRP_ContentItem {
        guard let serialized = try? update.serializedData(partial: true) else { return update }
        var merged = existing
        do {
            try merged.merge(serializedData: serialized, partial: true)
            return merged
        } catch {
            log.warning("MRP content-item merge failed; using incoming snapshot")
            return update
        }
    }

    private func mergeWithCachedItemIfSame(_ item: MRP_ContentItem) -> MRP_ContentItem {
        guard item.hasIdentifier, !item.identifier.isEmpty,
              let existing = contentItems.first(where: {
                  $0.hasIdentifier && $0.identifier == item.identifier
              }) else {
            return item
        }
        return mergedContentItem(item, with: existing)
    }

    private func applyPlaybackQueue(_ queue: MRP_PlaybackQueue) {
        // Session changes clear contentItems before a new queue is accepted, so
        // merging by item identifier here can never carry metadata across an app
        // or player boundary. New identifiers always start from the incoming item.
        contentItems = queue.contentItems.map { mergeWithCachedItemIfSame($0) }
        queueLocation = queue.hasLocation ? queue.location : 0
    }

    private func handleUpdateContentItem(_ message: MRP_ProtocolMessage) {
        guard message.hasMRP_updateContentItemMessage else { return }
        let update = message.MRP_updateContentItemMessage
        let bundleID = bundleIdentifier(from: update)
        let playerID = playerIdentifier(from: update)

        if let bundleID, !currentOwnerMatches(bundleID: bundleID, playerID: playerID) {
            return
        }

        var updatedQueue = false
        for item in update.contentItems {
            guard item.hasIdentifier, !item.identifier.isEmpty,
                  let idx = contentItems.firstIndex(where: { $0.hasIdentifier && $0.identifier == item.identifier })
            else { continue }
            contentItems[idx] = mergedContentItem(item, with: contentItems[idx])
            updatedQueue = true
        }

        // An item update describes an existing queue entry. A late push can
        // arrive after the queue was cleared or its player was removed.
        guard updatedQueue else { return }
        updateNowPlayingFromContentItems()
        maybeAutoSkipOpeningContent()
    }

    // MARK: - Playback queue request

    /// Request the playback queue with artwork, guarded to prevent concurrent requests.
    private func requestArtworkIfNeeded() {
        guard !artworkRequestPending else {
            log.info("[ART] request skipped, already pending")
            return
        }
        sendPlaybackQueueRequest()
    }

    private func sendPlaybackQueueRequest() {
        var request = MRP_PlaybackQueueRequestMessage()
        request.location = 0
        request.length = 1
        request.includeMetadata = true
        request.artworkWidth = 600
        request.artworkHeight = 600
        request.returnContentItemAssetsInUserCompletion = true

        var msg = MRP_ProtocolMessage()
        msg.type = .playbackQueueRequestMessage
        msg.MRP_playbackQueueRequestMessage = request

        playbackQueueRequestGeneration &+= 1
        let generation = playbackQueueRequestGeneration
        artworkRequestPending = true
        sendAndReceive(&msg) { [weak self] response in
            guard let self else { return }
            guard self.playbackQueueRequestGeneration == generation else { return }
            self.artworkRequestPending = false
            guard let response, response.hasMRP_setStateMessage else { return }
            self.handleSetState(response)
        }
    }

    /// Build NowPlayingState from the current content item in the playback queue.
    private func updateNowPlayingFromContentItems() {
        guard currentPlaybackState != .stopped, !contentItems.isEmpty else {
            clearDisplayedNowPlaying()
            return
        }

        let index = Int(queueLocation)
        let item = index < contentItems.count ? contentItems[index] : contentItems[0]

        guard item.hasMetadata else {
            clearDisplayedNowPlaying()
            return
        }

        let meta = item.metadata
        // Textual metadata is optional in normal MRP playback updates. Infuse,
        // for example, can publish a live queue item with timing/playback data
        // while temporarily omitting title/artist/album. Do not translate that
        // valid media state into "Nothing Playing" merely because text is absent.
        let hasTextContent =
            meta.hasTitle ||
            meta.hasTrackArtistName ||
            meta.hasAlbumName ||
            meta.hasSubtitle
        let hasPlaybackContent =
            meta.hasDuration ||
            meta.hasElapsedTime ||
            meta.hasPlaybackRate ||
            item.hasArtworkData
        let hasContent = hasTextContent || hasPlaybackContent

        let itemID = item.hasIdentifier && !item.identifier.isEmpty ? item.identifier : nil
        let wasPresented = itemID != nil && itemID == currentContentIdentifier
        let hasProgress = meta.hasElapsedTime && meta.elapsedTime.isFinite && meta.elapsedTime > 0
        let hasActiveRate = currentPlaybackState != .paused
            && meta.hasPlaybackRate && meta.playbackRate.isFinite && meta.playbackRate > 0

        // Browsing can publish a title and duration before a player starts.
        // A real item remains visible when paused, including at the first frame.
        guard hasContent, currentPlaybackState == .playing || currentPlaybackState == .seeking
                || wasPresented || hasProgress || hasActiveRate else {
            clearDisplayedNowPlaying()
            return
        }

        let contentChanged = itemID != currentContentIdentifier
        currentContentIdentifier = itemID

        if contentChanged {
            artworkUnavailable = false
        }

        let playbackRate = currentPlaybackState == .paused
            ? 0 : (meta.hasPlaybackRate ? meta.playbackRate : (self.nowPlaying?.playbackRate ?? 0))

        // elapsedTimeTimestamp is in Cocoa epoch (Jan 1, 2001)
        let timestamp: Date
        if meta.hasElapsedTimeTimestamp, meta.elapsedTimeTimestamp > 0 {
            let cocoaReferenceDate = Date(timeIntervalSince1970: 978_307_200) // Jan 1, 2001
            timestamp = cocoaReferenceDate.addingTimeInterval(meta.elapsedTimeTimestamp)
        } else {
            timestamp = Date()
        }

        // Only carry forward artwork if the content item hasn't changed
        let artworkData: Data?
        if item.hasArtworkData {
            artworkData = item.artworkData
            artworkUnavailable = false
            log.info("[ART] has artworkData (\(item.artworkData.count) bytes) contentChanged=\(contentChanged)")
        } else if contentChanged {
            artworkData = nil
            log.info("[ART] content changed, no artwork yet (id=\(itemID ?? "nil"))")
        } else {
            artworkData = self.nowPlaying?.artworkData
            if artworkData == nil {
                artworkUnavailable = true
                log.info("[ART] no artwork, marking unavailable (id=\(itemID ?? "nil"))")
            } else {
                log.info("[ART] carried forward existing artwork (\(artworkData!.count) bytes)")
            }
        }

        let needsArtwork = artworkData == nil && !artworkUnavailable
        let supplemental = supplementalMediaMetadata(from: meta)
        log.info("[ART] needsArtwork=\(needsArtwork) artworkUnavailable=\(self.artworkUnavailable) pending=\(self.artworkRequestPending)")

        DispatchQueue.main.async {
            self.nowPlayingSeriesName = supplemental.seriesName
            self.nowPlayingSeasonNumber = supplemental.seasonNumber
            self.nowPlayingEpisodeNumber = supplemental.episodeNumber
            self.nowPlayingEpisodeTitle = supplemental.episodeTitle

            self.nowPlaying = NowPlayingState(
                title: meta.hasTitle ? meta.title : nil,
                artist: meta.hasTrackArtistName ? meta.trackArtistName : (meta.hasSubtitle ? meta.subtitle : nil),
                album: meta.hasAlbumName ? meta.albumName : nil,
                duration: meta.hasDuration ? meta.duration : nil,
                elapsedTime: meta.hasElapsedTime ? meta.elapsedTime : nil,
                playbackRate: playbackRate,
                timestamp: timestamp,
                artworkData: artworkData
            )
            if needsArtwork {
                log.info("[ART] requesting artwork")
                self.requestArtworkIfNeeded()
            }
        }
    }
}
