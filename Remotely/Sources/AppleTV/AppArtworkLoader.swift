import AppKit
import Combine
import Foundation

/// Optional tvOS App Store artwork loader for the Apps card.
///
/// The loader is completely dormant unless the user enables the corresponding
/// Preferences toggle. App discovery and launching always remain local to the
/// selected Apple TV; this class only resolves landscape tvOS artwork for a
/// known bundle ID.
@MainActor
final class AppArtworkLoader: ObservableObject {
    static let shared = AppArtworkLoader()

    @Published private(set) var images: [String: NSImage] = [:]

    private var loadingBundleIDs: Set<String> = []
    private var unavailableBundleIDs: Set<String> = []

    private init() {}

    func image(for bundleID: String) -> NSImage? {
        images[bundleID]
    }

    func loadIfNeeded(bundleID: String, enabled: Bool) {
        guard enabled else { return }
        guard images[bundleID] == nil else { return }
        guard !loadingBundleIDs.contains(bundleID) else { return }
        guard !unavailableBundleIDs.contains(bundleID) else { return }

        loadingBundleIDs.insert(bundleID)

        Task { [weak self] in
            guard let self else { return }
            defer { loadingBundleIDs.remove(bundleID) }

            guard let image = await fetchArtwork(bundleID: bundleID) else {
                unavailableBundleIDs.insert(bundleID)
                return
            }

            images[bundleID] = image
        }
    }

    private func fetchArtwork(bundleID: String) async -> NSImage? {
        guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else {
            return nil
        }

        let country = Locale.current.region?.identifier.lowercased() ?? "us"
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "entity", value: "tvSoftware"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let lookupURL = components.url else { return nil }

        do {
            var lookupRequest = URLRequest(url: lookupURL)
            lookupRequest.timeoutInterval = 6
            lookupRequest.cachePolicy = .returnCacheDataElseLoad

            let (lookupData, lookupResponse) = try await URLSession.shared.data(for: lookupRequest)
            guard let httpResponse = lookupResponse as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }

            let response = try JSONDecoder().decode(LookupResponse.self, from: lookupData)
            guard let result = response.results.first,
                  let artworkString = result.artworkUrl512 ?? result.artworkUrl100 ?? result.artworkUrl60,
                  let artworkURL = URL(string: artworkString) else {
                return nil
            }

            var artworkRequest = URLRequest(url: artworkURL)
            artworkRequest.timeoutInterval = 8
            artworkRequest.cachePolicy = .returnCacheDataElseLoad

            let (imageData, imageResponse) = try await URLSession.shared.data(for: artworkRequest)
            guard let imageHTTPResponse = imageResponse as? HTTPURLResponse,
                  (200..<300).contains(imageHTTPResponse.statusCode),
                  let image = NSImage(data: imageData),
                  image.size.width > image.size.height else {
                return nil
            }

            return image
        } catch {
            return nil
        }
    }
}

private struct LookupResponse: Decodable {
    let results: [LookupResult]
}

private struct LookupResult: Decodable {
    let artworkUrl60: String?
    let artworkUrl100: String?
    let artworkUrl512: String?
}
