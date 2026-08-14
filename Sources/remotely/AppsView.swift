import SwiftUI

struct AppsView: View {
    @ObservedObject var service: AppleTVService
    @ObservedObject private var artworkLoader = AppArtworkLoader.shared
    @AppStorage(AppConstants.fetchAppArtworkDefaultsKey) private var fetchAppArtwork = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

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
                            ForEach(service.apps) { app in
                                Button {
                                    service.launchApp(app)
                                } label: {
                                    appTile(app)
                                }
                                .buttonStyle(AppTileButtonStyle())
                                .accessibilityLabel("Open \(app.name) on Apple TV")
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
        .onAppear {
            service.refreshApps()
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

private struct AppTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.76 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
