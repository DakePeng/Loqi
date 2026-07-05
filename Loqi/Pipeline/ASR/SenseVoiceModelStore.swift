import Foundation
import Observation
import os

/// Download source for the SenseVoice recognition models. ModelScope 魔搭
/// hosts community mirrors of the exact sherpa-onnx files (byte-identical)
/// and is reachable in China; its `resolve/master` CDN honors Range, so the
/// resumable downloader works unchanged.
enum ASRModelSource: String, CaseIterable, Identifiable {
    case modelScope
    case huggingFace

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .modelScope: "ModelScope 魔搭"
        case .huggingFace: "Hugging Face"
        }
    }

    var host: String {
        switch self {
        case .modelScope: "www.modelscope.cn"
        case .huggingFace: "huggingface.co"
        }
    }
}

/// Manages the on-disk SenseVoice model files (recognizer + silero VAD):
/// install-state detection and a resumable, retrying downloader.
/// sherpa-onnx loads the files straight from `directory`.
@MainActor
@Observable
final class SenseVoiceModelStore {
    nonisolated static let files: [ModelRemoteFile] = [
        ModelRemoteFile(
            name: "model.int8.onnx",
            hfPath: "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx",
            modelScopePath: "models/mariolux/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/master/model.int8.onnx",
            minBytes: 200_000_000,
            expectedBytes: 239_233_841),
        ModelRemoteFile(
            name: "tokens.txt",
            hfPath: "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt",
            modelScopePath: "models/mariolux/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/master/tokens.txt",
            minBytes: 100_000,
            expectedBytes: 320_000),
        ModelRemoteFile(
            name: "silero_vad.onnx",
            hfPath: "csukuangfj/vad/resolve/main/silero_vad.onnx",
            modelScopePath: "models/manyeyes/silero-vad-onnx/resolve/master/silero_vad.onnx",
            minBytes: 1_000_000,
            expectedBytes: 1_807_522),
    ]

    /// Total download size across all files, for the progress readout.
    nonisolated static var totalExpectedBytes: Int64 {
        files.reduce(0) { $0 + $1.expectedBytes }
    }

    nonisolated static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "SenseVoice", directoryHint: .isDirectory)
    }

    nonisolated static func fileURL(_ name: String) -> URL {
        directory.appending(path: name)
    }

    /// All files present and plausibly sized.
    nonisolated static var isInstalled: Bool {
        ModelFileDownloader.allInstalled(files, in: directory)
    }

    private(set) var downloading = false
    /// 0…1 across all files, weighted by expected size.
    private(set) var progress: Double = 0
    private(set) var lastError: String?

    private var downloadTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "sensevoice")

    func download(from source: ASRModelSource) async {
        guard !downloading else { return }
        downloading = true
        lastError = nil
        progress = 0
        // Run in an owned task so Stop can cancel it; completed-file
        // checkpoints stay on disk and a later download resumes.
        let task = Task { await performDownload(from: source) }
        downloadTask = task
        await task.value
        downloadTask = nil
        downloading = false
    }

    /// User-initiated stop; not an error. Partial files remain for resume.
    func cancelDownload() {
        downloadTask?.cancel()
    }

    private func performDownload(from source: ASRModelSource) async {
        do {
            // Shared manifest loop: skip-completed resume, per-file
            // verify-or-delete, size-weighted progress.
            try await ModelFileDownloader.downloadAll(
                Self.files, to: Self.directory, from: source
            ) { [weak self] blended in
                Task { @MainActor in self?.progress = blended }
            }
            progress = 1
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            logger.error("download failed: \(error)")
            lastError = String(
                localized: "Download failed — check your connection and try again.")
        }
    }
}
