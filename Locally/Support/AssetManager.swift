import Foundation
import Speech
import Translation

/// Checks and downloads the system assets the pipeline depends on:
/// SpeechTranscriber locale models and Translation framework language packs.
/// LLM weights are handled separately by LLMService (they live in the app
/// container, not as system assets).
@MainActor
final class AssetManager {
    enum SpeechAssetStatus: Sendable {
        case installed
        case downloadRequired
        case unsupported
    }

    /// Where this app's transcription assets stand for a language.
    func speechAssetStatus(for language: AppLanguage) async -> SpeechAssetStatus {
        let locale = language.speechLocale
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }) else { return .unsupported }

        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }) { return .installed }
        return .downloadRequired
    }

    /// Reserve the locale for this app and download its model if needed.
    /// Reports download progress in [0, 1].
    func installSpeechAssets(
        for language: AppLanguage,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let transcriber = SpeechTranscriber(
            locale: language.speechLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [])

        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            let progress = request.progress
            let poll = Task {
                while !Task.isCancelled {
                    onProgress(progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { poll.cancel() }
            try await request.downloadAndInstall()
        }
        onProgress(1.0)
    }

    /// Translation framework pair availability. `.supported` means a
    /// language pack download will be prompted on first use.
    func translationStatus(for pair: LanguagePair) async -> LanguageAvailability.Status {
        let availability = LanguageAvailability()
        return await availability.status(
            from: pair.source.translationLanguage,
            to: pair.target.translationLanguage)
    }

    /// True if this pair needs to pivot through English (no direct model).
    func needsEnglishPivot(for pair: LanguagePair) async -> Bool {
        guard pair.source != .english, pair.target != .english else { return false }
        return await translationStatus(for: pair) == .unsupported
    }
}
