import Foundation

/// A user-defined subject area ("Physics", "F1", …) chosen before Start.
/// Selecting one switches ASR from SpeechTranscriber to DictationTranscriber
/// biased with the domain's terms (AnalysisContext.contextualStrings — only
/// DictationTranscriber honours them), and uses the same list for post-ASR
/// terminology correction. No domain selected = general conversation.
struct ContentDomain: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    /// Same format as the terminology glossary: one term per line, optional
    /// `" = translation"` suffix to also override the translated form.
    var glossaryText: String

    /// Language-level code ("en") of a locale id like "en-US".
    static func languageCode(_ localeID: String) -> String {
        Locale(identifier: localeID).language.languageCode?.identifier ?? localeID
    }

    /// Language name in the UI language ("English", "英文") for a locale id.
    static func languageName(_ localeID: String) -> String {
        let code = languageCode(localeID)
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// The list's language is recorded only in its name: "Travel (English)".
    /// Left unchanged if the name already mentions that language (e.g. a
    /// re-imported export), so it isn't appended twice.
    static func name(_ base: String, language localeID: String) -> String {
        let lang = languageName(localeID)
        if base.localizedCaseInsensitiveContains(lang) { return base }
        return String(format: NSLocalizedString("vocab.nameWithLanguage", value: "%@ (%@)",
                                                comment: "Vocabulary name followed by its language"),
                      base, lang)
    }

    /// Canonical terms (the part before `=`), trimmed and deduplicated, in
    /// list order — used as ASR contextual strings.
    var terms: [String] {
        var seen = Set<String>()
        return glossaryText
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let term = line.split(separator: "=", maxSplits: 1).first
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { return nil }
                return term
            }
    }
}
