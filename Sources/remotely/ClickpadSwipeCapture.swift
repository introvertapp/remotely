import AppKit
import SwiftUI

/// Transparent AppKit bridge that interprets precise trackpad / Magic Mouse
/// scrolling over the remote clickpad as a continuous Apple TV touch gesture.
///
/// A local scroll-wheel monitor is intentional: using the responder chain would
/// make the gesture layer compete with the existing click targets. The SwiftUI
/// wrapper itself has hit testing disabled, while this monitor only claims
/// precise gestures whose pointer is over the clickpad.
struct ClickpadSwipeCapture: NSViewRepresentable {
    let isEnabled: Bool
    let onBegan: () -> Void
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint, CGPoint) -> Void

    func makeNSView(context: Context) -> ClickpadSwipeCaptureView {
        let view = ClickpadSwipeCaptureView()
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.setCaptureEnabled(isEnabled)
        return view
    }

    func updateNSView(_ nsView: ClickpadSwipeCaptureView, context: Context) {
        nsView.onBegan = onBegan
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
        nsView.setCaptureEnabled(isEnabled)
    }

    static func dismantleNSView(_ nsView: ClickpadSwipeCaptureView, coordinator: ()) {
        nsView.teardown()
    }
}

final class ClickpadSwipeCaptureView: NSView {
    var onBegan: (() -> Void)?
    var onChanged: ((CGPoint) -> Void)?
    var onEnded: ((CGPoint, CGPoint) -> Void)?

    /// Matches the starting feel of the reference implementation. This scales
    /// both travel and release velocity, keeping flick inertia proportional.
    private let sensitivity: CGFloat = 0.25

    private var eventMonitor: Any?
    private var captureEnabled = false
    private var gestureActive = false
    private var cumulativeTranslation: CGPoint = .zero
    private var releaseVelocity: CGPoint = .zero
    private var lastMoveTimestamp: TimeInterval = 0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && captureEnabled {
            installMonitorIfNeeded()
        } else {
            teardown()
        }
    }

    deinit {
        teardown()
    }

    func setCaptureEnabled(_ enabled: Bool) {
        guard captureEnabled != enabled else { return }
        captureEnabled = enabled

        if enabled {
            if window != nil {
                installMonitorIfNeeded()
            }
        } else {
            if gestureActive {
                endGesture()
            }
            teardown()
        }
    }

    func teardown() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        gestureActive = false
    }

    private func installMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScrollEvent(event) ?? event
        }
    }

    private func cursorIsOverClickpad(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let frameInWindow = convert(bounds, to: nil)
        return frameInWindow.contains(event.locationInWindow)
    }

    /// Returns nil when the clickpad owns this precise gesture; otherwise the
    /// original event is returned so ordinary scrolling elsewhere is untouched.
    private func handleScrollEvent(_ event: NSEvent) -> NSEvent? {
        guard captureEnabled else { return event }

        // Ignore traditional notched mouse wheels. Only high-resolution input
        // from a trackpad or Magic Mouse behaves like the Siri Remote surface.
        guard event.hasPreciseScrollingDeltas else { return event }
        guard gestureActive || cursorIsOverClickpad(event) else { return event }

        // `scrollingDelta*` follows the user's Natural Scrolling preference.
        // Remove that preference here so physical finger direction maps to the
        // Apple TV touch surface consistently on every Mac.
        let naturalDirection: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let dx = event.scrollingDeltaX * naturalDirection * sensitivity
        let dy = event.scrollingDeltaY * naturalDirection * sensitivity

        switch event.phase {
        case .began:
            beginGesture()
            applyDelta(dx: dx, dy: dy, timestamp: event.timestamp)

        case .changed:
            if !gestureActive {
                beginGesture()
            }
            applyDelta(dx: dx, dy: dy, timestamp: event.timestamp)

        case .ended, .cancelled:
            endGesture()

        default:
            // macOS sends momentum events after fingers lift. The Apple TV
            // protocol core performs its own inertia from release velocity, so
            // consume that momentum while the pointer remains over the pad.
            return cursorIsOverClickpad(event) ? nil : event
        }

        return nil
    }

    private func beginGesture() {
        gestureActive = true
        cumulativeTranslation = .zero
        releaseVelocity = .zero
        lastMoveTimestamp = 0
        onBegan?()
    }

    private func applyDelta(dx: CGFloat, dy: CGFloat, timestamp: TimeInterval) {
        guard gestureActive else { return }

        cumulativeTranslation.x += dx
        cumulativeTranslation.y += dy

        if lastMoveTimestamp > 0 {
            let elapsed = max(timestamp - lastMoveTimestamp, 1.0 / 1000.0)
            releaseVelocity = CGPoint(x: dx / elapsed, y: dy / elapsed)
        }

        lastMoveTimestamp = timestamp
        onChanged?(cumulativeTranslation)
    }

    private func endGesture() {
        guard gestureActive else { return }
        gestureActive = false
        onEnded?(cumulativeTranslation, releaseVelocity)
    }
}
