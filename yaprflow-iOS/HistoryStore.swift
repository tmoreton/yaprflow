import Foundation
import Combine

/// FIFO of the most recent transcripts for quick re-copy inside the iOS app.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    private static let key = "yaprflow.history"
    private static let maxItems = 3

    @Published private(set) var items: [String] = []

    private let defaults: UserDefaults

    private init() {
        self.defaults = .standard
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
