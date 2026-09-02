import AppKit

@main
@MainActor
struct YaprflowApp {
    private static var appDelegate: AppDelegate?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        application.delegate = delegate
        application.run()
    }
}
