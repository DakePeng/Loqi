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
    /// One file the recognizer needs. `name` is the path relative to
    /// `directory` — it doubles as the local layout. HF mirrors the
    /// official sherpa-onnx int8 package; ModelScope hosts a community
    /// conversion with identical file sizes (verified 2026-06).
    struct RemoteFile: Sendable {
        let name: String
        let hfPath: String
        let modelScopePath: String
        /// Sanity floor — a finished file smaller than this is corrupt.
        let minBytes: Int64
        /// Real download size, used to weight progress and show a size readout.
        let expectedBytes: Int64

        func path(for source: ASRModelSource) -> String {
            switch source {
            case .huggingFace: hfPath
            case .modelScope: modelScopePath
            }
        }
    }

    private nonisolated static let hfRepo =
        "csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25/resolve/main"
    private nonisolated static let msRepo =
        "models/zengshuishui/Qwen3-ASR-onnx/resolve/master"

    nonisolated static let files: [RemoteFile] = [
        RemoteFile(
            name: "conv_frontend.onnx",
            hfPath: "\(hfRepo)/conv_frontend.onnx",
            modelScopePath: "\(msRepo)/model_0.6B/conv_frontend.onnx",
            minBytes: 40_000_000,
            expectedBytes: 44_148_281),
        RemoteFile(
            name: "encoder.int8.onnx",
            hfPath: "\(hfRepo)/encoder.int8.onnx",
            modelScopePath: "\(msRepo)/model_0.6B/encoder.int8.onnx",
            minBytes: 160_000_000,
            expectedBytes: 182_491_662),
        RemoteFile(
            name: "decoder.int8.onnx",
            hfPath: "\(hfRepo)/decoder.int8.onnx",
            modelScopePath: "\(msRepo)/model_0.6B/decoder.int8.onnx",
            minBytes: 700_000_000,
            expectedBytes: 755_914_231),
        RemoteFile(
            name: "tokenizer/vocab.json",
            hfPath: "\(hfRepo)/tokenizer/vocab.json",
            modelScopePath: "\(msRepo)/tokenizer/vocab.json",
            minBytes: 2_000_000,
            expectedBytes: 2_776_833),
        RemoteFile(
            name: "tokenizer/merges.txt",
            hfPath: "\(hfRepo)/tokenizer/merges.txt",
            modelScopePath: "\(msRepo)/tokenizer/merges.txt",
            minBytes: 1_200_000,
            expectedBytes: 1_671_853),
        RemoteFile(
            name: "tokenizer/tokenizer_config.json",
            hfPath: "\(hfRepo)/tokenizer/tokenizer_config.json",
            modelScopePath: "\(msRepo)/tokenizer/tokenizer_config.json",
            minBytes: 8_000,
            expectedBytes: 12_487),
        // Own VAD copy: the post-pass must not depend on the SenseVoice
        // store being installed. Same upstream files SenseVoice fetches.
        RemoteFile(
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
        files.allSatisfy { file in
            let url = fileURL(file.name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Int64(size) >= file.minBytes
        }
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
        try? FileManager.default.createDirectory(
            at: Self.directory, withIntermediateDirectories: true)

        let totalWeight = Self.files.reduce(0) { $0 + $1.expectedBytes }
        var doneWeight: Int64 = 0
        for file in Self.files {
            do {
                try Task.checkCancellation()
                let base = doneWeight
                try await fetch(file, from: source) { [weak self] fileFraction in
                    let blended = Double(base) / Double(totalWeight)
                        + fileFraction * Double(file.expectedBytes) / Double(totalWeight)
                    self?.progress = min(blended, 1)
                }
                doneWeight += file.expectedBytes
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch {
                logger.error("download \(file.name) failed: \(error)")
                lastError = String(
                    localized: "Download failed — check your connection and try again.")
                return
            }
        }
        progress = 1
    }

    /// Download one file through the segmented downloader: parallel Range
    /// connections for the big decoder, one stream for the small files.
    /// Retries, .part checkpointing, and cross-launch resume live there.
    private func fetch(
        _ file: RemoteFile,
        from source: ASRModelSource,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let final = Self.fileURL(file.name)
        if let size = try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(size) >= file.minBytes {
            onProgress(1)
            return
        }
        // Relative names can carry a subdirectory (tokenizer/…).
        try FileManager.default.createDirectory(
            at: final.deletingLastPathComponent(), withIntermediateDirectories: true)

        let url = URL(string: "https://\(source.host)/\(file.path(for: source))")!
        try await ModelFileDownloader.download(
            url: url, to: final, expectedBytes: file.expectedBytes
        ) { bytes in
            let fraction = min(1, Double(bytes) / Double(file.expectedBytes))
            Task { @MainActor in onProgress(fraction) }
        }

        let size = Int64(
            (try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size >= file.minBytes else {
            try? FileManager.default.removeItem(at: final)
            throw URLError(.cannotParseResponse)
        }
        onProgress(1)
    }
}
