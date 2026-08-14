import Foundation
import SwiftUI

struct PanelRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var remote: AppleTVService

    // Keep two face slots alive so the incoming card can be constructed and
    // laid out before the 3D rotation begins. This avoids doing the expensive
    // PreferencesView creation at the 90-degree midpoint of the flip.
    @State private var primaryMode: PanelMode
    @State private var secondaryMode: PanelMode?
    @State private var showingSecondary = false
    @State private var displayedMode: PanelMode
    @State private var flipDegrees: Double = 0
    @State private var isFlipping = false
    @State private var pendingMode: PanelMode?

    init(model: AppModel) {
        self.model = model
        _remote = ObservedObject(wrappedValue: model.remote)
        _primaryMode = State(initialValue: model.mode)
        _secondaryMode = State(initialValue: nil)
        _displayedMode = State(initialValue: model.mode)
    }

    var body: some View {
        ZStack {
            faceLayer(for: primaryMode, visible: !showingSecondary)

            if let secondaryMode {
                faceLayer(for: secondaryMode, visible: showingSecondary)
            }
        }
        .frame(
            width: preferredPanelWidth,
            height: preferredPanelHeight
        )
        .clipShape(
            RoundedRectangle(cornerRadius: preferredCornerRadius, style: .continuous)
        )
        .rotation3DEffect(
            .degrees(flipDegrees),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.72
        )
        .overlay(alignment: .top) {
            if model.allowPanelDragging {
                WindowDragHandle(isEnabled: !isFlipping)
                    .frame(height: AppConstants.windowDragHandleHeight)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: model.mode) { _, newMode in
            flip(to: newMode)
        }
    }

    private var shouldUseMiniRemote: Bool {
        model.useMiniRemote && !remote.keyboardInputRequested
    }

    private var presentingMiniRemote: Bool {
        displayedMode == .remote && shouldUseMiniRemote
    }

    private var preferredPanelWidth: CGFloat {
        presentingMiniRemote ? AppConstants.miniRemoteWidth : AppConstants.panelWidth
    }

    private var preferredPanelHeight: CGFloat {
        guard displayedMode == .remote else { return AppConstants.panelHeight }
        if presentingMiniRemote { return AppConstants.miniRemoteHeight }
        return AppConstants.remotePanelHeight(
            showNowPlaying: model.showNowPlaying,
            keyboardVisible: remote.keyboardInputRequested
        )
    }

    private var preferredCornerRadius: CGFloat {
        presentingMiniRemote ? AppConstants.miniRemoteCornerRadius : AppConstants.cornerRadius
    }

    @ViewBuilder
    private func faceLayer(for mode: PanelMode, visible: Bool) -> some View {
        let interactive = visible && !isFlipping

        panelFace(for: mode, interactive: interactive)
            // A tiny non-zero opacity keeps the hidden destination renderable so
            // AppKit/SwiftUI can prepare its backing content before the flip.
            // It remains visually imperceptible and cannot receive input.
            .opacity(visible ? 1 : 0.001)
            .allowsHitTesting(interactive)
            .accessibilityHidden(!visible)
            .compositingGroup()
    }

    @ViewBuilder
    private func panelFace(for mode: PanelMode, interactive: Bool) -> some View {
        switch mode {
        case .remote:
            if shouldUseMiniRemote {
                MiniRemoteView(service: model.remote)
            } else {
                // Keyboard Search temporarily uses the full Remote even when
                // MiniRemote is preferred, so live tvOS text input is never lost.
                RemoteView(
                    service: model.remote,
                    showNowPlaying: model.showNowPlaying,
                    clickpadInputEnabled: interactive
                )
            }
        case .apps:
            AppsView(service: model.remote)
        case .preferences:
            PreferencesView(model: model, service: model.remote)
        }
    }

    private func flip(to newMode: PanelMode) {
        guard newMode != displayedMode else { return }

        guard !isFlipping else {
            pendingMode = newMode
            return
        }

        isFlipping = true
        pendingMode = nil

        let sourceMode = displayedMode
        let direction: Double = newMode.rawValue > sourceMode.rawValue ? 1 : -1
        let halfDuration = 0.17
        let prewarmDelay = 0.04

        // Populate the currently hidden slot first. The short prewarm interval
        // gives SwiftUI at least a couple of display passes to construct/layout
        // a heavy destination such as Preferences before any rotation starts.
        var stagingTransaction = Transaction()
        stagingTransaction.disablesAnimations = true
        withTransaction(stagingTransaction) {
            if showingSecondary {
                primaryMode = newMode
            } else {
                secondaryMode = newMode
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + prewarmDelay) {
            withAnimation(.easeIn(duration: halfDuration)) {
                flipDegrees = 90 * direction
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + halfDuration) {
                // The incoming face is already mounted. At the edge-on point,
                // only swap visibility and reset the rotation origin; no new
                // card hierarchy is created here.
                var midpointTransaction = Transaction()
                midpointTransaction.disablesAnimations = true
                withTransaction(midpointTransaction) {
                    showingSecondary.toggle()
                    displayedMode = newMode
                    flipDegrees = -90 * direction
                }

                withAnimation(.easeOut(duration: halfDuration)) {
                    flipDegrees = 0
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + halfDuration) {
                    isFlipping = false

                    if let pending = pendingMode {
                        pendingMode = nil
                        if pending != displayedMode {
                            flip(to: pending)
                        }
                    }
                }
            }
        }
    }
}
