import Foundation

/// Pure matching/fixup logic over a hotword list — Sendable and free of UI
/// or actor state so it's unit-testable and cheap to snapshot per utterance.
///
/// Matching strategies by script:
/// - Latin text: word-window Levenshtein similarity (catches "Quen"→"Qwen").
/// - CJK text: pinyin-equality over character windows (catches homophone
///   substitutions like 智朋 → 志鹏), plus Latin-run matching for foreign
///   names embedded in CJK speech.
struct HotwordMatcher: Sendable {
    let hotwords: [Hotword]

    /// Similarity required before tier-0 *replaces* text. High on purpose:
    /// a wrong replacement is worse than a missed one (the LLM still gets
    /// a shot at anything ≥ `refineThreshold`).
    var replaceThreshold = 0.84
    /// Similarity that forces tier-2 refinement even for short utterances.
    var refineThreshold = 0.7
    /// Glossary inclusion cutoff and cap (prompt budget).
    var glossaryThreshold = 0.6
    var glossaryLimit = 8

    var isEmpty: Bool { hotwords.isEmpty }

    // MARK: Scoring

    /// Best match score of `hotword` anywhere in `text` (0...1).
    func score(_ hotword: Hotword, in text: String, language: AppLanguage) -> Double {
        var best = 0.0
        for form in hotword.recognitionForms(for: language) {
            if language.usesCJKScript, form.contains(where: \.isCJK) {
                if cjkWindowMatch(form: form, in: text) { return 1.0 }
            }
            best = max(best, latinBestSimilarity(form: form, in: text))
        }
        return best
    }

    func shouldForceRefine(_ text: String, language: AppLanguage) -> Bool {
        hotwords.contains { score($0, in: text, language: language) >= refineThreshold }
    }

    /// Formatted glossary lines for hotwords plausibly present in `text`.
    func glossaryLines(direction: LanguagePair, sourceText: String) -> [String] {
        hotwords
            .compactMap { hotword -> (Double, String)? in
                let score = score(hotword, in: sourceText, language: direction.source)
                guard score >= glossaryThreshold else { return nil }
                let source = hotword.rendering(for: direction.source)
                let target = hotword.rendering(for: direction.target)
                let note = hotword.note.isEmpty ? "" : " (\(hotword.note))"
                return (score, "\(source) → \(target)\(note)")
            }
            .sorted { $0.0 > $1.0 }
            .prefix(glossaryLimit)
            .map(\.1)
    }

    // MARK: Tier-0 fixup

    /// Replace high-confidence near-misses in finalized source text with the
    /// hotword's preferred rendering. Conservative by design.
    func fixup(_ text: String, language: AppLanguage) -> String {
        guard !hotwords.isEmpty else { return text }
        var result = text
        for hotword in hotwords {
            let rendering = hotword.rendering(for: language)
            guard !rendering.isEmpty else { continue }
            for form in hotword.recognitionForms(for: language) {
                if language.usesCJKScript, form.contains(where: \.isCJK) {
                    result = replaceCJKHomophones(
                        of: form, with: rendering, in: result)
                } else {
                    result = replaceLatinNearMisses(
                        of: form, with: rendering, in: result)
                }
            }
        }
        return result
    }

    // MARK: Latin matching

    private func latinBestSimilarity(form: String, in text: String) -> Double {
        let target = Self.normalizeLatin(form)
        guard target.count >= 3 else {
            // Too short for fuzzy matching; exact containment only.
            return Self.normalizeLatin(text).contains(target) && !target.isEmpty ? 1.0 : 0.0
        }
        let words = latinRuns(in: text)
        guard !words.isEmpty else { return 0 }
        let formWordCount = max(1, form.split(separator: " ").count)
        var best = 0.0
        for start in words.indices {
            for windowSize in 1...min(formWordCount + 1, words.count - start) {
                let window = words[start..<(start + windowSize)]
                    .map { Self.normalizeLatin($0.text) }.joined()
                best = max(best, Self.similarity(window, target))
            }
        }
        return best
    }

    private func replaceLatinNearMisses(
        of form: String, with rendering: String, in text: String
    ) -> String {
        let target = Self.normalizeLatin(form)
        guard target.count >= 4 else { return text }
        let formWordCount = max(1, form.split(separator: " ").count)

        var result = text
        // Right-to-left so earlier ranges stay valid after replacement.
        let words = latinRuns(in: result)
        var replacements: [(Range<String.Index>, String)] = []
        var index = 0
        while index < words.count {
            var matched = false
            for windowSize in stride(from: min(formWordCount + 1, words.count - index), through: 1, by: -1) {
                let window = words[index..<(index + windowSize)]
                let joined = window.map { Self.normalizeLatin($0.text) }.joined()
                guard Self.similarity(joined, target) >= replaceThreshold else { continue }
                let range = window.first!.range.lowerBound..<window.last!.range.upperBound
                if String(result[range]) != rendering {
                    replacements.append((range, rendering))
                }
                index += windowSize
                matched = true
                break
            }
            if !matched { index += 1 }
        }
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// Maximal runs of Latin letters/digits with their ranges in `text`
    /// (in CJK text these are embedded foreign words; in Latin text, words).
    private func latinRuns(in text: String) -> [(text: String, range: Range<String.Index>)] {
        var runs: [(String, Range<String.Index>)] = []
        var runStart: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char.isLetter && !char.isCJK || char.isNumber {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                runs.append((String(text[start..<index]), start..<index))
                runStart = nil
            }
            index = text.index(after: index)
        }
        if let start = runStart {
            runs.append((String(text[start..<text.endIndex]), start..<text.endIndex))
        }
        return runs
    }

    // MARK: CJK matching

    private func cjkWindowMatch(form: String, in text: String) -> Bool {
        let formPinyin = Self.pinyin(form)
        guard !formPinyin.isEmpty, form.count >= 2 else { return false }
        let characters = Array(text)
        let length = form.count
        guard characters.count >= length else { return false }
        for start in 0...(characters.count - length) {
            let window = String(characters[start..<(start + length)])
            if Self.pinyin(window) == formPinyin { return true }
        }
        return false
    }

    private func replaceCJKHomophones(
        of form: String, with rendering: String, in text: String
    ) -> String {
        let formPinyin = Self.pinyin(form)
        guard !formPinyin.isEmpty, form.count >= 2 else { return text }
        let characters = Array(text)
        let length = form.count
        guard characters.count >= length else { return text }

        var output: [Character] = []
        var index = 0
        while index < characters.count {
            if index + length <= characters.count {
                let window = String(characters[index..<(index + length)])
                if window != rendering, Self.pinyin(window) == formPinyin {
                    output.append(contentsOf: rendering)
                    index += length
                    continue
                }
            }
            output.append(characters[index])
            index += 1
        }
        return String(output)
    }

    // MARK: Primitives

    static func normalizeLatin(_ text: some StringProtocol) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Toneless pinyin romanization, used for CJK homophone equality.
    static func pinyin(_ text: some StringProtocol) -> String {
        let mutable = NSMutableString(string: String(text))
        CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return (mutable as String).lowercased().filter(\.isLetter)
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let aChars = Array(a), bChars = Array(b)
        let longest = max(aChars.count, bChars.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(levenshtein(aChars, bChars)) / Double(longest)
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

extension Character {
    /// CJK Unified Ideographs plus kana — covers zh and ja text.
    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF,   // CJK Unified Ideographs
             0x3400...0x4DBF,   // Extension A
             0x3040...0x309F,   // Hiragana
             0x30A0...0x30FF:   // Katakana
            return true
        default:
            return false
        }
    }
}
