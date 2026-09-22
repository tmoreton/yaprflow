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

    @Test("Turns spoken sentence punctuation into symbols")
    func appliesSpokenSentencePunctuation() {
        #expect(
            TranscriptPolishing.polish(
                "Hello period how are you question mark I am ready exclamation point"
            ) == "Hello. How are you? I am ready!"
        )
    }

    @Test("Turns spoken formatting commands into punctuation and line breaks")
    func appliesSpokenFormatting() {
        #expect(
            TranscriptPolishing.polish(
                "First item comma second item semicolon third item colon done new paragraph next section new line final thought"
            ) == "First item, second item; third item: done\n\nNext section\nFinal thought"
        )
    }

    @Test("Preserves punctuation words in clearly literal phrases")
    func preservesLiteralPunctuationWords() {
        #expect(
            TranscriptPolishing.polish(
                "This was a difficult period in history, and the question mark symbol was discussed."
            ) == "This was a difficult period in history, and the question mark symbol was discussed."
        )
    }
}
