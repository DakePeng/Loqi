import Foundation
import Observation
import os

/// Manages the on-disk Qwen3-ASR-0.6B files — the high-accuracy
/// post-processing recognizer behind "Re-transcribe & summarize" and
/// imports (a Speech-LLM: Whisper-style encoder → Qwen3-0.6B decoder, one
/// model for all four app languages). Install-state detection plus the
/// same resumable, retrying downloader SenseVoice uses.
///
/// sherpa-onnx loads the onnx files straight from `directory`; the
/// tokenizer files live in a `tokenizer/` subdirectory because the
/// recognizer config takes that directory's path (see the official
/// swift-api example).
@MainActor
@Observable
final class Qwen3ASRModelStore {
    // HF mirrors the official sherpa-onnx int8 package; ModelScope hosts a
    // community conversion with identical file sizes (verified 2026-06).

    private nonisolated static let hfRepo =
        "csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/main"
    private nonisolated static let msRepo =
        "models/zengshuishui/Qwen3-ASR-onnx/resolve/master"

    nonisolated static let files: [ModelRemoteFile] = [
        ModelRemoteFile(
            name: "conv_frontend.onnx",
            hfPath: "\(hfRepo)/conv_frontend.onnx",
            modelScopePath: "\(msRepo)/model_0.6B/conv_frontend.onnx",
            minBytes: 40_000_000,
            expectedBytes: 44_148_281),
        ModelRemoteFile(
            name: "encoder.int8.onnx",
            hfPath: "\(hfRepo)/encoder.int8.onnx",
            modelScopePath: "\(msRepo)/model_0.6B/encoder.int8.onnx",
            minBytes: 160_000_000,
            expectedBytes: 182_491_662),
        ModelRemoteFile(
            name: "decoder.int8.onnx",
            hfPath: "\(hfRepo)/decoder.int8.onnx",
            modelScopePath: "\(msRepo)/model_0.6B/decoder.int8.onnx",
            minBytes: 700_000_000,
            expectedBytes: 755_914_231),
        ModelRemoteFile(
            name: "tokenizer/vocab.json",
            hfPath: "\(hfRepo)/tokenizer/vocab.json",
            modelScopePath: "\(msRepo)/tokenizer/vocab.json",
            minBytes: 2_000_000,
            expectedBytes: 2_776_833),
        ModelRemoteFile(
            name: "tokenizer/merges.txt",
            hfPath: "\(hfRepo)/tokenizer/merges.txt",
            modelScopePath: "\(msRepo)/tokenizer/merges.txt",
            minBytes: 1_200_000,
            expectedBytes: 1_671_853),
        ModelRemoteFile(
            name: "tokenizer/tokenizer_config.json",
            hfPath: "\(hfRepo)/tokenizer/tokenizer_config.json",
            modelScopePath: "\(msRepo)/tokenizer/tokenizer_config.json",
            minBytes: 8_000,
            expectedBytes: 12_487),
        // Own VAD copy: the post-pass must not depend on the SenseVoice
        // store being installed. Same upstream files SenseVoice fetches.
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
        URL.applicationSupportDirectory.appending(path: "Qwen3ASR", directoryHint: .isDirectory)
    }

    nonisolated static func fileURL(_ name: String) -> URL {
        directory.appending(path: name)
    }

    /// The directory the recognizer's `tokenizer:` config field points at.
    nonisolated static var tokenizerDirectory: URL {
        directory.appending(path: "tokenizer", directoryHint: .isDirectory)
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
    private let logger = Logger(subsystem: "com.kunzhipeng.loqi", category: "qwen3asr")

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
