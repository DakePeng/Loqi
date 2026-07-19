import Foundation
import os

/// Shared post-decode polish for the offline transcription paths
/// (re-transcribe and file import): deterministic hotword fixup →
/// optional LFM2.5 sentence cleanup → second fixup pass to catch LLM
/// drift. Runs strictly before translation drafting so Apple translates
/// the cleaned text. Generation is injected as a closure so the fixup
/// ordering, fidelity gating, and rawSourceText bookkeeping are
/// unit-testable without a model (precedent:
/// SummaryEngine.generateStructuredReduce).
@MainActor
struct OfflineTranscriptPolisher {
    typealias Generate = @MainActor (
        _ system: String, _ user: String, _ maxTokens: Int
    ) async throws -> String

    struct Output: Equatable {
        /// Final text per utterance; same order and count as the input.
        var texts: [String]
        /// index → the pre-cleanup (post-fixup-1) text, present only where
        /// an accepted LLM cleanup changed the sentence. Feeds
        /// SessionRecord.Entry.rawSourceText, matching the live pipeline's
        /// applyCleanedSource semantics (and hygienePass's skip rule).
        var originals: [Int: String] = [:]
    }

    /// nil or empty → the fixup passes are no-ops.
    let matcher: HotwordMatcher?
    private let prompts = PromptBuilder()
    private let logger = Logger(
        subsystem: "com.kunzhipeng.loqi", category: "offlinePolish")

    /// Every remaining backend is CTC (no decoder biasing), so LFM2.5
    /// cleanup applies whenever it's enabled and downloaded. Pure for
    /// testing; keeps the seam should a future backend opt out again.
    nonisolated static func shouldRunLLMCleanup(
        backend: OfflineTranscriber.Backend,
        llmEnabled: Bool,
        refineModelDownloaded: Bool
    ) -> Bool {
        llmEnabled && refineModelDownloaded
    }

    /// The whole offline polish phase in one call — gate, live-refine model
    /// swap, and the shared generate closure — so the re-transcribe and
    /// import paths can't drift. Callers keep only entry construction and
    /// their site policies (imports unload the LLM afterwards via
    /// `ranLLMCleanup`; re-transcribe leaves it loaded for the summarize
    /// that follows). The ASR pass unloaded the LLM; generate self-heals
    /// with a requireDownloaded load of the 230M (admitLoad absorbs ONNX
    /// arena release lag).
    static func run(
        texts: [String],
        language: AppLanguage,
        backend: OfflineTranscriber.Backend,
        llm: LLMService?,
        llmEnabled: Bool,
        matcher: HotwordMatcher?,
        onProgress: (Double) -> Void
    ) async throws -> (output: Output, ranLLMCleanup: Bool) {
        let refineModelDownloaded = LLMService.isDownloaded(
            model: ModelCatalog.liveRefineModel)
        let runCleanup = llm != nil && shouldRunLLMCleanup(
            backend: backend,
            llmEnabled: llmEnabled,
            refineModelDownloaded: refineModelDownloaded)
        if !runCleanup {
            // A silently-skipped cleanup is indistinguishable from a broken
            // one from the outside — say which gate closed.
            Logger(subsystem: "com.kunzhipeng.loqi", category: "offlinePolish")
                .notice("offline cleanup skipped: llm=\(llm != nil) enabled=\(llmEnabled) refineModelDownloaded=\(refineModelDownloaded)")
        }
        if runCleanup {
            onProgress(0)
            await llm?.setModel(ModelCatalog.liveRefineModel)
        }
        let output = try await OfflineTranscriptPolisher(matcher: matcher).polish(
            texts, language: language, runLLMCleanup: runCleanup,
            generate: { [llm] in
                guard let llm else { throw LLMServiceError.modelNotLoaded }
                // Near-greedy, no repetition penalty — cleanup copies its
                // input, which the penalty ring would punish (see the
                // matching closure in RefinementQueue).
                return try await llm.generate(
                    system: $0, user: $1, maxTokens: $2,
                    temperature: 0.1, repetitionPenalty: nil,
                    responsePrefix: PromptBuilder.refineResponsePrefix)
            },
            onProgress: onProgress)
        return (output, runCleanup)
    }

    /// Polish every utterance. Throws only `CancellationError`; generation
    /// problems are best-effort — a failed sentence keeps its fixed text,
    /// and missing LFM2.5 weights abort the cleanup loop quietly.
    func polish(
        _ texts: [String],
        language: AppLanguage,
        runLLMCleanup: Bool,
        generate: Generate,
        onProgress: (Double) -> Void = { _ in }
    ) async throws -> Output {
        let fixed = texts.map { fixup($0, language: language) }
        var output = Output(texts: fixed)
        // Preserve the true pre-fixup ASR as the original wherever the
        // deterministic hotword fixup already changed a line — it must
        // survive even when LLM cleanup is skipped (AI off), aborted
        // (missing weights / low memory), or leaves the sentence
        // unchanged. Cleanup below may edit the text further, but the
        // original stays the raw ASR.
        for i in fixed.indices where fixed[i] != texts[i] { output.originals[i] = texts[i] }
        guard runLLMCleanup, !fixed.isEmpty else { return output }
        // Outcome tally for the summary line below — the one number that
        // says whether the cleanup pass is earning its keep.
        var cleaned = 0, unchanged = 0, failed = 0
        var rejections: [String: Int] = [:]
        for index in fixed.indices {
            try Task.checkCancellation()
            onProgress(Double(index) / Double(fixed.count))
            let sentence = fixed[index]
            guard sentence.hasSpeechContent else { continue }
            do {
                switch try await prompts.refineSentence(
                    sentence, language: language,
                    context: Array(output.texts[..<index]
                        .suffix(PromptBuilder.refineContextLimit)),
                    glossary: matcher?.noteGlossaryLines(
                        language: language, text: sentence) ?? [],
                    generate: generate) {
                case .cleaned(let text):
                    cleaned += 1
                    // Second fixup pass: the cleanup can drift a term the
                    // deterministic matcher knows how to spell.
                    let final = fixup(text, language: language)
                    if final != sentence {
                        output.texts[index] = final
                        // Keep the raw ASR if the pre-guard pass already
                        // captured it (fixup changed this line); otherwise
                        // `sentence` IS the raw text (fixup left it alone).
                        if output.originals[index] == nil {
                            output.originals[index] = sentence
                        }
                    }
                case .unchanged:
                    unchanged += 1   // the model found no errors
                case .rejected(let raw, let reason):
                    // The reason ("parse", "similarity 0.41" …) is metadata
                    // and stays public; the output derives from the user's
                    // speech — visible in Xcode while debugging, redacted
                    // in sysdiagnoses and Console.app.
                    rejections[reason.split(separator: " ").first.map(String.init) ?? reason, default: 0] += 1
                    logger.warning(
                        "offline cleanup rejected (\(reason, privacy: .public)), fixed sentence kept: \(raw, privacy: .private)")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch LLMServiceError.modelNotDownloaded {
                logger.info("offline cleanup skipped: LFM2.5 not downloaded")
                break
            } catch LLMServiceError.insufficientMemory {
                // Load-level failure: generate would re-run the whole
                // admission retry for EVERY remaining utterance. Give up on
                // the pass; the fixed sentences stand.
                logger.info("offline cleanup aborted: not enough memory to load")
                break
            } catch {
                failed += 1
                logger.warning(
                    "offline cleanup generate failed, fixed sentence kept: \(error.localizedDescription, privacy: .public)")
            }
        }
        let rejectionSummary = rejections.isEmpty
            ? "0"
            : rejections.sorted { $0.value > $1.value }
                .map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        logger.notice(
            "offline cleanup: \(fixed.count) sentences — \(cleaned) cleaned, \(unchanged) unchanged, rejected [\(rejectionSummary, privacy: .public)], \(failed) failed")
        onProgress(1)
        return output
    }

    private func fixup(_ text: String, language: AppLanguage) -> String {
        guard let matcher, !matcher.isEmpty else { return text }
        return matcher.fixup(text, language: language)
    }
}
