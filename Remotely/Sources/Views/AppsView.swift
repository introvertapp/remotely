import SwiftUI

struct AppsView: View {
    @ObservedObject var service: AppleTVService
    @ObservedObject private var artworkLoader = AppArtworkLoader.shared
    @AppStorage(AppConstants.fetchAppArtworkDefaultsKey) private var fetchAppArtwork = false

    @State private var orderedApps: [RemoteApp] = []
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var isEditing = false
    @State private var draggedAppID: String?
    @State private var orderDeviceID: String?

    private static let appOrderDefaultsKeyPrefix = "appsOrder."
    private static let coordinateSpaceName = "AppsCard"

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var displayedApps: [RemoteApp] {
        orderedApps.isEmpty ? service.apps : orderedApps
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Apps")
                .font(.system(size: 16, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.top, 22)

            Group {
                if !service.isConnected {
                    emptyState(
                        symbol: "appletv",
                        title: "Apple TV not connected",
                        detail: "Connect to an Apple TV in Preferences to view its apps."
                    )
                } else if service.apps.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading apps…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 15) {
                            ForEach(displayedApps) { app in
                                Button {
                                    guard !isEditing else { return }
                                    service.launchApp(app)
                                } label: {
                                    appTile(app)
                                }
                                .buttonStyle(AppTileButtonStyle())
                                .modifier(
                                    AppTileWiggleModifier(
                                        isEditing: isEditing,
                                        direction: wiggleDirection(for: app)
                                    )
                                )
                                .scaleEffect(draggedAppID == app.bundleID ? 1.035 : 1)
                                .zIndex(draggedAppID == app.bundleID ? 1 : 0)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: AppTileFramePreferenceKey.self,
                                            value: [
                                                app.bundleID: geometry.frame(
                                                    in: .named(Self.coordinateSpaceName)
                                                )
                                            ]
                                        )
                                    }
                                }
                                .simultaneousGesture(
                                    LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
                                        .onEnded { _ in
                                            beginEditing()
                                        }
                                )
                                .simultaneousGesture(
                                    DragGesture(
                                        minimumDistance: 4,
                                        coordinateSpace: .named(Self.coordinateSpaceName)
                                    )
                                    .onChanged { value in
                                        handleDrag(value, app: app)
                                    }
                                    .onEnded { _ in
                                        draggedAppID = nil
                                    }
                                )
                                .accessibilityLabel("Open \(app.name) on Apple TV")
                                .accessibilityHint(
                                    isEditing
                                        ? "Drag to reorder. Click an empty area to save."
                                        : "Press and hold to reorder apps."
                                )
                                .onAppear {
                                    if builtInSymbol(for: app) == nil {
                                        artworkLoader.loadIfNeeded(
                                            bundleID: app.bundleID,
                                            enabled: fetchAppArtwork
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 22)
                        .padding(.bottom, 18)
                    }
                    .scrollIndicators(.automatic)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppConstants.remoteBackground)
        .foregroundStyle(.white)
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onPreferenceChange(AppTileFramePreferenceKey.self) { frames in
            tileFrames = frames
        }
        .simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .named(Self.coordinateSpaceName))
                .onEnded { value in
                    guard isEditing else { return }
                    let tappedTile = tileFrames.values.contains { $0.contains(value.location) }
                    if !tappedTile {
                        finishEditing(save: true)
                    }
                }
        )
        .onAppear {
            orderDeviceID = service.remoteDeviceID
            reconcileApps(service.apps, deviceID: orderDeviceID)
            service.refreshApps()
        }
        .onDisappear {
            if isEditing {
                finishEditing(save: true)
            }
        }
        .onChange(of: service.apps) { _, apps in
            reconcileApps(apps, deviceID: orderDeviceID)
        }
        .onChange(of: service.remoteDeviceID) { oldValue, newValue in
            if isEditing {
                saveOrder(for: oldValue)
                finishEditing(save: false)
            }
            orderDeviceID = newValue
            reconcileApps(service.apps, deviceID: newValue)
        }
    }

    private func appTile(_ app: RemoteApp) -> some View {
        VStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppConstants.controlBackground)
                .aspectRatio(5.0 / 3.0, contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        artworkContent(for: app, in: geometry.size)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppConstants.controlBorder, lineWidth: 0.8)
                }

            Text(app.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
        }
        .contentShape(Rectangle())
    }

    private func beginEditing() {
        guard !isEditing else { return }

        orderDeviceID = service.remoteDeviceID
        reconcileApps(service.apps, deviceID: orderDeviceID)
        isEditing = true
    }

    private func finishEditing(save: Bool) {
        guard isEditing else { return }

        if save {
            saveOrder(for: orderDeviceID)
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            draggedAppID = nil
            isEditing = false
        }
    }

    private func handleDrag(_ value: DragGesture.Value, app: RemoteApp) {
        guard isEditing else { return }

        draggedAppID = app.bundleID

        guard let targetID = tileFrames.first(where: { $0.value.contains(value.location) })?.key,
              targetID != app.bundleID,
              let sourceIndex = orderedApps.firstIndex(where: { $0.bundleID == app.bundleID }),
              let targetIndex = orderedApps.firstIndex(where: { $0.bundleID == targetID }) else {
            return
        }

        withAnimation(.easeInOut(duration: 0.14)) {
            let movedApp = orderedApps.remove(at: sourceIndex)
            orderedApps.insert(movedApp, at: min(targetIndex, orderedApps.count))
        }
    }

    private func reconcileApps(_ apps: [RemoteApp], deviceID: String?) {
        guard !apps.isEmpty else {
            orderedApps = []
            return
        }

        let preferredOrder: [String]
        if isEditing, deviceID == orderDeviceID, !orderedApps.isEmpty {
            preferredOrder = orderedApps.map(\.bundleID)
        } else {
            preferredOrder = savedOrder(for: deviceID)
        }

        let appsByID = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleID, $0) })
        var seen = Set<String>()
        var result: [RemoteApp] = []

        for bundleID in preferredOrder {
            guard let app = appsByID[bundleID], seen.insert(bundleID).inserted else { continue }
            result.append(app)
        }

        for app in apps where seen.insert(app.bundleID).inserted {
            result.append(app)
        }

        orderedApps = result
    }

    private func saveOrder(for deviceID: String?) {
        guard !orderedApps.isEmpty else { return }
        UserDefaults.standard.set(
            orderedApps.map(\.bundleID),
            forKey: appOrderDefaultsKey(for: deviceID)
        )
    }

    private func savedOrder(for deviceID: String?) -> [String] {
        UserDefaults.standard.stringArray(forKey: appOrderDefaultsKey(for: deviceID)) ?? []
    }

    private func appOrderDefaultsKey(for deviceID: String?) -> String {
        let suffix = deviceID?.isEmpty == false ? deviceID! : "default"
        return Self.appOrderDefaultsKeyPrefix + suffix
    }

    private func wiggleDirection(for app: RemoteApp) -> Double {
        app.bundleID.count.isMultiple(of: 2) ? 1 : -1
    }

    @ViewBuilder
    private func artworkContent(for app: RemoteApp, in size: CGSize) -> some View {
        if let symbol = builtInSymbol(for: app) {
            ZStack {
                Color.white.opacity(0.15)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if fetchAppArtwork, let image = artworkLoader.image(for: app.bundleID) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            ZStack {
                Color.white.opacity(0.15)
                Image(systemName: "app.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func builtInSymbol(for app: RemoteApp) -> String? {
        // Apple/system apps intentionally use local SF Symbols rather than
        // App Store artwork uses a landscape launcher-style treatment.
        // and avoids showing unrelated square iOS icons for tvOS system apps.
        let name = app.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch name {
        case "app store":
            return "bag"
        case "arcade":
            return "gamecontroller.fill"
        case "computers":
            return "rectangle.stack.fill"
        case "fitness":
            return "figure.run"
        case "music":
            return "music.note"
        case "photos":
            return "photo.fill"
        case "podcasts":
            return "dot.radiowaves.left.and.right"
        case "search":
            return "magnifyingglass"
        case "settings":
            return "gearshape.fill"
        case "tv", "apple tv":
            return "tv.fill"
        default:
            break
        }

        // Other Apple-owned system bundle IDs should still get a neutral local
        // fallback rather than an external App Store lookup.
        if app.bundleID.hasPrefix("com.apple.") {
            return "app.fill"
        }

        return nil
    }

    private func emptyState(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 14, weight: .semibold))

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


private struct AppTileWiggleModifier: ViewModifier {
    let isEditing: Bool
    let direction: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEditing {
            content
                .phaseAnimator([false, true]) { view, phase in
                    view.rotationEffect(.degrees((phase ? 1.05 : -1.05) * direction))
                } animation: { _ in
                    .easeInOut(duration: 0.12)
                }
        } else {
            content
                .rotationEffect(.degrees(0))
        }
    }
}

private struct AppTileFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct AppTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
