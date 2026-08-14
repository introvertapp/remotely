import AppKit
import SwiftUI

struct MiniRemoteView: View {
    @ObservedObject var service: AppleTVService

    private var state: RemoteNowPlaying? { service.nowPlaying }

    var body: some View {
        HStack(spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    AppleTVLogoTile(size: 24, selected: false, cornerRadius: 6)

                    Text(service.remoteDeviceName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .lineLimit(1)

                    Spacer(minLength: 8)
                }
                .frame(height: 26)

                Spacer().frame(height: 5)

                NowPlayingMetadata(state: state)
                    .frame(height: 56, alignment: .topLeading)

                Spacer().frame(height: 5)

                NowPlayingTimeline(
                    position: state?.position ?? 0,
                    duration: state?.duration ?? 0,
                    enabled: state != nil && (state?.duration ?? 0) > 0,
                    onSeek: service.seek(to:)
                )
                .frame(height: 24)

                Spacer().frame(height: 11)

                controls
                    .frame(height: 38)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .frame(width: AppConstants.miniRemoteWidth, height: AppConstants.miniRemoteHeight)
        .background(AppConstants.remoteBackground)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var artwork: some View {
        if let data = state?.artworkData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 82, height: 166)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppConstants.controlBackground)
                .overlay {
                    Image(systemName: "tv.fill")
                        .font(.system(size: 23, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.28))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppConstants.controlBorder, lineWidth: 0.8)
                }
                .frame(width: 82, height: 166)
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            miniButton(
                symbol: "speaker.wave.1.fill",
                label: "Volume Down",
                enabled: service.isConnected,
                action: service.volumeDown
            )

            Spacer(minLength: 0)

            miniButton(
                symbol: "gobackward.10",
                label: "Rewind 10 Seconds",
                enabled: state != nil && service.canSkipBackward,
                action: service.rewind10
            )

            Spacer(minLength: 0)

            miniButton(
                symbol: state?.isPlaying == true ? "pause.fill" : "play.fill",
                label: state?.isPlaying == true ? "Pause" : "Play",
                enabled: state != nil,
                glyphSize: 18,
                action: service.playPause
            )

            Spacer(minLength: 0)

            miniButton(
                symbol: "goforward.10",
                label: "Forward 10 Seconds",
                enabled: state != nil && service.canSkipForward,
                action: service.forward10
            )

            Spacer(minLength: 0)

            miniButton(
                symbol: "speaker.wave.3.fill",
                label: "Volume Up",
                enabled: service.isConnected,
                action: service.volumeUp
            )
        }
        .frame(height: 34)
    }

    private func miniButton(
        symbol: String,
        label: String,
        enabled: Bool,
        glyphSize: CGFloat = 16,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.24))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
