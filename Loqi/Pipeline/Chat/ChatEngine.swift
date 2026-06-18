import Foundation
import NaturalLanguage

/// On-device Q&A over one saved session ("chat with a session"). Chunk
/// notes are the retrieval index — the outline grounds broad questions,
/// matching bullets and keyword-matched transcript lines ground specific
/// ones — and short sessions without notes fall back to the raw transcript.
///
/// Static helpers are pure logic, unit-testable without MLX or a device.
struct ChatEngine {
    let llm: LLMService
    private let prompts = PromptBuilder()

    /// Context character budget (≈ tokens for CJK); keeps prefill in the
    /// seconds range on the 2B model.
    static let contextBudget = 2800
    /// Of which the outline (all headlines) may use at most this much.
    static let outlineBudget = 1200
    static let answerMaxTokens = 256
    /// Q/A pairs of earlier chat carried into the prompt.
    static let historyWindow = 4

    /// The answer is written in the question's language, detected
    /// on-device; ambiguous or unsupported text falls back to the given
    /// language (device language, then session target — the summary rule).
    static func answerLanguage(
        for question: String, fallback: AppLanguage
    ) -> AppLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(question)
        switch recognizer.dominantLanguage {
        case .simplifiedChinese, .traditionalChinese: return .chinese
        case .japanese: return .japanese
        case .korean: return .korean
        case .english: return .english
        default: return fallback
        }
    }

    /// Match tokens for retrieval: lowercased whitespace-split words of ≥2
    /// characters for spaced text, plus all 2-grams of contiguous CJK runs
    /// (substring semantics — the same philosophy as SessionSearch).
    static func queryTokens(_ question: String) -> [String] {
        var tokens: [String] = []
        var seen = Set<String>()
        func add(_ token: String) {
            if seen.insert(token).inserted { tokens.append(token) }
        }

        var latinWord = ""
        var cjkRun = ""
        func flush() {
            if latinWord.count >= 2 { add(latinWord) }
            latinWord = ""
            if cjkRun.count == 1 {
                add(cjkRun)
            } else if cjkRun.count >= 2 {
                let characters = Array(cjkRun)
                for index in 0..<(characters.count - 1) {
                    add(String(characters[index...(index + 1)]))
                }
            }
            cjkRun = ""
        }

        for character in question.lowercased() {
            if character.unicodeScalars.allSatisfy(Self.isCJK) {
                if !latinWord.isEmpty { flush() }
                cjkRun.append(character)
            } else if character.isLetter || character.isNumber {
                if !cjkRun.isEmpty { flush() }
                latinWord.append(character)
            } else {
                flush()
            }
        }
        flush()
        return Array(tokens.prefix(24))
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF,   // Han
             0x3040...0x309F, 0x30A0...0x30FF,   // kana
             0x1100...0x11FF, 0xAC00...0xD7AF:   // Hangul
            return true
        default:
            return false
        }
    }

    /// Speaker-labelled transcript lines containing any token,
    /// chronological, capped to `budget` characters.
    static func relevantLines(
        in record: SessionRecord, question: String, budget: Int
    ) -> [String] {
        let tokens = queryTokens(question)
        guard !tokens.isEmpty else { return [] }
        var lines: [String] = []
        var used = 0
        for entry in record.entries {
            let speaker = record.speakerLabel(entry.speaker).map { "[\($0)] " } ?? ""
            let translation = entry.translation.map { " → \($0)" } ?? ""
            let line = "\(speaker)\(entry.sourceText)\(translation)"
            let haystack = line.lowercased()
            guard tokens.contains(where: { haystack.contains($0) }) else { continue }
            guard used + line.count <= budget else { break }
            lines.append(line)
            used += line.count
        }
        return lines
    }

    /// Context assembly, in priority order under `budget`:
    /// 1. the outline — every chunk-note headline with its time,
    /// 2. bullets of notes whose text matches a query token,
    /// 3. keyword-matched transcript lines with the remaining budget.
    /// No notes at all → matched lines alone, else the transcript tail.
    static func context(
        for record: SessionRecord, question: String, budget: Int = contextBudget
    ) -> String {
        // Photo text grounds chat too: pseudo-notes join the outline and
        // the keyword-matched bullets like any other note.
        let notes = AttachmentNotes.merged(
            record.chunkNotes ?? [], attachments: record.attachments)
        guard !notes.isEmpty else {
            let lines = relevantLines(in: record, question: question, budget: budget)
            return lines.isEmpty
                ? record.plainTranscript(limit: budget)
                : lines.joined(separator: "\n")
        }

        let formatter = DateFormatter()
        formatter.timeStyle = .short
        var blocks: [String] = []
        var used = 0

        var outline: [String] = []
        for note in notes {
            let line = "- \(formatter.string(from: note.startedAt)) \(note.headline)"
            guard used + line.count <= min(Self.outlineBudget, budget) else { break }
            outline.append(line)
            used += line.count
        }
        blocks.append("Outline:\n" + outline.joined(separator: "\n"))

        let tokens = queryTokens(question)
        var bullets: [String] = []
        for note in notes {
            let labelled = note.facts.map { "fact: \($0)" }
                + note.decisions.map { "decision: \($0)" }
                + note.actions.map { "action: \($0)" }
                + note.terms.map { "term: \($0)" }
                + (note.summaryRecords ?? []).map {
                    "\($0.kind.rawValue): \($0.text)"
                }
            for line in labelled {
                let haystack = line.lowercased()
                guard tokens.contains(where: { haystack.contains($0) }) else { continue }
                guard used + line.count <= budget else { break }
                bullets.append(line)
                used += line.count
            }
        }
        if !bullets.isEmpty {
            blocks.append("Notes:\n" + bullets.joined(separator: "\n"))
        }

        let lines = relevantLines(
            in: record, question: question, budget: budget - used)
        if !lines.isEmpty {
            blocks.append("Transcript excerpts:\n" + lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Adjacent user→assistant turns, newest `window` pairs. A trailing
    /// unanswered question (the one being asked now) pairs with nothing
    /// and is ignored.
    static func pairedHistory(
        _ messages: [SessionRecord.ChatMessage], window: Int = historyWindow
    ) -> [(question: String, answer: String)] {
        var pairs: [(question: String, answer: String)] = []
        var pendingQuestion: String?
        for message in messages {
            if message.isUser {
                pendingQuestion = message.text
            } else if let question = pendingQuestion {
                pairs.append((question, message.text))
                pendingQuestion = nil
            }
        }
        return Array(pairs.suffix(window))
    }

    func answer(
        question: String,
        record: SessionRecord,
        history: [SessionRecord.ChatMessage]
    ) async throws -> String {
        try await llm.load(policy: .requireDownloaded)
        let language = Self.answerLanguage(
            for: question,
            fallback: AppLanguage.devicePreferred
                ?? record.entries.last?.direction.target ?? .english)
        let prompt = prompts.qaPrompt(
            question: question,
            context: Self.context(for: record, question: question),
            history: Self.pairedHistory(history),
            in: language)
        let raw = try await llm.generate(
            system: prompt.system, user: prompt.user,
            maxTokens: Self.answerMaxTokens, temperature: 0.3)
        // A cancelled generation returns its partial text instead of
        // throwing; a half answer must not be shown or persisted.
        try Task.checkCancellation()
        let cleaned = prompts.cleanResponse(raw)
        guard !cleaned.isEmpty, !PromptBuilder.hasDegenerateRepetition(cleaned)
        else { throw ChatError.generationFailed }
        return cleaned
    }
}

enum ChatError: LocalizedError {
    case generationFailed

    var errorDescription: String? {
        String(localized: "Couldn't answer — try again.")
    }
}
