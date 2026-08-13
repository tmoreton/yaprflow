#if os(iOS)
import SwiftUI

@main
struct YaprflowApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .tint(.white)
        }
    }
}
#endif
