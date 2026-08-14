import SwiftUI

/// A single-line label that remains completely static when it fits and gently
/// pans only when its intrinsic width exceeds the space offered by its parent.
/// The full string remains in the view hierarchy for accessibility.
struct OverflowMarqueeText: View {
    let text: String
    let font: Font
    let color: Color

    @State private var measuredTextWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let travel = max(0, measuredTextWidth - geometry.size.width)
            let animationID = "\(text)|\(Int(travel.rounded()))"

            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background {
                    GeometryReader { textGeometry in
                        Color.clear.preference(
                            key: MarqueeTextWidthKey.self,
                            value: textGeometry.size.width
                        )
                    }
                }
                .offset(x: offset)
                .frame(width: geometry.size.width, alignment: .leading)
                .clipped()
                .task(id: animationID) {
                    await runMarquee(travel: travel)
                }
        }
        .onPreferenceChange(MarqueeTextWidthKey.self) { width in
            measuredTextWidth = width
        }
    }

    @MainActor
    private func runMarquee(travel: CGFloat) async {
        offset = 0
        guard travel > 1 else { return }

        // Keep a readable, nearly constant travel speed while bounding very
        // short/long titles to sensible animation durations.
        let duration = max(2.0, min(9.0, Double(travel) / 24.0))

        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(900))
                withAnimation(.linear(duration: duration)) {
                    offset = -travel
                }

                try await Task.sleep(for: .seconds(duration + 1.0))
                withAnimation(.linear(duration: duration)) {
                    offset = 0
                }

                try await Task.sleep(for: .seconds(duration + 1.0))
            }
        } catch {
            // Cancellation is expected when the title, available width, or
            // containing card changes. The next task always restarts at x = 0.
            offset = 0
        }
    }
}

private struct MarqueeTextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
