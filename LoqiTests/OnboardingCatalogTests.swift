import Foundation
import Testing

@testable import Loqi

/// Guards for the onboarding region → source fan-out and the download
/// queue shape. The region choice is the only place all three source
/// settings are written together — a wrong mapping strands China-mainland
/// users on unreachable hosts (and the diarizer must use HF-Mirror, never
/// ModelScope, where its repos don't exist).
struct OnboardingCatalogTests {
    // MARK: Region suggestion

    @Test func mainlandChinaGetsMirrorSuggestion() {
        #expect(DownloadRegion.suggested(for: Locale.Region("CN")) == .chinaMainland)
    }

    @Test(arguments: ["US", "TW", "HK", "JP"])
    func otherRegionsGetGlobal(identifier: String) {
        #expect(DownloadRegion.suggested(for: Locale.Region(identifier)) == .global)
    }

    @Test func unknownRegionGetsGlobal() {
        #expect(DownloadRegion.suggested(for: nil) == .global)
    }

    // MARK: Region → source mapping

    @Test func globalUsesHuggingFaceEverywhere() {
        #expect(DownloadRegion.global.llmSource == .huggingFace)
        #expect(DownloadRegion.global.asrSource == .huggingFace)
        #expect(DownloadRegion.global.diarizerSource == .huggingFace)
    }

    @Test func chinaMainlandUsesModelScopeAndHFMirror() {
        #expect(DownloadRegion.chinaMainland.llmSource == .modelScope)
        #expect(DownloadRegion.chinaMainland.asrSource == .modelScope)
        #expect(DownloadRegion.chinaMainland.diarizerSource == .hfMirror)
    }

    @Test func persistWritesTheSettingsKeys() {
        let suite = "OnboardingCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        DownloadRegion.chinaMainland.persistSources(to: defaults)
        #expect(defaults.string(forKey: "model.source") == ModelSource.modelScope.rawValue)
        #expect(defaults.string(forKey: "asr.source") == ASRModelSource.modelScope.rawValue)
        #expect(defaults.string(forKey: "diarizer.source") == DiarizerSource.hfMirror.rawValue)

        DownloadRegion.global.persistSources(to: defaults)
        #expect(defaults.string(forKey: "model.source") == ModelSource.huggingFace.rawValue)
        #expect(defaults.string(forKey: "asr.source") == ASRModelSource.huggingFace.rawValue)
        #expect(defaults.string(forKey: "diarizer.source") == DiarizerSource.huggingFace.rawValue)
    }

    // MARK: Item lineup

    @Test func recommendedSelectionIncludesTranslationPacks() {
        #expect(OnboardingItemKind.defaultSelection == [
            .translationPacks,
            .senseVoice,
            .diarizer,
            .llm,
        ])
    }

    @Test func appleSpeechIsAlwaysIncludedAndSizeless() {
        #expect(OnboardingItemKind.appleSpeech.alwaysIncluded)
        #expect(OnboardingItemKind.appleSpeech.downloadBytes == nil)
        #expect(OnboardingItemKind.allCases.filter(\.alwaysIncluded) == [.appleSpeech])
    }

    @Test func translationPacksAreRecommendedAndSizeless() {
        #expect(OnboardingItemKind.translationPacks.isRecommended)
        #expect(!OnboardingItemKind.translationPacks.alwaysIncluded)
        #expect(OnboardingItemKind.translationPacks.downloadBytes == nil)
    }

    @Test func everyModelItemKnowsItsSize() {
        for kind in OnboardingItemKind.allCases
            where kind != .appleSpeech && kind != .translationPacks {
            #expect((kind.downloadBytes ?? 0) > 0)
        }
    }

    @Test func translationPackPairsCoverEveryOrderedLanguagePair() {
        #expect(OnboardingItemKind.translationPairs.count == 12)
        #expect(!OnboardingItemKind.translationPairs.contains {
            $0.source == $0.target
        })
        #expect(OnboardingItemKind.translationPairs.contains(
            LanguagePair(source: .english, target: .chinese)))
        #expect(OnboardingItemKind.translationPairs.contains(
            LanguagePair(source: .korean, target: .japanese)))
    }

    // MARK: Total label

    @Test func totalSumsSelectedUninstalledItems() {
        let total = OnboardingItemKind.totalBytes(
            for: [.translationPacks, .senseVoice, .diarizer, .llm], installed: [])
        let expected = SenseVoiceModelStore.totalExpectedBytes
            + StreamingDiarizer.approximateDownloadBytes
            + ModelCatalog.default.downloadBytes
        #expect(total == expected)
    }

    @Test func totalIgnoresInstalledAndAppleSpeech() {
        let total = OnboardingItemKind.totalBytes(
            for: [.appleSpeech, .senseVoice, .llm], installed: [.llm])
        #expect(total == SenseVoiceModelStore.totalExpectedBytes)
    }

    @Test func emptySelectionTotalsZero() {
        #expect(OnboardingItemKind.totalBytes(for: [], installed: []) == 0)
    }

    // MARK: Queue

    @Test func queueRunsFallbackEngineFirstAndOptionalLast() {
        let queue = OnboardingItemKind.queueOrder(
            selection: [
                .translationPacks,
                .qwen3ASR,
                .llm,
                .diarizer,
                .senseVoice,
            ],
            installed: [])
        #expect(queue == [
            .appleSpeech,
            .translationPacks,
            .senseVoice,
            .diarizer,
            .llm,
            .qwen3ASR,
        ])
    }

    @Test func queueDropsInstalledAndUnselected() {
        let queue = OnboardingItemKind.queueOrder(
            selection: [.senseVoice, .llm], installed: [.senseVoice])
        #expect(queue == [.appleSpeech, .llm])
    }

    @Test func appleSpeechSurvivesEmptySelection() {
        #expect(OnboardingItemKind.queueOrder(selection: [], installed: [])
            == [.appleSpeech])
    }
}
