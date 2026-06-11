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
    /// One file the engine needs. The HF and ModelScope repos hold the same
    /// bytes but differ in owner/revision, so each source has its own path
    /// (already including the host-specific prefix).
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

    nonisolated static let files: [RemoteFile] = [
        RemoteFile(
            name: "model.int8.onnx",
            hfPath: "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx",
            modelScopePath: "models/mariolux/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/master/model.int8.onnx",
            minBytes: 200_000_000,
            expectedBytes: 239_233_841),
        RemoteFile(
            name: "tokens.txt",
            hfPath: "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt",
            modelScopePath: "models/mariolux/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/master/tokens.txt",
            minBytes: 100_000,
            expectedBytes: 320_000),
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
        URL.applicationSupportDirectory.appending(path: "SenseVoice", directoryHint: .isDirectory)
    }

    nonisolated static func fileURL(_ name: String) -> URL {
        directory.appending(path: name)
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

    private let logger = Logger(subsystem: "com.kunzhipeng.locally", category: "sensevoice")

    func download(from source: ASRModelSource) async {
        guard !downloading else { return }
        downloading = true
        lastError = nil
        progress = 0
        defer { downloading = false }

        try? FileManager.default.createDirectory(
            at: Self.directory, withIntermediateDirectories: true)

        let totalWeight = Self.files.reduce(0) { $0 + $1.expectedBytes }
        var doneWeight: Int64 = 0
        for file in Self.files {
            do {
                let base = doneWeight
                try await fetch(file, from: source) { [weak self] fileFraction in
                    let blended = Double(base) / Double(totalWeight)
                        + fileFraction * Double(file.expectedBytes) / Double(totalWeight)
                    self?.progress = min(blended, 1)
                }
                doneWeight += file.expectedBytes
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
    /// connections for the big recognizer, one stream for the small files.
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

        let url = URL(string: "https://\(source.host)/\(file.path(for: source))")!
        try await SegmentedDownloader().download(
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
