import Foundation
import Observation
import SwiftUI

/// Drives the onboarding download step: one strictly sequential queue over
/// the selected items with per-item status, retry for failures, and a
/// skip-remaining escape hatch. Every download goes through the exact path
/// Settings uses, so anything skipped or failed here resumes there from its
/// partial files.
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
        /// Apple-assets row only: overall fraction across the languages and
        /// the one currently downloading (system assets have no byte sizes,
        /// so the speedometer doesn't apply).
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
    private var queue: [OnboardingItemKind] = []
    private var worker: Task<Void, Never>?

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

        queue = OnboardingItemKind.queueOrder(selection: selection, installed: installed)
        startWorkerIfNeeded()
    }

    /// Failed rows only: back into the queue, behind whatever is running.
    func retry(_ kind: OnboardingItemKind) {
        guard let item = item(for: kind), case .failed = item.status else { return }
        item.status = .pending
        queue.append(kind)
        startWorkerIfNeeded()
    }

    /// Settles every unfinished row immediately so the finish button appears.
    /// The diarizer and Apple assets have no cancel API — their in-flight
    /// task may complete in the background, which only populates caches the
    /// app wants anyway.
    func skipRemaining() {
        queue.removeAll()
        worker?.cancel()
        senseVoiceStore.cancelDownload()
        qwen3Store.cancelDownload()
        let llm = pipeline.llm
        Task { await llm.cancelLoad() }
        for item in items where !item.status.isSettled {
            item.status = .skipped
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task {
            while !Task.isCancelled, !queue.isEmpty {
                let kind = queue.removeFirst()
                guard let item = item(for: kind), item.status == .pending else { continue }
                item.status = .downloading
                await download(kind, into: item)
            }
            worker = nil
        }
    }

    private func download(_ kind: OnboardingItemKind, into item: Item) async {
        switch kind {
        case .appleSpeech: await downloadAppleAssets(item)
        case .senseVoice: await downloadSenseVoice(item)
        case .diarizer: await downloadDiarizer(item)
        case .llm: await downloadLLM(item)
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
            try await pipeline.voiceprint.loadIfNeeded(source: region.diarizerSource) { fraction in
                Task { @MainActor in item.speedometer.update(fraction) }
            }
            // Loaded as a side effect — small (CoreML), leave it warm like
            // Settings does.
            item.status = .done
        } catch is CancellationError {
            item.status = .skipped
        } catch {
            item.status = .failed(error.localizedDescription)
        }
    }

    private func downloadLLM(_ item: Item) async {
        item.speedometer.start(totalBytes: ModelCatalog.default.downloadBytes)
        let llm = pipeline.llm
        // The shared pipeline was constructed before the region step wrote
        // the source keys — sync the actor like SettingsView's .task does.
        await llm.setModel(ModelCatalog.default)
        await llm.setSource(region.llmSource)
        do {
            try await llm.load { fraction in
                Task { @MainActor in item.speedometer.update(fraction) }
            }
            // Onboarding wants bytes on disk, not 1.5 GB resident while
            // Qwen3-ASR may still download next; the pipeline warm-loads
            // lazily when a session needs it.
            await llm.unload()
            item.status = .done
        } catch {
            if LLMService.isDownloaded(model: ModelCatalog.default) {
                // Weights completed (the marker is written when the
                // downloader returns); only the load-into-memory stage
                // failed — e.g. the simulator, where MLX cannot run.
                await llm.unload()
                item.status = .done
            } else if error is CancellationError {
                item.status = .skipped
            } else {
                item.status = .failed(error.localizedDescription)
            }
        }
    }
}
