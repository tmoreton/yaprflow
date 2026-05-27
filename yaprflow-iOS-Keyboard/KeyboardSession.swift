#if os(iOS)
import Foundation
import SwiftUI
import UIKit
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow.keyboard", category: "Session")

enum KeyboardStatus: Equatable {
    case idle
    case awaitingApp        // user tapped mic; app should be opening
    case awaitingReturn     // result already arrived; just needs the user to swipe back
    case inserted
    case error(String)
}

/// Owns page/shift state and the URL-handoff lifecycle with the main app.
///
/// Recording is NOT done in this process — iOS blocks all extensions from
/// mic access. Instead, the mic button opens the main Yaprflow app via the
/// `yaprflow://record?id=…` URL scheme; the app records and writes a result
/// file into the App Group; we read it on viewWillAppear and insert.
@MainActor
final class KeyboardSession: ObservableObject {
    @Published var status: KeyboardStatus = .idle
    @Published var history: [String] = []

    @Published var page: KeyboardPage = .letters
    @Published var shift: ShiftState = .uppercaseOnce

    var insertText: ((String) -> Void)?
    var deleteBackward: (() -> Void)?
    var openHostApp: ((URL) -> Void)?
    var advanceToNextKeyboard: (() -> Void)?
    var needsInputModeSwitchKey: Bool = false

    private var lastRequestID: String?
    private var lastShiftTapAt: Date?

    init() {}

    // MARK: - Text input

    func tapLetter(_ ch: String) {
        let out: String
        switch shift {
        case .lowercase: out = ch.lowercased()
        case .uppercaseOnce, .capsLock: out = ch.uppercased()
        }
        insertText?(out)
        if shift == .uppercaseOnce { shift = .lowercase }
    }

    func tapRawText(_ s: String) { insertText?(s) }
    func tapSpace() { insertText?(" ") }
    func tapReturn() { insertText?("\n") }
    func tapBackspace() { deleteBackward?() }

    func tapShift() {
        let now = Date()
        let doubleTap = (lastShiftTapAt.map { now.timeIntervalSince($0) < 0.3 } ?? false)
        lastShiftTapAt = now
        if doubleTap {
            shift = (shift == .capsLock ? .lowercase : .capsLock)
            return
        }
        switch shift {
        case .lowercase: shift = .uppercaseOnce
        case .uppercaseOnce: shift = .lowercase
        case .capsLock: shift = .lowercase
        }
    }

    func switchPage(_ target: KeyboardPage) { page = target }
    func handleGlobe() { advanceToNextKeyboard?() }

    // MARK: - Mic (URL handoff)

    /// User tapped the mic. Write a request file (so the main app knows
    /// what triggered it) and open `yaprflow://record?id=...`. Recording
    /// happens in the main app.
    func tapMic() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // Clear any stale result before we start a new round so the keyboard
        // doesn't pick up a previous transcript by mistake.
        KeyboardResult.clear()

        let request = KeyboardRequest.make()
        do {
            try request.write()
        } catch let error as NSError {
            // Surface the real reason so we can diagnose. Most likely the
            // App Group container isn't reachable from the keyboard (App
            // Groups capability not enabled on the keyboard target's
            // provisioning profile / signing).
            log.error("Failed to write keyboard request: \(error.domain) code=\(error.code) — \(error.localizedDescription, privacy: .public)")
            status = .error("Queue failed: \(error.domain) \(error.code)")
            return
        }
        lastRequestID = request.id
        status = .awaitingApp

        var components = URLComponents()
        components.scheme = "yaprflow"
        components.host = "record"
        components.queryItems = [URLQueryItem(name: "id", value: request.id)]
        if let url = components.url {
            openHostApp?(url)
        }
    }

    /// Called by the view controller whenever the keyboard reappears (e.g.
    /// after the user swipes back from Yaprflow). If there's a matching
    /// result waiting in the App Group, insert it.
    func consumePendingResult() {
        refreshHistory()
        guard let result = KeyboardResult.readCurrent() else { return }

        // Only insert if this matches our most recent request — guards
        // against stale results from older sessions.
        guard let lastID = lastRequestID, result.requestID == lastID else {
            // Result for an older request — discard, don't insert.
            KeyboardResult.clear()
            return
        }

        guard !result.text.isEmpty else {
            KeyboardResult.clear()
            status = .idle
            return
        }

        insertText?(result.text)
        KeyboardResult.clear()
        lastRequestID = nil
        status = .inserted
        scheduleStatusReset(after: 1.2)
    }

    /// On viewWillAppear, the result might already be there (if user
    /// returned slowly) or might not have arrived yet (if they're fast).
    /// Either way: try once, and if we're still waiting, stay in the
    /// `awaitingReturn` state with helpful copy.
    func refreshAfterReturn() {
        if KeyboardResult.readCurrent() != nil {
            consumePendingResult()
        } else if status == .awaitingApp, lastRequestID != nil {
            status = .awaitingReturn
        }
    }

    func insertHistoryItem(_ text: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        insertText?(text)
    }

    // MARK: - Helpers

    func refreshHistory() {
        let raw = AppGroup.sharedDefaults.stringArray(forKey: "yaprflow.history") ?? []
        history = Array(raw.prefix(3))
    }

    private func scheduleStatusReset(after seconds: Double) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self else { return }
            switch self.status {
            case .inserted, .error:
                self.status = .idle
            default: break
            }
        }
    }
}
#endif
