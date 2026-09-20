import Foundation

@main
struct MobileMeetingStoreSmoke {
    @MainActor
    static func main() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaprflow-ios-meeting-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let store = MobileMeetingStore(rootOverride: root)

            store.draftTitle = "Title without content"
            do {
                _ = try store.saveCapture(
                    transcript: "",
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    endedAt: Date(timeIntervalSince1970: 1_700_000_010),
                    duration: 10
                )
                fail("a title-only draft created an empty meeting")
            } catch MobileMeetingStoreError.emptyCapture {
                // Expected: a title is metadata, not meeting content.
            }

            store.draftTitle = "Launch review"
            store.draftNotes = "Confirm the release owner."
            let notesOnly = try store.saveCapture(
                transcript: "",
                startedAt: Date(timeIntervalSince1970: 1_700_000_100),
                endedAt: Date(timeIntervalSince1970: 1_700_000_115),
                duration: 15
            )

            store.resetDraft()
            let transcript = try store.saveCapture(
                transcript: "We agreed to ship on Friday.",
                startedAt: Date(timeIntervalSince1970: 1_700_000_200),
                endedAt: Date(timeIntervalSince1970: 1_700_000_230),
                duration: 30
            )

            let reloaded = MobileMeetingStore(rootOverride: root)
            guard reloaded.meetings.count == 2,
                  reloaded.meetings.contains(where: { $0.id == notesOnly.id }),
                  reloaded.meetings.contains(where: { $0.id == transcript.id })
            else {
                fail("saved meetings did not survive a store reload")
            }

            let markdown = try String(
                contentsOf: reloaded.exportURL(for: transcript),
                encoding: .utf8
            )
            guard markdown.contains("We agreed to ship on Friday.") else {
                fail("the Markdown export did not include the transcript")
            }

            reloaded.delete(notesOnly)
            guard reloaded.errorMessage == nil,
                  reloaded.meetings.count == 1,
                  !reloaded.meetings.contains(where: { $0.id == notesOnly.id })
            else {
                fail("deleting a meeting did not update durable storage")
            }

            print("YAPRFLOW_IOS_MEETING_STORE_SMOKE_TEST=PASS")
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(
            Data("YAPRFLOW_IOS_MEETING_STORE_SMOKE_TEST=FAIL \(message)\n".utf8)
        )
        Foundation.exit(1)
    }
}
