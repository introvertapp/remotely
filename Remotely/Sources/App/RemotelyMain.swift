import AppKit

@main
enum RemotelyMain {
    @MainActor
    static func main() {
        // Allow release verification without opening UI or connecting to a TV.
        if CommandLine.arguments.dropFirst().contains("--version") {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            print("remotely \(version)")
            return
        }
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)

        // NSApplication.delegate is not an owning reference. Keep the
        // controller alive for the complete application event loop.
        withExtendedLifetime(controller) {
            app.run()
        }
    }
}
