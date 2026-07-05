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

    /// LFM2.5 cleanup runs only for the non-accuracy-pass backends —
    /// Qwen3-ASR already had decoder hotword priming and IS the accuracy
    /// pass. Pure for testing.
    nonisolated static func shouldRunLLMCleanup(
        backend: OfflineTranscriber.Backend,
        llmEnabled: Bool,
        refineModelDownloaded: Bool
    ) -> Bool {
        backend != .qwen3ASR && llmEnabled && refineModelDownloaded
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
        let runCleanup = llm != nil && shouldRunLLMCleanup(
            backend: backend,
            llmEnabled: llmEnabled,
            refineModelDownloaded: LLMService.isDownloaded(
                model: ModelCatalog.liveRefineModel))
        if runCleanup {
            onProgress(0)
            await llm?.setModel(ModelCatalog.liveRefineModel)
        }
        let output = try await OfflineTranscriptPolisher(matcher: matcher).polish(
            texts, language: language, runLLMCleanup: runCleanup,
            generate: { [llm] in
                guard let llm else { throw LLMServiceError.modelNotLoaded }
                return try await llm.generate(system: $0, user: $1, maxTokens: $2)
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
        guard runLLMCleanup, !fixed.isEmpty else { return Output(texts: fixed) }

        var output = Output(texts: fixed)
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
                case .cleaned(let cleaned):
                    // Second fixup pass: the cleanup can drift a term the
                    // deterministic matcher knows how to spell.
                    let final = fixup(cleaned, language: language)
                    if final != sentence {
                        output.texts[index] = final
                        output.originals[index] = sentence
                    }
                case .unchanged:
                    break   // the model found no errors
                case .rejected(let raw):
                    // .private: the output derives from the user's speech;
                    // Xcode's console still shows it while debugging, but
                    // it stays out of sysdiagnoses and Console.app.
                    logger.warning(
                        "offline cleanup rejected, fixed sentence kept: \(raw, privacy: .private)")
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
                logger.warning(
                    "offline cleanup generate failed, fixed sentence kept: \(error.localizedDescription, privacy: .public)")
            }
        }
        onProgress(1)
        return output
    }

    private func fixup(_ text: String, language: AppLanguage) -> String {
        guard let matcher, !matcher.isEmpty else { return text }
        return matcher.fixup(text, language: language)
    }
}
