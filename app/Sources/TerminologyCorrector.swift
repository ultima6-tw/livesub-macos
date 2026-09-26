import Foundation

/// Fuzzy-corrects ASR output against a user-maintained glossary of proper
/// nouns / terms (e.g. F1 driver and team names) that SpeechTranscriber has
/// no vocabulary-hinting API for (unlike DictationTranscriber's
/// customizedLanguage content hint). Optionally also forces a translation
/// override when the on-device translator leaves the term untranslated.
struct TerminologyCorrector {
    /// One glossary line per entry: `"Max Verstappen"` (ASR correction only)
    /// or `"Max Verstappen = 麥克斯·維斯塔潘"` (also overrides the translation).
    var glossary: [String] = []

    private struct Entry {
        let words: [String]              // canonical words, e.g. ["Max", "Verstappen"]
        let lowerJoined: String          // "max verstappen"
        let translationOverride: String?
    }

    private var entries: [Entry] {
        glossary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { line -> Entry in
                let parts = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                let term = parts[0]
                let override = (parts.count > 1 && !parts[1].isEmpty) ? parts[1] : nil
                let words = term.split(separator: " ").map(String.init)
                return Entry(words: words, lowerJoined: words.joined(separator: " ").lowercased(),
                             translationOverride: override)
            }
            // Longer phrases first so multi-word terms win over single-word ones.
            .sorted { $0.words.count > $1.words.count }
    }

    /// A word split into surrounding punctuation and its alphanumeric core,
    /// e.g. `"Stappen,"` -> (leading: "", core: "Stappen", trailing: ","). Matching
    /// compares only the core so trailing commas/periods don't throw off the
    /// edit-distance threshold; the original punctuation is reattached on replace.
    private struct WordParts {
        let leading: String
        let core: String
        let trailing: String
    }

    private func splitPunctuation(_ word: String) -> WordParts {
        let chars = Array(word)
        var leadEnd = 0
        while leadEnd < chars.count, chars[leadEnd].isPunctuation {
            leadEnd += 1
        }
        var trailStart = chars.count
        while trailStart > leadEnd, chars[trailStart - 1].isPunctuation {
            trailStart -= 1
        }
        return WordParts(leading: String(chars[0..<leadEnd]),
                          core: String(chars[leadEnd..<trailStart]),
                          trailing: String(chars[trailStart...]))
    }

    func correct(_ text: String) -> String {
        guard !glossary.isEmpty else { return text }
        var words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return text }

        let parts = words.map(splitPunctuation)
        var used = Array(repeating: false, count: words.count)

        for entry in entries {
            let k = entry.words.count
            guard k > 0, k <= words.count else { continue }

            var i = 0
            while i + k <= words.count {
                defer { i += 1 }
                if used[i..<(i + k)].contains(true) { continue }

                let coreWindow = parts[i..<(i + k)].map(\.core).joined(separator: " ")
                if matches(coreWindow.lowercased(), entry.lowerJoined) {
                    for (offset, w) in entry.words.enumerated() {
                        let idx = i + offset
                        words[idx] = parts[idx].leading + w + parts[idx].trailing
                        used[idx] = true
                    }
                    i += k - 1
                }
            }
        }

        return words.joined(separator: " ")
    }

    /// Best-effort post-translation override: on-device translation often
    /// leaves an unfamiliar proper noun untranslated (verbatim, in the
    /// source script) inside the translated sentence. Where that literal
    /// term is still present in the translated output, force it to the
    /// configured override. Harmless no-op when the translator instead
    /// transliterated the term into the target script — that case isn't
    /// fixable this way (would need a placeholder-substitution round-trip,
    /// not attempted yet since we haven't verified this simpler path
    /// against real translated output).
    func applyTranslationOverrides(to translated: String) -> String {
        var result = translated
        for entry in entries {
            guard let override = entry.translationOverride else { continue }
            let term = entry.words.joined(separator: " ")
            guard !term.isEmpty else { continue }
            result = result.replacingOccurrences(of: term, with: override, options: .caseInsensitive)
        }
        return result
    }

    /// Very short terms (acronyms like "DRS") require an exact
    /// case-insensitive match — fuzzy matching on 2-3 letters is too prone
    /// to false positives. Longer terms allow a bounded edit distance.
    private func matches(_ candidate: String, _ term: String) -> Bool {
        if candidate == term { return true }
        guard term.count >= 4 else { return false }

        let distance = levenshtein(candidate, term)
        let threshold = max(1, Int((Double(term.count) * 0.34).rounded(.down)))
        return distance <= threshold
    }

    private func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var prev = Array(0...b.count)
        var curr = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    curr[j] = prev[j - 1]
                } else {
                    curr[j] = 1 + min(prev[j - 1], prev[j], curr[j - 1])
                }
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
