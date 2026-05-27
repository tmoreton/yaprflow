import Foundation

/// Filesystem + UserDefaults conventions shared between the main app and the
/// keyboard extension. Both targets compile this file directly — there's no
/// framework, the source is just shared by membership.
///
/// Architecture note: the keyboard CANNOT record audio (iOS blocks all
/// extensions from mic access at the kernel level). So the handoff is:
///   1. Keyboard writes a "request" JSON with a UUID, opens yaprflow:// URL
///   2. Main app reads the request, records + transcribes, writes a "result"
///   3. User swipes back to the host app; keyboard reads matching result and
///      inserts text via textDocumentProxy
enum AppGroup {
    static let id = "group.com.tmoreton.yaprflow"

    static var containerURL: URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: id
        ) else {
            fatalError("App Group container missing for \(id) — check entitlements")
        }
        return url
    }

    /// Single-slot pending request file (keyboard → main app).
    static var pendingRequestURL: URL {
        containerURL.appendingPathComponent("pending_request.json")
    }

    /// Single-slot pending result file (main app → keyboard).
    static var pendingResultURL: URL {
        containerURL.appendingPathComponent("pending_result.json")
    }

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: id) ?? .standard
    }
}

/// Written by the keyboard when the user taps the mic. Carries a UUID so the
/// main app's result can be matched against the request that triggered it
/// (prevents stale results from leaking into the wrong text field).
struct KeyboardRequest: Codable {
    let id: String
    let requestedAt: Date

    static func make() -> KeyboardRequest {
        KeyboardRequest(id: UUID().uuidString, requestedAt: Date())
    }

    func write() throws {
        let data = try JSONEncoder().encode(self)
        // No .atomic — atomic writes (temp file + rename) have been seen to
        // fail inside the App Group sandbox in extension processes. A plain
        // write to the container root is reliable.
        try data.write(to: AppGroup.pendingRequestURL)
    }

    static func readCurrent() -> KeyboardRequest? {
        guard let data = try? Data(contentsOf: AppGroup.pendingRequestURL) else {
            return nil
        }
        return try? JSONDecoder().decode(KeyboardRequest.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: AppGroup.pendingRequestURL)
    }
}

/// Written by the main app when transcription finishes. The keyboard polls
/// this on viewWillAppear and inserts the text if the request ID matches its
/// most recently dispatched request.
struct KeyboardResult: Codable {
    let requestID: String
    let text: String
    let finishedAt: Date

    func write() throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: AppGroup.pendingResultURL, options: .atomic)
    }

    static func readCurrent() -> KeyboardResult? {
        guard let data = try? Data(contentsOf: AppGroup.pendingResultURL) else {
            return nil
        }
        return try? JSONDecoder().decode(KeyboardResult.self, from: data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: AppGroup.pendingResultURL)
    }
}
