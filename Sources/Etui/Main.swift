import AppKit

@main
struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let launcher = Launcher()
        app.delegate = launcher
        withExtendedLifetime(launcher) { app.run() }
    }
}
