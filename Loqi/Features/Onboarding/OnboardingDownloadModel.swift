import Foundation
import Observation
import SwiftUI

/// Drives the onboarding download step. Apple-managed system assets run
/// one-at-a-time because their download UI lives in OS frameworks; app-owned
/// models run in parallel so first setup is not artificially serialized.
/// Every download goes through the same path Settings or Apple's system APIs
/// use, so skipped model downloads resume from partial files and system packs
/// can prompt again on first use.
@MainActor
@Observable
final class OnboardingDownloadModel {
    enum Status: Equatable {
        case pending
        case downloading
        case done
        case skipped
        case failed(String)

        var isSettled: Bool {
            switch self {
            case .done, .skipped, .failed: true
            case .pending, .downloading: false
            }
        }
    }

    /// A class so each row's speedometer keeps its identity across status
    /// changes (DownloadSpeedometer accumulates rate samples). Nested types
    /// don't inherit the outer @MainActor, so it's restated — which also
    /// makes Item Sendable for the download progress closures.
    @MainActor
    @Observable
    final class Item: Identifiable {
        let kind: OnboardingItemKind
        var status: Status = .pending
        let speedometer = DownloadSpeedometer()
        /// System-asset rows only: overall fraction across languages/pairs
        /// and the one currently downloading. These assets have no byte
        /// sizes, so the speedometer doesn't apply.
        var assetFraction: Double = 0
        var assetCaption: String?

        init(kind: OnboardingItemKind) {
            self.kind = kind
        }
    }

    private(set) var items: [Item] = []

    /// Exposed so the download step can mirror SettingsView's
    /// `.onChange(of: store.progress)` wiring.
    let senseVoiceStore = SenseVoiceModelStore()
    let qwen3Store = Qwen3ASRModelStore()

    private let pipeline: CaptionPipeline
    private let assets = AssetManager()
    private var region = DownloadRegion.global
    private var systemAssetQueue: [OnboardingItemKind] = []
    private var systemAssetWorker: Task<Void, Never>?
    private var modelWorkers: [OnboardingItemKind: Task<Void, Never>] = [:]
    private var llmQueue: [OnboardingItemKind] = []
    private var llmWorker: Task<Void, Never>?
    private var translationContinuation: CheckedContinuation<Void, Error>?
    private var translationTimeout: Task<Void, Never>?
    private(set) var translationPreparationPair: LanguagePair?
    private let translationPreparationTimeout: Duration = .seconds(60)

    init(pipeline: CaptionPipeline) {
        self.pipeline = pipeline
    }

    var allSettled: Bool {
        !items.isEmpty && items.allSatisfy(\.status.isSettled)
    }

    /// Anything to point the "get them in Settings" caption at.
    var anyUnfinished: Bool {
        items.contains { $0.status != .done && $0.status.isSettled }
    }

    func item(for kind: OnboardingItemKind) -> Item? {
        items.first { $0.kind == kind }
    }

    func start(selection: Set<OnboardingItemKind>, region: DownloadRegion) {
        guard items.isEmpty else { return }
        self.region = region

        let installed = OnboardingItemKind.installedNow
        items = OnboardingItemKind.allCases
            .filter { $0.alwaysIncluded || selection.contains($0) }
            .map(Item.init)
        for item in items where installed.contains(item.kind) {
            item.status = .done
        }
        // A previous aborted run may have downloaded SenseVoice but died
        // before the engine write. The rule: SenseVoice selected and settled
        // done ⇒ it becomes the live engine.
        if selection.contains(.senseVoice), installed.contains(.senseVoice) {
            UserDefaults.standard.set("sensevoice", forKey: "asr.engine")
        }

        let pending = OnboardingItemKind.queueOrder(selection: selection, installed: installed)
        systemAssetQueue = pending.filter(\.usesSystemAssetProgress)
        startSystemAssetWorkerIfNeeded()
        for kind in pending where !kind.usesSystemAssetProgress {
            if kind.usesSharedLLMWorker {
                llmQueue.append(kind)
            } else {
                startModelWorker(for: kind)
            }
        }
        startLLMWorkerIfNeeded()
    }

    /// Failed rows only: system assets go behind the current system asset;
    /// app-owned models restart independently.
    func retry(_ kind: OnboardingItemKind) {
        guard let item = item(for: kind), case .failed = item.status else { return }
        item.status = .pending
        if kind.usesSystemAssetProgress {
            systemAssetQueue.append(kind)
            startSystemAssetWorkerIfNeeded()
        } else if kind.usesSharedLLMWorker {
            llmQueue.append(kind)
            startLLMWorkerIfNeeded()
        } else {
            startModelWorker(for: kind)
        }
    }

    /// Settles every unfinished row immediately so the finish button appears.
    /// The diarizer and system assets have no cancel API — their in-flight
    /// task may complete in the background, which only populates caches the
    /// app wants anyway.
    func skipRemaining() {
        systemAssetQueue.removeAll()
        systemAssetWorker?.cancel()
        systemAssetWorker = nil
        llmQueue.removeAll()
        llmWorker?.cancel()
        llmWorker = nil
        modelWorkers.values.forEach { $0.cancel() }
        modelWorkers.removeAll()
        senseVoiceStore.cancelDownload()
        qwen3Store.cancelDownload()
        cancelTranslationPreparation()
        let llm = pipeline.llm
        Task { await llm.cancelLoad() }
        for item in items where !item.status.isSettled {
            item.status = .skipped
        }
    }

    private func startSystemAssetWorkerIfNeeded() {
        guard systemAssetWorker == nil else { return }
        systemAssetWorker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !systemAssetQueue.isEmpty {
                let kind = systemAssetQueue.removeFirst()
                guard let item = item(for: kind), item.status == .pending else { continue }
                item.status = .downloading
                await download(kind, into: item)
            }
            systemAssetWorker = nil
        }
    }

    private func startLLMWorkerIfNeeded() {
        guard llmWorker == nil, !llmQueue.isEmpty else { return }
        llmWorker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !llmQueue.isEmpty {
                let kind = llmQueue.removeFirst()
                guard let item = item(for: kind), item.status == .pending else { continue }
                item.status = .downloading
                await download(kind, into: item)
            }
            llmWorker = nil
        }
    }

    private func startModelWorker(for kind: OnboardingItemKind) {
        guard !kind.usesSystemAssetProgress,
              !kind.usesSharedLLMWorker,
              modelWorkers[kind] == nil,
              let item = item(for: kind),
              item.status == .pending else { return }
        item.status = .downloading
        modelWorkers[kind] = Task { [weak self, weak item] in
            guard let self, let item else { return }
            await download(kind, into: item)
            modelWorkers[kind] = nil
        }
    }

    private func download(_ kind: OnboardingItemKind, into item: Item) async {
        switch kind {
        case .appleSpeech: await downloadAppleAssets(item)
        case .translationPacks: await downloadTranslationPacks(item)
        case .senseVoice: await downloadSenseVoice(item)
        case .diarizer: await downloadDiarizer(item)
        case .liveLLM: await downloadSingleLLM(item, model: ModelCatalog.liveRefineModel)
        case .summaryLLM: await downloadSingleLLM(item, model: ModelCatalog.qwen35_2b)
        case .qwen3ASR: await downloadQwen3ASR(item)
        }
    }

    /// Port of the old onboarding assets step: every app language in turn,
    /// `.unsupported` counts as settled, already-installed locales fast-path
    /// (which is what makes Retry resume where it left off).
    private func downloadAppleAssets(_ item: Item) async {
        let languages = AppLanguage.allCases
        var anyFailure = false
        for (index, language) in languages.enumerated() {
            let base = Double(index) / Double(languages.count)
            item.assetFraction = base
            item.assetCaption = language.displayName
            switch await assets.speechAssetStatus(for: language) {
            case .installed, .unsupported:
                continue
            case .downloadRequired:
                do {
                    try await assets.installSpeechAssets(for: language) { fraction in
                        Task { @MainActor in
                            item.assetFraction = base + fraction / Double(languages.count)
                        }
                    }
                } catch {
                    anyFailure = true
                }
            }
        }
        item.assetFraction = 1
        item.assetCaption = nil
        item.status = anyFailure
            ? .failed(String(
                localized: "Some languages didn’t download — check your connection."))
            : .done
    }

    /// Translation packs can only be prepared through SwiftUI's
    /// `.translationTask`, so this method coordinates with the hidden host
    /// view in OnboardingDownloadStep one pair at a time.
    private func downloadTranslationPacks(_ item: Item) async {
        let pairs = OnboardingItemKind.translationPairs
        var anyFailure = false

        for (index, pair) in pairs.enumerated() {
            if Task.isCancelled {
                item.status = .skipped
                return
            }

            let base = Double(index) / Double(pairs.count)
            item.assetFraction = base
            item.assetCaption = pair.displayName

            switch await assets.translationStatus(for: pair) {
            case .installed, .unsupported:
                continue
            case .supported:
                do {
                    try await prepareTranslationPack(for: pair)
                } catch is CancellationError {
                    item.status = .skipped
                    return
                } catch {
                    anyFailure = true
                }
            @unknown default:
                anyFailure = true
            }
        }

        item.assetFraction = 1
        item.assetCaption = nil
        item.status = anyFailure
            ? .failed(String(
                localized: "Some translation packs didn’t download — check your connection."))
            : .done
    }

    private func prepareTranslationPack(for pair: LanguagePair) async throws {
        try await withCheckedThrowingContinuation { continuation in
            translationContinuation = continuation
            translationPreparationPair = pair
            translationTimeout?.cancel()
            let timeout = translationPreparationTimeout
            translationTimeout = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await MainActor.run {
                    self?.completeTranslationPreparation(
                        for: pair,
                        errorMessage: String(localized: "Translation pack download timed out."))
                }
            }
        }
    }

    func completeTranslationPreparation(for pair: LanguagePair, errorMessage: String?) {
        guard pair == translationPreparationPair,
              let continuation = translationContinuation else { return }
        translationContinuation = nil
        translationPreparationPair = nil
        translationTimeout?.cancel()
        translationTimeout = nil

        if let errorMessage {
            continuation.resume(throwing: TranslationPackDownloadError.failed(errorMessage))
        } else {
            continuation.resume()
        }
    }

    private func cancelTranslationPreparation() {
        translationPreparationPair = nil
        translationTimeout?.cancel()
        translationTimeout = nil
        guard let continuation = translationContinuation else { return }
        translationContinuation = nil
        continuation.resume(throwing: CancellationError())
    }

    private func downloadSenseVoice(_ item: Item) async {
        item.speedometer.start(totalBytes: SenseVoiceModelStore.totalExpectedBytes)
        await senseVoiceStore.download(from: region.asrSource)
        if SenseVoiceModelStore.isInstalled {
            item.status = .done
            UserDefaults.standard.set("sensevoice", forKey: "asr.engine")
        } else if let error = senseVoiceStore.lastError {
            item.status = .failed(error)
        } else {
            // download(from:) returns silently after cancelDownload().
            item.status = .skipped
        }
    }

    private func downloadQwen3ASR(_ item: Item) async {
        item.speedometer.start(totalBytes: Qwen3ASRModelStore.totalExpectedBytes)
        await qwen3Store.download(from: region.asrSource)
        if Qwen3ASRModelStore.isInstalled {
            item.status = .done
        } else if let error = qwen3Store.lastError {
            item.status = .failed(error)
        } else {
            item.status = .skipped
        }
    }

    private func downloadDiarizer(_ item: Item) async {
        item.speedometer.start(totalBytes: VoiceprintService.approximateDownloadBytes)
        do {
            try await VoiceprintService.downloadModels(source: region.diarizerSource) { fraction in
                Task { @MainActor in item.speedometer.update(fraction) }
            }
            item.status = .done
        } catch is CancellationError {
            item.status = .skipped
        } catch {
            item.status = .failed(error.localizedDescription)
        }
    }

    /// One LLM tier in isolation: bytes to disk, then unloaded — onboarding
    /// wants the file present, not 0.8/1.75 GB resident while later items
    /// (the other tier, Qwen3-ASR) may still download. The pipeline warm-loads
    /// lazily when a session needs it.
    private func downloadSingleLLM(_ item: Item, model: ModelOption) async {
        item.speedometer.start(totalBytes: model.downloadBytes)
        let llm = pipeline.llm
        // The shared pipeline was constructed before the region step wrote
        // the source keys — sync the actor like SettingsView's .task does.
        await llm.setSource(region.llmSource)
        await llm.setModel(model)
        do {
            try await llm.load { fraction in
                Task { @MainActor in item.speedometer.update(fraction) }
            }
            await llm.unload()
            if LLMService.isDownloaded(model: model) {
                item.speedometer.update(1)
                item.status = .done
            } else {
                item.status = .failed("Download incomplete")
            }
        } catch is CancellationError {
            await llm.unload()
            item.status = .skipped
        } catch {
            await llm.unload()
            // Tolerate a late error if the bytes actually landed.
            item.status = LLMService.isDownloaded(model: model)
                ? .done
                : .failed(error.localizedDescription)
        }
    }
}

private enum TranslationPackDownloadError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        }
    }
}
