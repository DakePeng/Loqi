import Foundation

/// The one region choice onboarding asks for: it fans out into the three
/// per-model source settings Settings manages individually. China mainland
/// maps the diarizer to HF-Mirror, not ModelScope — the FluidInference
/// CoreML repos are not mirrored there (see DiarizerSource).
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

    var diarizerSource: DiarizerSource {
        switch self {
        case .global: .huggingFace
        case .chinaMainland: .hfMirror
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
        defaults.set(diarizerSource.rawValue, forKey: DiarizerSource.defaultsKey)
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
    case llm
    case qwen3ASR

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleSpeech: String(localized: "Apple speech recognition")
        case .translationPacks: String(localized: "Translation language packs")
        case .senseVoice: String(localized: "SenseVoice live recognition")
        case .diarizer: String(localized: "Speaker recognition")
        case .llm: String(localized: "Qwen3.5 2B AI model")
        case .qwen3ASR: String(localized: "Qwen3-ASR re-transcription")
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
        case .llm:
            String(localized: "Translations, summaries, titles and chat")
        case .qwen3ASR:
            String(localized: "Slower, high-accuracy second pass for recordings")
        }
    }

    /// nil for system-managed assets: size is unknown up front, so they
    /// never count toward the total label.
    var downloadBytes: Int64? {
        switch self {
        case .appleSpeech, .translationPacks: nil
        case .senseVoice: SenseVoiceModelStore.totalExpectedBytes
        case .diarizer: StreamingDiarizer.approximateDownloadBytes
        case .llm: ModelCatalog.onboardingLLMBytes
        case .qwen3ASR: Qwen3ASRModelStore.totalExpectedBytes
        }
    }

    var isRecommended: Bool {
        switch self {
        case .translationPacks, .senseVoice, .diarizer, .llm: true
        case .appleSpeech, .qwen3ASR: false
        }
    }

    var alwaysIncluded: Bool { self == .appleSpeech }

    var usesSystemAssetProgress: Bool {
        self == .appleSpeech || self == .translationPacks
    }

    func systemAssetProgressText(_ caption: String) -> String {
        switch self {
        case .appleSpeech:
            String(localized: "Downloading \(caption)…")
        case .translationPacks:
            String(localized: "Preparing \(caption)…")
        case .senseVoice, .diarizer, .llm, .qwen3ASR:
            caption
        }
    }

    /// Synchronous on-disk check. System assets report false — their status
    /// is async; the download loop fast-paths installed packs/locales.
    var isInstalled: Bool {
        switch self {
        case .appleSpeech, .translationPacks: false
        case .senseVoice: SenseVoiceModelStore.isInstalled
        case .diarizer: StreamingDiarizer.isModelCached
        case .llm: LLMService.isDownloaded(model: ModelCatalog.default)
        case .qwen3ASR: Qwen3ASRModelStore.isInstalled
        }
    }

    static var installedNow: Set<OnboardingItemKind> {
        Set(allCases.filter(\.isInstalled))
    }

    /// The recommended set the model step pre-checks.
    static var defaultSelection: Set<OnboardingItemKind> {
        [.translationPacks, .senseVoice, .diarizer, .llm]
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
