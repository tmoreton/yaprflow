import Foundation
import Combine

/// FIFO of the most recent transcripts. Backed by the App Group container so
/// the keyboard extension (phase 2) can read the same list without IPC.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    /// Update this if you create the App Group with a different identifier.
    /// Falls back to standard UserDefaults if the App Group isn't configured yet.
    static let appGroupID = "group.com.tmoreton.yaprflow"

    private static let key = "yaprflow.history"
    private static let maxItems = 3

    @Published private(set) var items: [String] = []

    private let defaults: UserDefaults

    private init() {
        self.defaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
        self.items = defaults.stringArray(forKey: Self.key) ?? []
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = items.filter { $0 != trimmed }
        next.insert(trimmed, at: 0)
        if next.count > Self.maxItems {
            next = Array(next.prefix(Self.maxItems))
        }
        items = next
        defaults.set(next, forKey: Self.key)
    }

    func clear() {
        items = []
        defaults.removeObject(forKey: Self.key)
    }
}
