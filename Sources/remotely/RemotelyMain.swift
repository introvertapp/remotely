import AppKit

@main
enum RemotelyMain {
    @MainActor
    static func main() {
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
