import AppKit
import SwiftUI

struct RemoteView: View {
    @ObservedObject var service: AppleTVService
    let showNowPlaying: Bool
    let clickpadInputEnabled: Bool

    @State private var keyboardText = ""
    @State private var showingDeviceSelector = false
    @FocusState private var keyboardFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(width: AppConstants.panelContentWidth, height: 42)

            Spacer().frame(height: 14)

            if service.keyboardInputRequested {
                keyboardSearchField
                    .frame(width: AppConstants.panelContentWidth, height: 42)

                Spacer().frame(height: 8)
            }

            clickpad
                .frame(width: 316, height: 316)

            Spacer().frame(height: 14)

            bottomRow
                .frame(width: AppConstants.panelContentWidth, height: 83)

            if showNowPlaying {
                Spacer().frame(height: 10)

                NowPlayingBlock(service: service)
                    .frame(width: AppConstants.panelContentWidth, height: 190)
            }

            Spacer(minLength: 16)
        }
        .padding(.top, 14)
        .frame(
            width: AppConstants.panelWidth,
            height: AppConstants.remotePanelHeight(
                showNowPlaying: showNowPlaying,
                keyboardVisible: service.keyboardInputRequested
            ),
            alignment: .top
        )
        .background(AppConstants.remoteBackground)
        .preferredColorScheme(.dark)
        .onChange(of: service.keyboardInputRequested) { _, requested in
            if !requested {
                keyboardFieldFocused = false
                keyboardText = ""
            }
        }
    }

    private var keyboardSearchField: some View {
        TextField("Search", text: $keyboardText)
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(width: AppConstants.panelContentWidth, height: 42)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: AppConstants.cornerRadius, style: .continuous)
                        .fill(AppConstants.controlBackground)
                    RoundedRectangle(cornerRadius: AppConstants.cornerRadius, style: .continuous)
                        .stroke(AppConstants.controlBorder, lineWidth: 0.8)
                }
            }
            .focused($keyboardFieldFocused)
            .onChange(of: keyboardText) { _, text in
                service.updateKeyboardText(text)
            }
            .onSubmit {
                // Text is mirrored live through Companion RTI. Return is not a
                // submit/dismiss action; tvOS owns the keyboard lifetime.
                DispatchQueue.main.async {
                    keyboardFieldFocused = true
                }
            }
            .onAppear {
                keyboardText = ""
                DispatchQueue.main.async {
                    keyboardFieldFocused = true
                }
            }
            .accessibilityLabel("Apple TV search text")
    }

    private var header: some View {
        HStack(spacing: 8) {
            RemoteSymbolButton(
                symbol: "speaker.slash.fill",
                accessibilityLabel: "Mute",
                glyphSize: 15,
                size: CGSize(width: 42, height: 42),
                action: service.mute
            )

            Button {
                showingDeviceSelector.toggle()
            } label: {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)

                    HStack(spacing: 14) {
                        AppleTVLogoTile(size: 26, selected: false, cornerRadius: 7)

                        Text(service.remoteDeviceName)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)
                            .allowsTightening(true)
                            .layoutPriority(1)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.68))
                    }

                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
                .contentShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            }
            .buttonStyle(RemotePillButtonStyle(cornerRadius: 19))
            .accessibilityLabel("Select Apple TV")
            .popover(isPresented: $showingDeviceSelector, arrowEdge: .top) {
                RemoteDeviceSelector(
                    service: service,
                    isPresented: $showingDeviceSelector
                )
            }

            LongPressRemoteButton(
                symbol: "power",
                accessibilityLabel: "Power",
                glyphSize: 15.75,
                size: CGSize(width: 42, height: 42),
                shortAction: service.powerPress,
                longAction: service.powerHold
            )
        }
    }


    private var clickpad: some View {
        ZStack(alignment: .topLeading) {
            ClickpadSurface { zone in
                switch zone {
                case .up: service.up()
                case .down: service.down()
                case .left: service.left()
                case .right: service.right()
                case .select: service.select()
                }
            }


            // Trackpad and Magic Mouse swipes over the visible clickpad are
            // translated into the Apple TV's real-time touch stream. The
            // capture view does not participate in hit testing, so all of the
            // existing directional/select/volume click targets remain intact.
            ClickpadSwipeCapture(
                isEnabled: clickpadInputEnabled,
                onBegan: {
                    service.touchBegan(
                        referenceSize: CGSize(width: 316 * 1.5, height: 316 * 1.5)
                    )
                },
                onChanged: service.touchMoved(translation:),
                onEnded: service.touchEnded(translation:velocity:)
            )
            .frame(width: 316, height: 316)
            .allowsHitTesting(false)

            clickpadGlyph("chevron.up", size: 16.5)
                .frame(width: 44, height: 44)
                .position(x: 158, y: 34)
                .allowsHitTesting(false)

            clickpadGlyph("chevron.left", size: 16.5)
                .frame(width: 44, height: 44)
                .position(x: 40, y: 158)
                .allowsHitTesting(false)

            clickpadGlyph("chevron.right", size: 16.5)
                .frame(width: 44, height: 44)
                .position(x: 276, y: 158)
                .allowsHitTesting(false)

            clickpadGlyph("chevron.down", size: 16.5)
                .frame(width: 44, height: 44)
                .position(x: 158, y: 282)
                .allowsHitTesting(false)

            // Keep volume controls as independent buttons above the clickpad so
            // its gesture surface cannot intercept their clicks.
            RemoteSymbolButton(
                symbol: "speaker.wave.1.fill",
                accessibilityLabel: "Volume Down",
                glyphSize: 19,
                size: CGSize(width: 50, height: 50),
                cornerRadius: 16,
                drawBackground: false,
                action: service.volumeDown
            )
            .position(x: 39, y: 280)

            RemoteSymbolButton(
                symbol: "speaker.wave.3.fill",
                accessibilityLabel: "Volume Up",
                glyphSize: 19,
                size: CGSize(width: 50, height: 50),
                cornerRadius: 16,
                drawBackground: false,
                action: service.volumeUp
            )
            .position(x: 277, y: 280)
        }
    }

    private func clickpadGlyph(_ name: String, size: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(.white)
    }

    private var bottomRow: some View {
        HStack(spacing: 0) {
            LongPressRemoteButton(
                symbol: "playpause.fill",
                accessibilityLabel: "Play / Pause",
                glyphSize: 20.25,
                size: CGSize(width: 57, height: 57),
                shortAction: service.playPause,
                longAction: service.playPauseHold
            )

            Spacer(minLength: 0)

            RemoteSymbolButton(
                symbol: "chevron.backward",
                accessibilityLabel: "Back",
                glyphSize: 24.86,
                size: CGSize(width: 70.13, height: 70.13),
                action: service.back
            )

            Spacer(minLength: 0)

            LongPressRemoteButton(
                symbol: "tv",
                accessibilityLabel: "TV / Home",
                glyphSize: 20.25,
                size: CGSize(width: 57, height: 57),
                shortAction: service.home,
                longAction: service.homeHold
            )
        }
        .padding(.horizontal, 14)
    }
}

private struct RemoteDeviceSelector: View {
    @ObservedObject var service: AppleTVService
    @Binding var isPresented: Bool

    private var alphabeticalDevices: [RemoteDevice] {
        service.configuredDevices.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.host < $1.host : order == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if alphabeticalDevices.isEmpty {
                HStack(spacing: 10) {
                    AppleTVLogoTile(size: 34, selected: false, cornerRadius: 9)
                    Text("No configured Apple TVs")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
            } else {
                ScrollView(.vertical, showsIndicators: alphabeticalDevices.count > 5) {
                    VStack(spacing: 4) {
                        ForEach(alphabeticalDevices) { device in
                            deviceRow(device)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 246)
            }
        }
        .frame(width: 224)
        .background(AppConstants.remoteBackground)
        .preferredColorScheme(.dark)
    }

    private func deviceRow(_ device: RemoteDevice) -> some View {
        let selected = service.remoteDeviceID == device.id

        return Button {
            service.selectAndConnectDevice(device.id)
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                AppleTVLogoTile(size: 34, selected: selected, cornerRadius: 9)

                Text(device.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.72))
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 44)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(RemoteDeviceRowButtonStyle())
        .accessibilityLabel("Connect to \(device.name) Apple TV")
        .accessibilityValue(selected ? "Selected" : "")
        .help(device.host)
    }
}

private struct RemoteDeviceRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? AppConstants.controlHighlight : Color.clear)
            }
    }
}

private struct NowPlayingBlock: View {
    @ObservedObject var service: AppleTVService

    private var state: RemoteNowPlaying? { service.nowPlaying }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            artwork

            VStack(alignment: .leading, spacing: 0) {
                NowPlayingMetadata(state: state)
                    .frame(height: 56, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                Spacer(minLength: 0)

                NowPlayingTimeline(
                    position: state?.position ?? 0,
                    duration: state?.duration ?? 0,
                    enabled: state != nil && (state?.duration ?? 0) > 0,
                    onSeek: service.seek(to:)
                )
                .frame(height: 24)

                Spacer(minLength: 0)

                playbackControls
                    .frame(height: 38)
                    .frame(maxWidth: .infinity, alignment: .bottom)
            }
            .frame(height: 166)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppConstants.controlBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(AppConstants.controlBorder, lineWidth: 0.8)
                }
        }
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
                .fill(Color.white.opacity(0.055))
                .frame(width: 82, height: 166)
                .overlay {
                    Image(systemName: "tv.fill")
                        .font(.system(size: 25, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.28))
                }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 0) {
            mediaButton(
                symbol: "gobackward.10",
                label: "Rewind 10 Seconds",
                enabled: state != nil && service.canSkipBackward,
                size: 16,
                action: service.rewind10
            )

            Spacer()

            mediaButton(
                symbol: state?.isPlaying == true ? "pause.fill" : "play.fill",
                label: state?.isPlaying == true ? "Pause" : "Play",
                enabled: state != nil,
                size: 18,
                action: service.playPause
            )

            Spacer()

            mediaButton(
                symbol: "goforward.10",
                label: "Forward 10 Seconds",
                enabled: state != nil && service.canSkipForward,
                size: 16,
                action: service.forward10
            )
        }
    }

    private func mediaButton(
        symbol: String,
        label: String,
        enabled: Bool,
        size: CGFloat,
        buttonSize: CGFloat = 34,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.25))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

private struct RemotePillButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat = 25) {
        self.cornerRadius = cornerRadius
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? AppConstants.controlHighlight : AppConstants.controlBackground)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppConstants.controlBorder, lineWidth: 0.8)
            }
    }
}
