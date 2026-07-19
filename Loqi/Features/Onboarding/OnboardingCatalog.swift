import Foundation

/// The one region choice onboarding asks for: it fans out into the three
/// per-model source settings Settings manages individually. China mainland
/// maps everything to ModelScope, including the diarizer (its ONNX files
/// are mirrored there — see DiarizerModelStore).
enum DownloadRegion: String, CaseIterable, Identifiable {
    case global
    case chinaMainland

    var id: String { rawValue }

    var llmSource: ModelSource {
        switch self {
        case .global: .huggingFace
        case .chinaMainland: .modelScope
        }
    }

    var asrSource: ASRModelSource {
        switch self {
        case .global: .huggingFace
        case .chinaMainland: .modelScope
        }
    }

    var diarizerSource: ASRModelSource {
        switch self {
        case .global: .huggingFace
        case .chinaMainland: .modelScope
        }
    }

    var title: String {
        switch self {
        case .global: String(localized: "Global")
        case .chinaMainland: String(localized: "China mainland")
        }
    }

    /// Proper nouns — not localized.
    var sourceSummary: String {
        switch self {
        case .global: "Hugging Face"
        case .chinaMainland: "ModelScope 魔搭 + HF-Mirror"
        }
    }

    var symbolName: String {
        switch self {
        case .global: "globe"
        case .chinaMainland: "globe.asia.australia"
        }
    }

    /// Pre-selection for the region step. Only the mainland gets the mirror
    /// suggestion — Hugging Face is reachable from TW/HK/MO.
    static func suggested(for region: Locale.Region?) -> DownloadRegion {
        region?.identifier == "CN" ? .chinaMainland : .global
    }

    /// Writes the same keys SettingsView's @AppStorage pickers manage, so
    /// Settings reflects the choice afterwards.
    func persistSources(to defaults: UserDefaults = .standard) {
        defaults.set(llmSource.rawValue, forKey: "model.source")
        defaults.set(asrSource.rawValue, forKey: "asr.source")
        defaults.set(diarizerSource.rawValue, forKey: DiarizerModelStore.sourceDefaultsKey)
    }
}

/// Everything the onboarding download step can install, in queue order.
/// Apple speech assets ride along uncheckable: they are the fallback live
/// engine and must work offline even if the user skips every model.
enum OnboardingItemKind: String, CaseIterable, Identifiable {
    case appleSpeech
    case translationPacks
    case senseVoice
    case diarizer
    case liveLLM
    case summaryLLM

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleSpeech: String(localized: "Apple speech recognition")
        case .translationPacks: String(localized: "Translation language packs")
        case .senseVoice: String(localized: "SenseVoice live recognition")
        case .diarizer: String(localized: "Speaker recognition")
        case .liveLLM: String(localized: "Live AI model (LFM2.5)")
        case .summaryLLM: String(localized: "Summary AI model (2B)")
        }
    }

    var subtitle: String {
        switch self {
        case .appleSpeech:
            String(localized: "Built-in live captions — always installed")
        case .translationPacks:
            String(localized: "Offline live translation for English, 中文, 日本語 and 한국어")
        case .senseVoice:
            String(localized: "More accurate live captions for 中文, English, 日本語, 한국어")
        case .diarizer:
            String(localized: "Tells voices apart in recordings")
        case .liveLLM:
            String(localized: "Tiny on-device model that cleans up the live transcript")
        case .summaryLLM:
            String(localized: "Higher-quality summaries, titles and chat")
        }
    }

    /// nil for system-managed assets: size is unknown up front, so they
    /// never count toward the total label.
    var downloadBytes: Int64? {
        switch self {
        case .appleSpeech, .translationPacks: nil
        case .senseVoice: SenseVoiceModelStore.totalExpectedBytes
        case .diarizer: VoiceprintService.approximateDownloadBytes
        case .liveLLM: ModelCatalog.liveRefineModel.downloadBytes
        case .summaryLLM: ModelCatalog.qwen35_2b.downloadBytes
        }
    }

    var isRecommended: Bool {
        switch self {
        case .translationPacks, .senseVoice, .diarizer, .liveLLM, .summaryLLM: true
        case .appleSpeech: false
        }
    }

    var alwaysIncluded: Bool { self == .appleSpeech }

    var usesSystemAssetProgress: Bool {
        self == .appleSpeech || self == .translationPacks
    }

    var usesSharedLLMWorker: Bool {
        self == .liveLLM || self == .summaryLLM
    }

    func systemAssetProgressText(_ caption: String) -> String {
        switch self {
        case .appleSpeech:
            String(localized: "Downloading \(caption)…")
        case .translationPacks:
            String(localized: "Preparing \(caption)…")
        case .senseVoice, .diarizer, .liveLLM, .summaryLLM:
            caption
        }
    }

    /// Synchronous on-disk check. System assets report false — their status
    /// is async; the download loop fast-paths installed packs/locales.
    var isInstalled: Bool {
        switch self {
        case .appleSpeech, .translationPacks: false
        case .senseVoice: SenseVoiceModelStore.isInstalled
        case .diarizer: VoiceprintService.isOfflineDiarizerDownloaded
        case .liveLLM: LLMService.isDownloaded(model: ModelCatalog.liveRefineModel)
        case .summaryLLM: LLMService.isDownloaded(model: ModelCatalog.qwen35_2b)
        }
    }

    static var installedNow: Set<OnboardingItemKind> {
        Set(allCases.filter(\.isInstalled))
    }

    /// The recommended set the model step pre-checks.
    static var defaultSelection: Set<OnboardingItemKind> {
        [.translationPacks, .senseVoice, .diarizer, .liveLLM, .summaryLLM]
    }

    /// Translation packs are system-managed and checked asynchronously, so
    /// onboarding prepares every ordered v1 pair. Unsupported direct pairs
    /// are skipped; the coordinator will still pivot those through English.
    static var translationPairs: [LanguagePair] {
        AppLanguage.allCases.flatMap { source in
            AppLanguage.allCases.compactMap { target in
                source == target ? nil : LanguagePair(source: source, target: target)
            }
        }
    }

    /// Bytes still to fetch for the total label: checked items that aren't
    /// already on disk. System assets contribute nothing (downloadBytes nil).
    static func totalBytes(
        for selection: Set<OnboardingItemKind>,
        installed: Set<OnboardingItemKind>
    ) -> Int64 {
        allCases
            .filter { selection.contains($0) && !installed.contains($0) }
            .compactMap(\.downloadBytes)
            .reduce(0, +)
    }

    /// The work queue, in fixed `allCases` order: fallback engine first,
    /// then the small recommended models, the big LLM late, the optional
    /// extra last — quitting midway still leaves a working capture path.
    /// Installed items are dropped (the download step shows them as done
    /// without re-fetching).
    static func queueOrder(
        selection: Set<OnboardingItemKind>,
        installed: Set<OnboardingItemKind>
    ) -> [OnboardingItemKind] {
        allCases.filter {
            ($0.alwaysIncluded || selection.contains($0)) && !installed.contains($0)
        }
    }
}
