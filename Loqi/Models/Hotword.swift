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
    /// Alternate spoken forms (nicknames, abbreviations), recognized and
    /// corrected to their OWN spelling, never rewritten to the term.
    /// Optional on purpose: `HotwordStore.load()` is a `try?` decode, and a
    /// missing non-optional key would silently wipe pre-alias hotword files.
    var aliases: [String]?

    /// The form this hotword should take in `language`.
    func rendering(for language: AppLanguage) -> String {
        let preferred = renderings[language]?.trimmingCharacters(in: .whitespaces)
        if let preferred, !preferred.isEmpty { return preferred }
        return term
    }

    /// All spellings that might occur in `language` speech: the language's
    /// rendering, the canonical term (foreign names are often spoken
    /// verbatim inside another language), and any aliases.
    func recognitionForms(for language: AppLanguage) -> [String] {
        var forms = [rendering(for: language)]
        if !forms.contains(term) { forms.append(term) }
        for alias in aliases ?? [] where !forms.contains(alias) {
            forms.append(alias)
        }
        return forms.filter { !$0.isEmpty }
    }

    /// (recognized form → replacement) pairs for tier-0 fixup: rendering and
    /// term both restore the canonical rendering, while an alias restores
    /// the alias's own spelling — fixup must not rewrite what was said.
    /// First mapping wins, so an alias equal to the term stays canonical.
    func fixupPairs(for language: AppLanguage) -> [(form: String, replacement: String)] {
        let canonical = rendering(for: language)
        var seen = Set<String>()
        var pairs: [(String, String)] = []
        func add(_ form: String, _ replacement: String) {
            let trimmed = form.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !replacement.isEmpty,
                  seen.insert(trimmed).inserted else { return }
            pairs.append((trimmed, replacement))
        }
        add(canonical, canonical)
        add(term, canonical)
        for alias in aliases ?? [] { add(alias, alias) }
        return pairs
    }
}
