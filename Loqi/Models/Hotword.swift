import Foundation

/// A user-defined name or domain term the pipeline should get right.
/// Used three ways: biasing ASR recognition (contextual strings), fixing
/// near-miss transcriptions before translation, and steering the LLM toward
/// consistent renderings in each language.
struct Hotword: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    /// Canonical form, in whatever language the user typed it.
    var term: String
    /// Preferred form per language (e.g. english: "Zhipeng", chinese: "志鹏").
    /// Missing languages fall back to `term`.
    var renderings: [AppLanguage: String] = [:]
    /// Free-text hint for the LLM, e.g. "person name", "app name, keep as-is".
    var note: String = ""

    /// The form this hotword should take in `language`.
    func rendering(for language: AppLanguage) -> String {
        let preferred = renderings[language]?.trimmingCharacters(in: .whitespaces)
        if let preferred, !preferred.isEmpty { return preferred }
        return term
    }

    /// All spellings that might occur in `language` speech: the language's
    /// rendering plus the canonical term (foreign names are often spoken
    /// verbatim inside another language).
    func recognitionForms(for language: AppLanguage) -> [String] {
        var forms = [rendering(for: language)]
        if !forms.contains(term) { forms.append(term) }
        return forms.filter { !$0.isEmpty }
    }
}
