import Foundation
import os

/// On-disk files for sherpa-onnx offline speaker diarization: pyannote
/// segmentation-3.0 (frame-level speaker activity, overlap-aware) plus
/// 3D-Speaker's bilingual zh/en CAM++ embedding — chosen over the old
/// FluidAudio bundle because both files mirror to ModelScope and the
/// embedding is trained on exactly this app's two primary languages.
/// Same dual-source RemoteFile pattern as Qwen3ASRModelStore; downloads
/// go through the resumable, retrying ModelFileDownloader.
enum DiarizerModelStore {
    /// One file the diarizer needs. `name` is the local filename; the
    /// ModelScope paths are community mirrors verified byte-identical to
    /// the Hugging Face uploads (sizes checked 2026-07-05).
    struct RemoteFile: Sendable {
        let name: String
        let hfPath: String
        let modelScopePath: String
        /// Sanity floor — a finished file smaller than this is corrupt.
        let minBytes: Int64
        /// Real download size, for progress weighting and size readouts.
        let expectedBytes: Int64

        func path(for source: ASRModelSource) -> String {
            switch source {
            case .huggingFace: hfPath
            case .modelScope: modelScopePath
            }
        }
    }

    static let files: [RemoteFile] = [
        RemoteFile(
            name: "pyannote-segmentation-3-0.onnx",
            hfPath: "csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx",
            modelScopePath: "models/pengzhendong/sherpa-onnx-pyannote-segmentation-3-0/resolve/master/model.onnx",
            minBytes: 5_000_000,
            expectedBytes: 5_992_913),
        RemoteFile(
            name: "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx",
            hfPath: "csukuangfj/speaker-embedding-models/resolve/main/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx",
            modelScopePath: "models/fengge2024/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx/resolve/master/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx",
            minBytes: 25_000_000,
            expectedBytes: 28_281_164),
    ]

    static var totalExpectedBytes: Int64 {
        files.reduce(0) { $0 + $1.expectedBytes }
    }

    static var directory: URL {
        URL.applicationSupportDirectory.appending(
            path: "SpeakerDiarizer", directoryHint: .isDirectory)
    }

    static func fileURL(_ name: String) -> URL {
        directory.appending(path: name)
    }

    static var segmentationModelURL: URL { fileURL(files[0].name) }
    static var embeddingModelURL: URL { fileURL(files[1].name) }

    /// All files present and plausibly sized.
    static var isInstalled: Bool {
        files.allSatisfy { file in
            let url = fileURL(file.name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Int64(size) >= file.minBytes
        }
    }

    /// Persisted download source (Settings key predates the sherpa swap;
    /// the retired hfMirror value falls back to Hugging Face).
    static let sourceDefaultsKey = "diarizer.source"

    static var currentSource: ASRModelSource {
        ASRModelSource(
            rawValue: UserDefaults.standard.string(forKey: sourceDefaultsKey) ?? ""
        ) ?? .huggingFace
    }

    /// Launch-time migration: the retired DiarizerSource value "hfMirror"
    /// (pre-sherpa China-mainland onboarding) maps to ModelScope — same
    /// unreachable-Hugging-Face motivation, and without this the fallback
    /// would quietly send those users to huggingface.co AND leave the
    /// Settings picker with no matching selection.
    static func migrateStoredSource(defaults: UserDefaults = .standard) {
        if defaults.string(forKey: sourceDefaultsKey) == "hfMirror" {
            defaults.set(ASRModelSource.modelScope.rawValue, forKey: sourceDefaultsKey)
        }
    }

    /// Reclaim the pre-sherpa diarizer's orphaned model caches (Sortformer
    /// + the FluidAudio Pyannote bundle, ~100+ MB) — nothing reads them
    /// anymore. Safe to call every launch; a missing directory is a no-op.
    static func removeOrphanedFluidAudioCaches() {
        let fluidAudio = URL.applicationSupportDirectory.appending(
            path: "FluidAudio", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: fluidAudio.path) else { return }
        try? FileManager.default.removeItem(at: fluidAudio)
    }

    /// Download any missing files, sequentially, with size-weighted
    /// progress. Completed files are skipped, so this doubles as a resume.
    static func download(
        from source: ASRModelSource,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let totalWeight = totalExpectedBytes
        var doneWeight: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let final = fileURL(file.name)
            let existing = Int64(
                (try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if existing >= file.minBytes {
                doneWeight += file.expectedBytes
                onProgress?(Double(doneWeight) / Double(totalWeight))
                continue
            }
            let base = doneWeight
            let url = URL(string: "https://\(source.host)/\(file.path(for: source))")!
            try await ModelFileDownloader.download(
                url: url, to: final, expectedBytes: file.expectedBytes
            ) { bytes in
                let blended = Double(base) / Double(totalWeight)
                    + min(1, Double(bytes) / Double(file.expectedBytes))
                    * Double(file.expectedBytes) / Double(totalWeight)
                onProgress?(min(blended, 1))
            }
            let size = Int64(
                (try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard size >= file.minBytes else {
                try? FileManager.default.removeItem(at: final)
                throw URLError(.cannotParseResponse)
            }
            doneWeight += file.expectedBytes
            onProgress?(Double(doneWeight) / Double(totalWeight))
        }
    }
}
