import Foundation
import CapsLockHelper

// Controls the Caps Lock LED to silently signal multiple-choice answers.
// No "processing" indicator and no solid-on marker — those made the sequence confusing (more
// blinks than there are options, no clear start of the real answer). The LED only ever blinks
// once the answer is ready: A=1, B=2, C=3, D=4, E=5, each individual blink lasting 1s ON with
// a 0.3s OFF gap between blinks.
enum CapsLockBlinker {

    // MARK: - Detection

    static func isMultipleChoiceAnswer(_ text: String) -> Bool {
        !extractLetters(text).isEmpty
    }

    // Only looks at the LEADING letter(s) of the answer, not the whole text — a verbose model
    // like gpt-6-luna often answers "C because the derivative of..." rather than a bare "C",
    // and scanning the whole string for A-E would also pick up stray letters from the
    // explanation prose itself. Matching strictly ^...$ against the whole string (the original
    // approach) missed every verbose answer, which is why the LED never fired.
    static func extractLetters(_ text: String) -> [Character] {
        let core = stripAnswerPrefix(text)
        // \b after each letter is essential: without it, on something like "B, at a very fancy
        // hotel" the ", " + [A-Ea-e] alternative greedily matched the "a" in "at" (lowercase a-e
        // is a valid letter in the class), over-consuming into an ordinary word and then failing
        // the trailing boundary check below — silently killing detection for a real MC answer.
        // \b forces each matched letter to actually be its own word, not the start of "at"/"do"/etc.
        let pattern = #"^[A-Ea-e]\b(?:\s*[,/&]\s*[A-Ea-e]\b|\s+and\s+[A-Ea-e]\b)*"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = re.firstMatch(in: core, range: NSRange(core.startIndex..., in: core)),
              let range = Range(match.range, in: core) else { return [] }
        // Require the leading match to be followed by punctuation/whitespace/end-of-string, so
        // a word that merely starts with one of these letters ("Area", "Does", "Explanation")
        // isn't mistaken for a one-letter MC answer.
        if range.upperBound < core.endIndex {
            let next = core[range.upperBound]
            guard next == " " || next == "." || next == "," || next == ":" || next == ")" || next == "\n" else { return [] }
        }
        return core[range].uppercased().filter { "ABCDE".contains($0) }
    }

    private static func stripAnswerPrefix(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["the answer is: ", "the answer is ", "answer: ", "answer is "]
        for p in prefixes {
            if t.lowercased().hasPrefix(p) {
                t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if t.hasSuffix(".") { t = String(t.dropLast()) }
        return t
    }

    // MARK: - Blinking

    static func scheduleForAnswer(_ answer: String) {
        let letters = extractLetters(answer)
        guard !letters.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let original = capslock_get()
            if original { capslock_set(false) }
            try? await Task.sleep(nanoseconds: 150_000_000)

            for (i, letter) in letters.enumerated() {
                if i > 0 {
                    // Longer pause between letters (vs. between blinks of the same letter) so
                    // a multi-letter answer still reads as distinct groups.
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
                let n = blinkCount(for: letter)
                for j in 0..<n {
                    capslock_set(true);  try? await Task.sleep(nanoseconds: 1_000_000_000)
                    capslock_set(false)
                    if j < n - 1 { try? await Task.sleep(nanoseconds: 300_000_000) }
                }
            }

            // Restore original state
            try? await Task.sleep(nanoseconds: 400_000_000)
            if original { capslock_set(true) }
        }
    }

    private static func blinkCount(for letter: Character) -> Int {
        ["A": 1, "B": 2, "C": 3, "D": 4, "E": 5][letter] ?? 0
    }
}
