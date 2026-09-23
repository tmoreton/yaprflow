import Testing
@testable import YaprflowCore

@Suite("Bundled model inventory")
struct BundledModelInventoryTests {
    @Test("Parakeet inventory covers every required Core ML component")
    func parakeetInventoryIsComplete() {
        let names = BundledModelInventory.parakeetSpeechFiles.map(\.name)
        #expect(Set(names).count == 21)
        #expect(names.contains("Preprocessor.mlmodelc/weights/weight.bin"))
        #expect(names.contains("Encoder.mlmodelc/weights/weight.bin"))
        #expect(names.contains("Decoder.mlmodelc/weights/weight.bin"))
        #expect(names.contains("JointDecision.mlmodelc/weights/weight.bin"))
        #expect(names.contains("parakeet_vocab.json"))
        #expect(BundledModelInventory.parakeetSpeechFiles.allSatisfy { $0.byteCount > 0 })
    }
}

@Suite("Rolling session audio")
struct RollingSessionAudioTests {
    @Test("Uses absolute indexes after discarding audio")
    func absoluteIndexesSurviveDiscard() {
        var audio = RollingSessionAudio()
        audio.append(Array(0..<10).map(Float.init))
        audio.discard(before: 6)
        audio.append([10, 11, 12])

        #expect(audio.startIndex == 6)
        #expect(audio.endIndex == 13)
        #expect(audio.samples(from: 5, to: 11) == [6, 7, 8, 9, 10])
    }

    @Test("Clamps requests and handles resets")
    func clampsAndResets() {
        var audio = RollingSessionAudio()
        audio.append([1, 2, 3])

        #expect(audio.samples(from: -10, to: 99) == [1, 2, 3])
        #expect(audio.samples(from: 99, to: 100).isEmpty)

        audio.reset(keepingCapacity: true)
        #expect(audio.isEmpty)
        #expect(audio.startIndex == 0)
        #expect(audio.endIndex == 0)
    }

    @Test("An hour-long feed remains bounded when finalized audio is discarded")
    func longSessionRemainsBounded() {
        var audio = RollingSessionAudio()
        let sampleRate = 16_000
        let chunk = [Float](repeating: 0, count: 5_120)
        let maximumRetainedSamples = 31 * sampleRate

        for _ in stride(from: 0, to: 65 * 60 * sampleRate, by: chunk.count) {
            audio.append(chunk)
            audio.discard(before: max(0, audio.endIndex - maximumRetainedSamples))
            #expect(audio.retainedSampleCount <= maximumRetainedSamples + chunk.count)
        }
    }
}

@Suite("Transcript segment boundaries")
struct TranscriptSegmentTests {
    @Test("Deduplicates punctuation-insensitive overlap")
    func removesLeadingOverlap() {
        let result = TranscriptSegments.appending(
            "brown fox, jumps over the dog",
            to: "The quick brown fox.",
            deduplicatingLeadingOverlap: true
        )

        #expect(result == "The quick brown fox. jumps over the dog")
    }

    @Test("Returns only the new portion of an overlapping timestamped segment")
    func returnsOverlapRemainder() {
        let remainder = TranscriptSegments.removingLeadingOverlap(
            from: "brown fox, jumps over the dog",
            alreadyConfirmedIn: "The quick brown fox.",
            maximumOverlapWords: 12
        )

        #expect(remainder == "jumps over the dog")
    }

    @Test("Does not deduplicate natural boundaries")
    func preservesNaturalBoundary() {
        let result = TranscriptSegments.appending(
            "hello again",
            to: "hello",
            deduplicatingLeadingOverlap: false
        )

        #expect(result == "hello hello again")
    }

    @Test("Caps overlap search to avoid removing repeated speech")
    func capsOverlap() {
        let repeated = (1...13).map { "w\($0)" }.joined(separator: " ")
        let result = TranscriptSegments.appending(
            repeated + " end",
            to: repeated,
            deduplicatingLeadingOverlap: true
        )

        #expect(result == repeated + " " + repeated + " end")
    }

    @Test("Combines stable and volatile text without stray spaces")
    func combinesText() {
        #expect(TranscriptSegments.combining(confirmed: "", volatile: "") == "")
        #expect(TranscriptSegments.combining(confirmed: "done", volatile: "") == "done")
        #expect(TranscriptSegments.combining(confirmed: "", volatile: "live") == "live")
        #expect(TranscriptSegments.combining(confirmed: "done", volatile: "live") == "done live")
    }

    @Test("Preserves Latin-script word spacing")
    func preservesLatinWordSpacing() {
        #expect(
            TranscriptSegments.appending(
                "otra frase",
                to: "Esta es una frase.",
                deduplicatingLeadingOverlap: false
            ) == "Esta es una frase. otra frase"
        )
        #expect(
            TranscriptSegments.combining(
                confirmed: "Bonjour tout le monde.",
                volatile: "Comment allez-vous?"
            ) == "Bonjour tout le monde. Comment allez-vous?"
        )
    }

    @Test("Joins Japanese segments and removes character overlap")
    func joinsJapaneseSegments() {
        #expect(
            TranscriptSegments.appending(
                "散歩に行きます。",
                to: "今日は晴れです。",
                deduplicatingLeadingOverlap: false
            ) == "今日は晴れです。散歩に行きます。"
        )
        #expect(
            TranscriptSegments.appending(
                "良い天気です。散歩に行きます。",
                to: "今日はとても良い天気です。",
                deduplicatingLeadingOverlap: true
            ) == "今日はとても良い天気です。散歩に行きます。"
        )
    }

    @Test("Joins Mandarin segments and removes character overlap")
    func joinsMandarinSegments() {
        #expect(
            TranscriptSegments.combining(
                confirmed: "今天天气很好。",
                volatile: "我们去散步吧。"
            ) == "今天天气很好。我们去散步吧。"
        )
        #expect(
            TranscriptSegments.appending(
                "天气很好。我们去散步吧。",
                to: "今天天气很好。",
                deduplicatingLeadingOverlap: true
            ) == "今天天气很好。我们去散步吧。"
        )
    }

    @Test("Does not force whitespace between Thai segments")
    func joinsThaiSegments() {
        #expect(
            TranscriptSegments.appending(
                "เราจะไปเดินเล่น",
                to: "วันนี้อากาศดีมาก",
                deduplicatingLeadingOverlap: false
            ) == "วันนี้อากาศดีมากเราจะไปเดินเล่น"
        )
        #expect(
            TranscriptSegments.appending(
                "อากาศดีมากเราจะไปเดินเล่น",
                to: "วันนี้อากาศดีมาก",
                deduplicatingLeadingOverlap: true
            ) == "วันนี้อากาศดีมากเราจะไปเดินเล่น"
        )
    }
}

@Suite("Recording lifecycle")
struct RecordingLifecycleTests {
    @Test("Every lifecycle state is exclusive")
    func phasesAreExclusive() {
        let phases: Set<RecordingLifecyclePhase> = [
            .idle,
            .starting(7),
            .recording(7),
            .stopping(7),
        ]
        #expect(phases.count == 4)
    }

    @Test("Generation identity rejects stale session states")
    func generationIdentity() {
        #expect(RecordingLifecyclePhase.recording(1) != .recording(2))
        #expect(RecordingLifecyclePhase.stopping(4) == .stopping(4))
    }
}
