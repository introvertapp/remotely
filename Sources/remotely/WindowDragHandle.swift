import AppKit
import SwiftUI

/// A deliberately small drag surface for the borderless main panel.
///
/// NSWindow background dragging is disabled for the rest of the application so
/// interactive content never accidentally repositions the Remote. The blank
/// strip at the very top of every card is the one place that initiates an
/// AppKit window drag.
struct WindowDragHandle: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> DragHandleView {
        let view = DragHandleView()
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: DragHandleView, context: Context) {
        nsView.isEnabled = isEnabled
    }

    final class DragHandleView: NSView {
        var isEnabled = true

        override var acceptsFirstResponder: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled, let window else { return }
            window.performDrag(with: event)
        }
    }
}
