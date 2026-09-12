import Testing
@testable import YaprflowCore

@Suite("Multilingual transcript polishing")
struct TranscriptPolishingTests {
    @Test("Removes fillers from confidently English text")
    func removesEnglishFillers() {
        #expect(
            TranscriptPolishing.polish("  Um, I think, uh, this is ready.  ")
                == "I think, this is ready."
        )
    }

    @Test("Preserves Portuguese um")
    func preservesPortugueseUm() {
        #expect(
            TranscriptPolishing.polish("um carro vermelho")
                == "um carro vermelho"
        )
    }

    @Test("Preserves German er")
    func preservesGermanEr() {
        #expect(
            TranscriptPolishing.polish("er ist heute hier")
                == "er ist heute hier"
        )
    }

    @Test("Preserves CJK text and embedded uppercase names")
    func preservesCJKText() {
        #expect(
            TranscriptPolishing.polish(
                "AIについて話します",
                normalizingEnglishAllCaps: true
            ) == "AIについて話します"
        )
    }

    @Test("Retains legacy normalization for confidently English all-caps text")
    func normalizesEnglishAllCaps() {
        #expect(
            TranscriptPolishing.polish(
                "I THINK THIS IS READY",
                normalizingEnglishAllCaps: true
            ) == "I think this is ready"
        )
    }
}
