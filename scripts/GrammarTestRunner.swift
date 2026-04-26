// Grammar Test Runner - Build and run with:
// cd /Users/tmoreton/Code/yaprflow && swift build 2>/dev/null || xcodebuild -project yaprflow.xcodeproj -scheme yaprflow -derivedDataPath ./build && swift -I ./build/Build/Products/Debug -L ./build/Build/Products/Debug -lswiftCore -target arm64-apple-macos15 scripts/GrammarTestRunner.swift

import Foundation

// Test cases: (input, expected substrings, forbidden substrings)
let testCases: [(input: String, expect: [String], forbid: [String], description: String)] = [
    (
        "She don't like them oranges.",
        ["doesn't", "those"],
        ["don't", "them oranges", " thinking", "</thinking>"],
        "Subject-verb agreement + demonstrative"
    ),
    (
        "i dont no if this work",
        ["I don't", "know", "works"],
        ["dont", "no if", " work", " thinking"],
        "Spelling + contractions"
    ),
    (
        "Their going to the store.",
        ["They're"],
        ["Their going", " thinking"],
        "Their/there/they're"
    ),
    (
        "He run fast yesterday",
        ["ran"],
        ["He run", " thinking"],
        "Verb tense"
    ),
    (
        "Me and him went to the park",
        ["He and I"],
        ["Me and him", " thinking"],
        "Pronoun case"
    ),
    (
        "The car is broke",
        ["broken"],
        ["is broke", " thinking"],
        "Past participle"
    ),
    (
        "Its out of ink",
        ["It's"],
        ["Its out", " thinking"],
        "Its/it's"
    ),
]

print("═".repeating(70))
print("  YAPRFLOW GRAMMAR TEST SUITE")
print("  Model: Qwen2.5-1.5B-Instruct-4bit (no thinking mode)")
print("═".repeating(70))
print()

print("Test cases defined:\n")
for (i, test) in testCases.enumerated() {
    print("Test \(String(format: "%02d", i+1)): \(test.description)")
    print("  Input:   \"\(test.input)\"")
    print("  Expect:  \(test.expect.joined(separator: ", "))")
    print("  Forbid:  \(test.forbid.joined(separator: ", "))")
    print()
}

print("═".repeating(70))
print("RESULTS FORMAT:")
print("  ✅ PASS - Output contains expected, lacks forbidden")
print("  ❌ FAIL - Output missing expected or contains forbidden")
print("═".repeating(70))
print()
print("To run with actual LLM:")
print("  1. Launch app with Grammar mode ON")
print("  2. Dictate each input")
print("  3. Compare to expected output")
print()

extension String {
    func repeating(_ n: Int) -> String { String(repeating: self, count: n) }
}
