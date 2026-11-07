import SwiftUI

/// Shared metadata presentation used by both the full Remote and MiniRemote so
/// title hierarchy and overflow behavior cannot drift between the two layouts.
struct NowPlayingMetadata: View {
    let state: RemoteNowPlaying?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state?.title ?? (state == nil ? "Nothing Playing" : "Now Playing"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(state == nil ? Color.white.opacity(0.38) : .white)
                .lineLimit(1)
                .truncationMode(.tail)

            if let seasonEpisode = state?.seasonEpisode, !seasonEpisode.isEmpty {
                Text(seasonEpisode)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.52))
                    .lineLimit(1)
            }

            if let episodeTitle = state?.episodeTitle, !episodeTitle.isEmpty {
                OverflowMarqueeText(
                    text: episodeTitle,
                    font: .system(size: 11.5, weight: .regular),
                    color: Color.white.opacity(0.72)
                )
                .frame(height: 15)
            }
        }
    }
}

/// Shared, progress-only playback timeline. The fixed-size time labels are the
/// MiniRemote geometry that already accommodates hour-long values such as
/// `-1:07:38` without wrapping. Both Remote presentations use this exact view.
struct NowPlayingTimeline: View {
    let position: TimeInterval
    let duration: TimeInterval
    let enabled: Bool
    let onSeek: (TimeInterval) -> Void

    @State private var isDragging = false
    @State private var dragPosition: TimeInterval = 0
    @State private var pendingSeekTarget: TimeInterval?

    private var displayPosition: TimeInterval {
        if isDragging { return dragPosition }
        if let pendingSeekTarget { return pendingSeekTarget }
        return min(max(0, position), max(0, duration))
    }

    private var progress: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, displayPosition / duration)))
    }

    private var remaining: TimeInterval {
        max(0, duration - displayPosition)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(enabled ? Self.timeString(displayPosition) : "--:--")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 46, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 4)

                    Capsule()
                        .fill(Color.white.opacity(enabled ? 0.72 : 0.18))
                        .frame(width: geometry.size.width * progress, height: 4)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            guard enabled, duration > 0, geometry.size.width > 0 else { return }
                            isDragging = true
                            let fraction = max(0, min(1, value.location.x / geometry.size.width))
                            dragPosition = fraction * duration
                        }
                        .onEnded { value in
                            guard enabled, duration > 0, geometry.size.width > 0 else {
                                isDragging = false
                                return
                            }
                            let fraction = max(0, min(1, value.location.x / geometry.size.width))
                            let target = fraction * duration
                            dragPosition = target
                            pendingSeekTarget = target
                            isDragging = false
                            onSeek(target)
                        }
                )
            }
            .frame(height: 16)

            Text(enabled ? "-\(Self.timeString(remaining))" : "--:--")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .frame(height: 24)
        .onChange(of: position) { _, newPosition in
            guard let target = pendingSeekTarget else { return }
            if abs(newPosition - target) <= 3.0 {
                pendingSeekTarget = nil
            }
        }
        .onChange(of: duration) { _, newDuration in
            if newDuration <= 0 {
                isDragging = false
                pendingSeekTarget = nil
            }
        }
    }

    private static func timeString(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let remainingSeconds = value % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}
