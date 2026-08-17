import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var service: AppleTVService
    @State private var pin = ""
    @State private var pinSubmitted = false
    @State private var showingRemovePairingConfirmation = false
    @AppStorage(AppConstants.fetchAppArtworkDefaultsKey) private var fetchAppArtwork = false
    @FocusState private var pinFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
            Text("Preferences")
                .font(.system(size: 16, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.top, 22)

            devicePicker
                .padding(.top, 28)

            HStack(spacing: 14) {
                preferencesButton("Scan") { service.scan() }
                preferencesButton(
                    "Connect",
                    disabled: !service.canConnectSelectedDevice
                ) { service.connectSelected() }
                preferencesButton(
                    "Pair…",
                    disabled: !service.canPairSelectedDevice
                ) { service.pairSelected() }
            }
            .padding(.top, 12)

            Text(service.selectedDeviceStatusText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                .padding(.top, 12)

            if service.isPairing {
                pairingSection
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Text("Pairing Data")
                .font(.system(size: 14, weight: .bold))
                .padding(.top, service.isPairing ? 26 : 8)

            Button(role: .destructive) {
                showingRemovePairingConfirmation = true
            } label: {
                Text("Remove Paired Device")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PreferencesDestructiveButtonStyle())
            .disabled(!service.canRemoveSelectedPairing)
            .padding(.top, 10)

            Text("Removes pairing credentials only for the selected Apple TV.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            Text("General")
                .font(.system(size: 14, weight: .bold))
                .padding(.top, 24)

            preferenceToggle("Allow window dragging from top edge", isOn: $model.allowPanelDragging)
                .padding(.top, 10)

            preferenceToggle("Always on top", isOn: $model.alwaysOnTop)
                .padding(.top, 8)

            preferenceToggle(
                "Launch remotely at login",
                isOn: Binding(
                    get: { model.launchAtLoginRequested },
                    set: { model.setLaunchAtLogin($0) }
                )
            )
            .padding(.top, 8)

            if let launchStatus = model.launchAtLoginStatusText {
                Text(launchStatus)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            }

            preferenceToggle("Show Now Playing", isOn: $model.showNowPlaying)
                .padding(.top, 8)

            preferenceToggle("Auto-skip tv ads and pre-roll sequences", isOn: $model.autoSkipOpeningContent)
                .padding(.top, 8)

            preferenceToggle("Use MiniRemote", isOn: $model.useMiniRemote)
                .padding(.top, 8)

            Text("Apps")
                .font(.system(size: 14, weight: .bold))
                .padding(.top, 24)

            preferenceToggle("Fetch app artwork from App Store", isOn: $fetchAppArtwork)
                .padding(.top, 10)

            Text("Uses Apple’s App Store lookup API for app artwork. Disabled by default; when off, remotely makes no App Store artwork requests.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)

                }
                .padding(.horizontal, 18)
            }

            Text(versionLabel)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Color.secondary.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 14)
        }
        .frame(width: AppConstants.panelWidth, height: AppConstants.panelHeight)
        .background(AppConstants.remoteBackground)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.16), value: service.isPairing)
        .confirmationDialog(
            "Remove paired device?",
            isPresented: $showingRemovePairingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Pairing", role: .destructive) {
                service.removeSelectedPairedDevice()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes pairing credentials for the selected Apple TV only. Other paired Apple TVs are not affected.")
        }
        .onAppear {
            // AppleTVService keeps Bonjour discovery running continuously, and
            // AppModel refreshes Login Items state at initialization and after
            // every toggle. Avoid restarting discovery and republishing model
            // state while this card is being introduced by the 3D flip.
            if service.isPairing {
                preparePINEntry()
            }
        }
        .onChange(of: service.isPairing) { _, pairing in
            if pairing {
                preparePINEntry()
            } else {
                pinFieldFocused = false
                pinSubmitted = false
                pin = ""
            }
        }
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return version.isEmpty ? "remotely" : "remotely v\(version)"
    }

    private var devicePicker: some View {
        Group {
            if service.devices.isEmpty {
                VStack(spacing: 8) {
                    AppleTVLogoTile(size: 72, selected: false)
                        .opacity(0.55)

                    Text("No Apple TVs found")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 96)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(service.devices) { device in
                            deviceButton(device)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    private func deviceButton(_ device: RemoteDevice) -> some View {
        let isSelected = service.selectedDeviceID == device.id

        return Button {
            service.chooseDevice(device.id)
        } label: {
            VStack(spacing: 7) {
                AppleTVLogoTile(size: 72, selected: isSelected)

                Text(device.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 92)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(device.name) Apple TV")
        .accessibilityValue(isSelected ? "Selected" : "")
        .help(device.host)
    }


    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pairing")
                .font(.system(size: 14, weight: .bold))
                .padding(.top, 3)

            Text("Enter the 4-digit code shown on Apple TV.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 5)

            pinEntry
                .padding(.top, 14)
        }
    }

    private var pinEntry: some View {
        ZStack {
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { index in
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AppConstants.controlBackground)
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        index == min(pin.count, 3)
                                            ? Color.white.opacity(0.72)
                                            : AppConstants.controlBorder,
                                        lineWidth: index == min(pin.count, 3) ? 1.5 : 0.8
                                    )
                            }

                        Text(digit(at: index))
                            .font(.system(size: 30, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 66, height: 68)
                }
            }

            TextField("", text: $pin)
                .textFieldStyle(.plain)
                .focused($pinFieldFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .onChange(of: pin) { _, newValue in
                    handlePINChange(newValue)
                }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            pinFieldFocused = true
        }
    }

    private func digit(at index: Int) -> String {
        guard index < pin.count else { return "" }
        let stringIndex = pin.index(pin.startIndex, offsetBy: index)
        return String(pin[stringIndex])
    }

    private func handlePINChange(_ value: String) {
        let sanitized = String(value.filter(\.isNumber).prefix(4))
        if sanitized != value {
            pin = sanitized
            return
        }

        guard service.isPairing else { return }
        if sanitized.count < 4 {
            pinSubmitted = false
            return
        }
        guard sanitized.count == 4, !pinSubmitted else { return }

        pinSubmitted = true
        pinFieldFocused = false
        service.submitPIN(sanitized)
    }

    private func preparePINEntry() {
        pin = ""
        pinSubmitted = false
        DispatchQueue.main.async {
            pinFieldFocused = true
        }
    }

    private func preferenceToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }

    private func preferencesButton(
        _ title: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(PreferencesButtonStyle())
            .frame(maxWidth: .infinity)
            .disabled(disabled)
    }
}

private struct PreferencesButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(isEnabled ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed && isEnabled ? AppConstants.controlHighlight : AppConstants.controlBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppConstants.controlBorder, lineWidth: 0.8)
                    }
            }
    }
}

private struct PreferencesDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? AppConstants.controlHighlight : AppConstants.controlBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(isEnabled ? Color.red.opacity(0.45) : AppConstants.controlBorder, lineWidth: 0.8)
                    }
            }
    }
}
