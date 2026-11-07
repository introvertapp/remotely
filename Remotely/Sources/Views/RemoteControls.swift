import SwiftUI

struct RemoteControlBackground<S: Shape>: ViewModifier {
    let shape: S
    let pressed: Bool
    let drawBackground: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if drawBackground {
                    shape
                        .fill(pressed ? AppConstants.controlHighlight : AppConstants.controlBackground)
                    shape
                        .stroke(AppConstants.controlBorder, lineWidth: 0.8)
                }
            }
    }
}

struct RemoteSymbolButton: View {
    let symbol: String
    let accessibilityLabel: String
    let glyphSize: CGFloat
    let size: CGSize
    var cornerRadius: CGFloat? = nil
    var drawBackground = true
    let action: () -> Void

    @GestureState private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($pressed) { _, state, _ in state = true }
        )
        .modifier(
            RemoteControlBackground(
                shape: RoundedRectangle(
                    cornerRadius: cornerRadius ?? min(size.width, size.height) / 2,
                    style: .continuous
                ),
                pressed: pressed,
                drawBackground: drawBackground
            )
        )
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Native long-press control. The long action fires at the threshold while the
/// mouse is still held down. Releasing after a long press never fires the short
/// action, matching the validated v0.9.4 behavior.
struct LongPressRemoteButton: View {
    let symbol: String
    let accessibilityLabel: String
    let glyphSize: CGFloat
    let size: CGSize
    var cornerRadius: CGFloat? = nil
    let shortAction: () -> Void
    let longAction: () -> Void

    @State private var isPressed = false
    @State private var longFired = false
    @State private var timerTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: glyphSize, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .background {
                let shape = RoundedRectangle(
                    cornerRadius: cornerRadius ?? min(size.width, size.height) / 2,
                    style: .continuous
                )
                shape.fill(isPressed ? AppConstants.controlHighlight : AppConstants.controlBackground)
                shape.stroke(AppConstants.controlBorder, lineWidth: 0.8)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        beginPressIfNeeded()
                    }
                    .onEnded { _ in
                        finishPress()
                    }
            )
            .onDisappear {
                cancelPress()
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel)
    }

    private func beginPressIfNeeded() {
        guard !isPressed else { return }
        isPressed = true
        longFired = false
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(AppConstants.longPressSeconds))
            guard !Task.isCancelled, isPressed, !longFired else { return }
            longFired = true
            longAction()
        }
    }

    private func finishPress() {
        guard isPressed else { return }
        timerTask?.cancel()
        timerTask = nil
        isPressed = false
        if !longFired {
            shortAction()
        }
        longFired = false
    }

    private func cancelPress() {
        timerTask?.cancel()
        timerTask = nil
        isPressed = false
        longFired = false
    }
}

enum ClickpadZone {
    case up, down, left, right, select
}

struct ClickpadSurface: View {
    let action: (ClickpadZone) -> Void
    @State private var isPressed = false

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: AppConstants.cornerRadius, style: .continuous)
                .fill(isPressed ? AppConstants.controlHighlight : AppConstants.controlBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: AppConstants.cornerRadius, style: .continuous)
                        .stroke(AppConstants.controlBorder, lineWidth: 0.8)
                }
                .contentShape(RoundedRectangle(cornerRadius: AppConstants.cornerRadius, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { _ in isPressed = true }
                        .onEnded { value in
                            isPressed = false
                            action(zone(for: value.location, size: geometry.size))
                        }
                )
        }
    }

    private func zone(for point: CGPoint, size: CGSize) -> ClickpadZone {
        let nx = (point.x - size.width / 2) / (size.width / 2)
        // SwiftUI's Y axis is top-down, unlike the old AppKit clickpad.
        let ny = -((point.y - size.height / 2) / (size.height / 2))

        if abs(nx) <= 0.34 && abs(ny) <= 0.30 {
            return .select
        }
        if abs(nx) > abs(ny) {
            return nx > 0 ? .right : .left
        }
        return ny > 0 ? .up : .down
    }
}
