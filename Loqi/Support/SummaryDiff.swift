import Foundation

/// Token-level diff that extracts the exact spans a user inserted while
/// editing text — the raw material for vocabulary mining. Tokenization is
/// `enumerateSubstrings(.byWords)` (ICU word breaking), which segments CJK
/// text without needing spaces.
enum SummaryDiff {
    /// Substrings of `new` whose tokens are not part of a longest common
    /// subsequence with `old`. Consecutive inserted tokens merge into one
    /// span (inner punctuation included); spans are exact substrings of
    /// `new`, trimmed, capped at `maxSpans`.
    static func insertedSpans(old: String, new: String, maxSpans: Int = 12) -> [String] {
        guard old != new else { return [] }
        // O(m·n) DP guard; tokens past the cap are simply not considered.
        let oldTokens = Array(tokens(in: old).prefix(1200))
        let newTokens = Array(tokens(in: new).prefix(1200))
        guard !newTokens.isEmpty else { return [] }

        let inLCS = newTokenInLCS(oldTokens.map(\.text), newTokens.map(\.text))
        var spans: [String] = []
        var runStart: Int?
        for index in 0...newTokens.count {
            let inserted = index < newTokens.count && !inLCS[index]
            if inserted {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                let range = newTokens[start].range.lowerBound
                    ..< newTokens[index - 1].range.upperBound
                let span = String(new[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !span.isEmpty { spans.append(span) }
                runStart = nil
            }
        }
        return Array(spans.prefix(maxSpans))
    }

    private static func tokens(
        in text: String
    ) -> [(text: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        text.enumerateSubstrings(
            in: text.startIndex..., options: .byWords
        ) { substring, range, _, _ in
            if let substring { result.append((substring, range)) }
        }
        return result
    }

    /// For each token of `new`, whether it belongs to a longest common
    /// subsequence with `old` — the complement marks the insertions.
    /// Case-sensitive on purpose: a casing fix ("qwen" → "Qwen") is signal.
    private static func newTokenInLCS(_ old: [String], _ new: [String]) -> [Bool] {
        let m = old.count, n = new.count
        guard m > 0 else { return [Bool](repeating: false, count: n) }
        // Flat Int32 table keeps the transient allocation modest (~6MB max).
        var table = [Int32](repeating: 0, count: (m + 1) * (n + 1))
        func cell(_ i: Int, _ j: Int) -> Int { i * (n + 1) + j }
        for i in 1...m {
            for j in 1...n {
                table[cell(i, j)] = old[i - 1] == new[j - 1]
                    ? table[cell(i - 1, j - 1)] + 1
                    : max(table[cell(i - 1, j)], table[cell(i, j - 1)])
            }
        }
        var inLCS = [Bool](repeating: false, count: n)
        var i = m, j = n
        while i > 0, j > 0 {
            if old[i - 1] == new[j - 1] {
                inLCS[j - 1] = true
                i -= 1
                j -= 1
            } else if table[cell(i - 1, j)] >= table[cell(i, j - 1)] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return inLCS
    }
}
