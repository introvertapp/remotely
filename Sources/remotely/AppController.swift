import AppKit
import Combine
import SwiftUI

final class RemotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let remoteService = AppleTVService()
    private lazy var model = AppModel(remote: remoteService)

    private var statusItem: NSStatusItem!
    private var panel: RemotePanel!
    private var contextMenu: NSMenu!
    private var applicationMiniRemoteMenuItem: NSMenuItem?
    private var contextMiniRemoteMenuItem: NSMenuItem?
    private var applicationAlwaysOnTopMenuItem: NSMenuItem?
    private var contextAlwaysOnTopMenuItem: NSMenuItem?
    private var panelPresented = false
    private var pairingPresentationCancellable: AnyCancellable?

    private var mainPanelUserPositioned = false
    private var updatingMainPanelFrame = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildApplicationMenu()
        buildStatusItem()
        buildPanel()
        installPanelGeometryUpdates()
        installPairingPresentation()
        applyMainPanelDragging(model.allowPanelDragging)
        applyAlwaysOnTop(model.alwaysOnTop)
        updateMiniRemoteMenuState()
        updateAlwaysOnTopMenuState()

        if !remoteService.hasConfiguredDevice {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.model.mode = .preferences
                self.showPanel()
            }
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Default behavior remains menu-bar transient. Always-on-top mode is
        // explicitly persistent and therefore survives application deactivation.
        guard panel != nil, !model.alwaysOnTop else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        }
        panelPresented = false
        updateRemotePresentationState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        remoteService.setMiniRemotePresentation(isVisible: false)
        remoteService.shutdown()
    }

    func windowDidMove(_ notification: Notification) {
        guard
            let movedWindow = notification.object as? NSWindow,
            movedWindow === panel,
            model.allowPanelDragging,
            panelPresented,
            !updatingMainPanelFrame
        else { return }

        mainPanelUserPositioned = true
    }

    private func installPanelGeometryUpdates() {
        remoteService.onKeyboardInputVisibilityChanged = { [weak self] _ in
            guard let self, self.panelPresented else { return }
            self.updateRemotePresentationState()
            self.updatePanelGeometry()
        }

        model.onModeChanged = { [weak self] newMode in
            guard let self else { return }
            self.updateRemotePresentationState()
            guard self.panelPresented else { return }

            // Grow either dimension before a flip so the destination face
            // cannot be clipped. Never mutate the NSPanel frame at the 3D
            // face-swap midpoint: forcing AppKit to redisplay the hosting view
            // there interrupts SwiftUI's rotation, especially when Preferences
            // is the incoming face. Collapse to the exact destination size only
            // after both 0.17-second halves have completed.
            let targetWidth = self.desiredPanelWidth
            let targetHeight = self.desiredPanelHeight
            let transitionWidth = max(self.panel.frame.width, targetWidth)
            let transitionHeight = max(self.panel.frame.height, targetHeight)
            if transitionWidth != self.panel.frame.width || transitionHeight != self.panel.frame.height {
                self.setPanelGeometry(width: transitionWidth, height: transitionHeight)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
                guard let self, self.panelPresented, self.model.mode == newMode else { return }
                self.updatePanelGeometry()
            }
        }

        model.onPanelDraggingChanged = { [weak self] enabled in
            self?.applyMainPanelDragging(enabled)
        }

        model.onShowNowPlayingChanged = { [weak self] _ in
            guard let self else { return }
            self.updateRemotePresentationState()
            guard self.panelPresented, self.model.mode == .remote, !self.presentingMiniRemote else { return }
            self.updatePanelGeometry()
        }

        model.onMiniRemoteModeChanged = { [weak self] _ in
            guard let self else { return }
            self.updateMiniRemoteMenuState()
            self.updateRemotePresentationState()
            guard self.panelPresented, self.model.mode == .remote else { return }
            self.updatePanelGeometry()
        }

        model.onAlwaysOnTopChanged = { [weak self] enabled in
            guard let self else { return }
            self.applyAlwaysOnTop(enabled)
            self.updateAlwaysOnTopMenuState()
            if enabled && !self.panelPresented {
                self.model.mode = .remote
                self.showPanel()
            }
        }
    }

    private func installPairingPresentation() {
        pairingPresentationCancellable = remoteService.$isPairing
            .removeDuplicates()
            .sink { [weak self] pairing in
                guard pairing else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.remoteService.isPairing else { return }
                    self.model.mode = .preferences
                    self.showPanel()
                }
            }
    }

    /// Install a conventional application menu even though remotely is an
    /// LSUIElement/accessory app. AppKit routes the command-key equivalents
    /// through this menu while the application is active.
    private func buildApplicationMenu() {
        let mainMenu = NSMenu(title: "Main Menu")
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: "remotely")

        let remote = NSMenuItem(
            title: "Remote",
            action: #selector(openRemoteFromMenu(_:)),
            keyEquivalent: "r"
        )
        remote.keyEquivalentModifierMask = [.command]
        remote.target = self
        appMenu.addItem(remote)

        let apps = NSMenuItem(
            title: "Apps",
            action: #selector(openAppsFromMenu(_:)),
            keyEquivalent: "a"
        )
        apps.keyEquivalentModifierMask = [.command]
        apps.target = self
        appMenu.addItem(apps)

        let miniRemote = makeMiniRemoteMenuItem()
        applicationMiniRemoteMenuItem = miniRemote
        appMenu.addItem(miniRemote)

        let alwaysOnTop = makeAlwaysOnTopMenuItem()
        applicationAlwaysOnTopMenuItem = alwaysOnTop
        appMenu.addItem(alwaysOnTop)

        let preferences = NSMenuItem(
            title: "Preferences…",
            action: #selector(openPreferencesFromMenu(_:)),
            keyEquivalent: ","
        )
        preferences.keyEquivalentModifierMask = [.command]
        preferences.target = self
        appMenu.addItem(preferences)
        appMenu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit remotely",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        appMenu.addItem(quit)

        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = makeRemoteIcon()
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let menu = NSMenu(title: "remotely")

        let remote = NSMenuItem(
            title: "Remote",
            action: #selector(openRemoteFromMenu(_:)),
            keyEquivalent: "r"
        )
        remote.keyEquivalentModifierMask = [.command]
        remote.target = self
        menu.addItem(remote)

        let apps = NSMenuItem(
            title: "Apps",
            action: #selector(openAppsFromMenu(_:)),
            keyEquivalent: "a"
        )
        apps.keyEquivalentModifierMask = [.command]
        apps.target = self
        menu.addItem(apps)

        let miniRemote = makeMiniRemoteMenuItem()
        contextMiniRemoteMenuItem = miniRemote
        menu.addItem(miniRemote)

        let alwaysOnTop = makeAlwaysOnTopMenuItem()
        contextAlwaysOnTopMenuItem = alwaysOnTop
        menu.addItem(alwaysOnTop)

        let preferences = NSMenuItem(
            title: "Preferences…",
            action: #selector(openPreferencesFromMenu(_:)),
            keyEquivalent: ","
        )
        preferences.keyEquivalentModifierMask = [.command]
        preferences.target = self
        menu.addItem(preferences)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit remotely",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)
        contextMenu = menu
    }

    private func makeMiniRemoteMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "MiniRemote",
            action: #selector(toggleMiniRemoteFromMenu(_:)),
            keyEquivalent: "m"
        )
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        item.state = model.useMiniRemote ? .on : .off
        return item
    }

    private func makeAlwaysOnTopMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Always on top",
            action: #selector(toggleAlwaysOnTopFromMenu(_:)),
            keyEquivalent: "t"
        )
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        item.state = model.alwaysOnTop ? .on : .off
        return item
    }

    private func buildPanel() {
        let root = PanelRootView(model: model)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: AppConstants.panelWidth, height: AppConstants.panelHeight)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = AppConstants.cornerRadius
        hosting.layer?.masksToBounds = true

        panel = RemotePanel(
            contentRect: NSRect(x: 0, y: 0, width: AppConstants.panelWidth, height: AppConstants.panelHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.delegate = self
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenuBelowStatusBar()
            return
        }

        if panelPresented {
            if model.alwaysOnTop {
                // Persistent mode is dismissed only by turning the preference off.
                model.mode = .remote
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                hidePanel()
            }
            return
        }

        model.mode = .remote
        showPanel()
    }

    @objc private func openRemoteFromMenu(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model.mode = .remote
            self.showPanel()
        }
    }

    @objc private func openAppsFromMenu(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model.mode = .apps
            self.remoteService.refreshApps()
            self.showPanel()
        }
    }

    @objc private func openPreferencesFromMenu(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model.mode = .preferences
            self.showPanel()
        }
    }

    @objc private func toggleMiniRemoteFromMenu(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model.useMiniRemote.toggle()
        }
    }

    @objc private func toggleAlwaysOnTopFromMenu(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model.alwaysOnTop.toggle()
        }
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    private func showPanel() {
        guard let panel else { return }
        updatePanelGeometry()

        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        panelPresented = true
        updateRemotePresentationState()

        if model.mode == .remote {
            remoteService.refreshNowPlaying()
        }
    }

    private func hidePanel() {
        guard let panel else { return }
        panel.orderOut(nil)
        panelPresented = false
        updateRemotePresentationState()
    }

    private func updateRemotePresentationState() {
        let remoteVisible = panelPresented && model.mode == .remote
        remoteService.setRemotePresentation(
            isVisible: remoteVisible && !presentingMiniRemote && model.showNowPlaying
        )
        remoteService.setMiniRemotePresentation(
            isVisible: remoteVisible && presentingMiniRemote
        )
    }

    private func applyMainPanelDragging(_ enabled: Bool) {
        guard panel != nil else { return }
        applyEffectivePanelMovability()

        if !enabled {
            mainPanelUserPositioned = false
            if panelPresented {
                updatePanelGeometry()
            }
        }
    }

    private func applyEffectivePanelMovability() {
        // Window repositioning is intentionally limited to the explicit top
        // drag strip in PanelRootView. Background dragging would compete with
        // sliders, timelines, scroll views, buttons, and the clickpad.
        panel.isMovable = model.allowPanelDragging
        panel.isMovableByWindowBackground = false
    }

    private func applyAlwaysOnTop(_ enabled: Bool) {
        guard panel != nil else { return }
        // The panel already lives at status-bar level, above ordinary app windows.
        // Persistence only changes whether AppKit/application deactivation hides it.
        panel.level = .statusBar
        panel.hidesOnDeactivate = !enabled
    }

    private func updateMiniRemoteMenuState() {
        let state: NSControl.StateValue = model.useMiniRemote ? .on : .off
        applicationMiniRemoteMenuItem?.state = state
        contextMiniRemoteMenuItem?.state = state
    }

    private func updateAlwaysOnTopMenuState() {
        let state: NSControl.StateValue = model.alwaysOnTop ? .on : .off
        applicationAlwaysOnTopMenuItem?.state = state
        contextAlwaysOnTopMenuItem?.state = state
    }

    private func showContextMenuBelowStatusBar() {
        guard let button = statusItem.button else { return }
        updateMiniRemoteMenuState()
        updateAlwaysOnTopMenuState()

        DispatchQueue.main.async { [weak self, weak button] in
            guard let self, let button else { return }
            self.statusItem.menu = self.contextMenu
            button.performClick(nil)
            self.statusItem.menu = nil
        }
    }

    private var presentingMiniRemote: Bool {
        model.mode == .remote && model.useMiniRemote && !remoteService.keyboardInputRequested
    }

    private var desiredPanelWidth: CGFloat {
        presentingMiniRemote ? AppConstants.miniRemoteWidth : AppConstants.panelWidth
    }

    private var desiredPanelHeight: CGFloat {
        guard model.mode == .remote else { return AppConstants.panelHeight }
        if presentingMiniRemote { return AppConstants.miniRemoteHeight }
        return AppConstants.remotePanelHeight(
            showNowPlaying: model.showNowPlaying,
            keyboardVisible: remoteService.keyboardInputRequested
        )
    }

    private func updatePanelGeometry() {
        setPanelGeometry(width: desiredPanelWidth, height: desiredPanelHeight)
    }

    private func setPanelGeometry(width: CGFloat, height: CGFloat) {
        guard let panel else { return }

        let origin: NSPoint
        if model.allowPanelDragging && mainPanelUserPositioned {
            let topEdge = panel.frame.maxY
            origin = clampedOrigin(
                NSPoint(x: panel.frame.minX, y: topEdge - height),
                width: width,
                height: height,
                screen: panel.screen
            )
        } else {
            origin = anchoredPanelOrigin(width: width, height: height)
        }

        updatingMainPanelFrame = true
        panel.contentView?.layer?.cornerRadius = presentingMiniRemote
            ? AppConstants.miniRemoteCornerRadius
            : AppConstants.cornerRadius
        panel.setFrame(
            NSRect(
                x: origin.x,
                y: origin.y,
                width: width,
                height: height
            ),
            display: panel.isVisible,
            animate: false
        )
        updatingMainPanelFrame = false
    }

    private func anchoredPanelOrigin(width: CGFloat, height: CGFloat) -> NSPoint {
        guard
            let button = statusItem.button,
            let window = button.window
        else {
            return .zero
        }

        let buttonInWindow = button.convert(button.bounds, to: nil)
        let buttonOnScreen = window.convertToScreen(buttonInWindow)
        let proposed = NSPoint(
            x: buttonOnScreen.origin.x + (buttonOnScreen.width - width) / 2,
            y: buttonOnScreen.minY - height - AppConstants.panelGap
        )

        return clampedOrigin(proposed, width: width, height: height, screen: window.screen)
    }

    private func clampedOrigin(
        _ proposed: NSPoint,
        width: CGFloat,
        height: CGFloat,
        screen: NSScreen?
    ) -> NSPoint {
        guard let screen else {
            return NSPoint(x: proposed.x.rounded(), y: proposed.y.rounded())
        }

        let visible = screen.visibleFrame
        let x = max(visible.minX, min(proposed.x, visible.maxX - width))
        let y = max(visible.minY, min(proposed.y, visible.maxY - height))
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    private func makeRemoteIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let body = NSBezierPath(
                roundedRect: NSRect(x: 5, y: 1, width: 8, height: 16),
                xRadius: 2.6,
                yRadius: 2.6
            )
            body.lineWidth = 1.4
            body.stroke()

            let clickpad = NSBezierPath(ovalIn: NSRect(x: 7, y: 10.2, width: 4, height: 4))
            clickpad.lineWidth = 1.2
            clickpad.stroke()

            NSBezierPath(ovalIn: NSRect(x: 8.1, y: 4.2, width: 1.8, height: 1.8)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
