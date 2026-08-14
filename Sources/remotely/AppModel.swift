import Foundation
import ServiceManagement

enum PanelMode: Int, Equatable {
    case remote = 0
    case apps = 1
    case preferences = 2
}

@MainActor
final class AppModel: ObservableObject {
    private enum DefaultsKey {
        static let allowPanelDragging = "allowPanelDragging"
        static let showNowPlaying = "showNowPlaying"
        static let useMiniRemote = "useMiniRemote"
        static let alwaysOnTop = "alwaysOnTop"
        static let legacyMiniRemoteVisible = "miniRemoteVisible"
    }

    @Published var mode: PanelMode = .remote {
        didSet {
            guard mode != oldValue else { return }
            onModeChanged?(mode)
        }
    }

    @Published var allowPanelDragging: Bool {
        didSet {
            guard allowPanelDragging != oldValue else { return }
            defaults.set(allowPanelDragging, forKey: DefaultsKey.allowPanelDragging)
            onPanelDraggingChanged?(allowPanelDragging)
        }
    }

    @Published var showNowPlaying: Bool {
        didSet {
            guard showNowPlaying != oldValue else { return }
            defaults.set(showNowPlaying, forKey: DefaultsKey.showNowPlaying)
            onShowNowPlayingChanged?(showNowPlaying)
        }
    }

    @Published var useMiniRemote: Bool {
        didSet {
            guard useMiniRemote != oldValue else { return }
            defaults.set(useMiniRemote, forKey: DefaultsKey.useMiniRemote)
            defaults.removeObject(forKey: DefaultsKey.legacyMiniRemoteVisible)
            onMiniRemoteModeChanged?(useMiniRemote)
        }
    }

    @Published var alwaysOnTop: Bool {
        didSet {
            guard alwaysOnTop != oldValue else { return }
            defaults.set(alwaysOnTop, forKey: DefaultsKey.alwaysOnTop)
            onAlwaysOnTopChanged?(alwaysOnTop)
        }
    }

    @Published private(set) var launchAtLoginRequested = false
    @Published private(set) var launchAtLoginStatusText: String?

    let remote: AppleTVService

    /// AppController uses these callbacks to keep AppKit presentation state in
    /// sync without coupling SwiftUI views directly to NSWindow/NSPanel.
    var onModeChanged: ((PanelMode) -> Void)?
    var onPanelDraggingChanged: ((Bool) -> Void)?
    var onShowNowPlayingChanged: ((Bool) -> Void)?
    var onMiniRemoteModeChanged: ((Bool) -> Void)?
    var onAlwaysOnTopChanged: ((Bool) -> Void)?

    private let defaults = UserDefaults.standard

    init(remote: AppleTVService) {
        self.remote = remote

        if defaults.object(forKey: DefaultsKey.allowPanelDragging) == nil {
            allowPanelDragging = true
        } else {
            allowPanelDragging = defaults.bool(forKey: DefaultsKey.allowPanelDragging)
        }

        if defaults.object(forKey: DefaultsKey.showNowPlaying) == nil {
            showNowPlaying = true
        } else {
            showNowPlaying = defaults.bool(forKey: DefaultsKey.showNowPlaying)
        }

        if defaults.object(forKey: DefaultsKey.useMiniRemote) != nil {
            useMiniRemote = defaults.bool(forKey: DefaultsKey.useMiniRemote)
        } else {
            // Preserve the v1.9.30 preference while changing MiniRemote from a
            // second floating window into the primary Remote presentation.
            useMiniRemote = defaults.bool(forKey: DefaultsKey.legacyMiniRemoteVisible)
        }

        alwaysOnTop = defaults.bool(forKey: DefaultsKey.alwaysOnTop)
        refreshLaunchAtLoginStatus()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp

        do {
            if enabled {
                if service.status == .notRegistered || service.status == .notFound {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            launchAtLoginStatusText = "Could not update Login Items: \(error.localizedDescription)"
            refreshLaunchAtLoginStatus(preserveError: true)
            return
        }

        refreshLaunchAtLoginStatus()

        if service.status == .requiresApproval {
            launchAtLoginStatusText = "Approval is required in System Settings → Login Items."
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func refreshLaunchAtLoginStatus(preserveError: Bool = false) {
        let status = SMAppService.mainApp.status
        launchAtLoginRequested = status == .enabled || status == .requiresApproval

        guard !preserveError else { return }

        switch status {
        case .enabled:
            launchAtLoginStatusText = nil
        case .requiresApproval:
            launchAtLoginStatusText = "Approval is required in System Settings → Login Items."
        case .notRegistered:
            launchAtLoginStatusText = nil
        case .notFound:
            launchAtLoginStatusText = "macOS could not find remotely as a login item."
        @unknown default:
            launchAtLoginStatusText = nil
        }
    }
}
