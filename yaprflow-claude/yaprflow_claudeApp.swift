import SwiftUI

@main
struct yaprflow_claudeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        _EmptyScene()
    }
}

private struct _EmptyScene: Scene {
    var body: some Scene {
        Settings { EmptyView() }
    }
}
