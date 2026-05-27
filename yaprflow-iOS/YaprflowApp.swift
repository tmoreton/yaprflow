#if os(iOS)
import SwiftUI

@main
struct YaprflowApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .tint(.white)
                .onOpenURL(perform: handleURL)
                .onAppear(perform: drainPendingKeyboardRequest)
        }
    }

    /// Handle yaprflow:// URLs. Two forms:
    ///   yaprflow://open         — just bring the app forward, no auto-record
    ///   yaprflow://record?id=X  — auto-start dictation for keyboard request X
    private func handleURL(_ url: URL) {
        guard url.scheme == "yaprflow" else { return }
        switch url.host {
        case "record":
            // Prefer the id from the query string; fall back to the pending
            // request file (in case the URL was opened by something that
            // strips query strings).
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let queryID = comps?.queryItems?.first(where: { $0.name == "id" })?.value
            if let id = queryID ?? KeyboardRequest.readCurrent()?.id {
                TranscriptionEngine.shared.autoRecordForKeyboard(requestID: id)
            }
        default:
            break
        }
    }

    /// On cold launch via the URL, onOpenURL fires AFTER onAppear in some
    /// iOS versions. Belt-and-suspenders: also check the pending request
    /// file at startup in case it was set right before we launched.
    private func drainPendingKeyboardRequest() {
        guard let req = KeyboardRequest.readCurrent() else { return }
        // Only auto-trigger if the request is fresh (last 30 seconds).
        // Stale requests shouldn't kick off random recording sessions.
        if Date().timeIntervalSince(req.requestedAt) < 30 {
            TranscriptionEngine.shared.autoRecordForKeyboard(requestID: req.id)
        }
    }
}
#endif
