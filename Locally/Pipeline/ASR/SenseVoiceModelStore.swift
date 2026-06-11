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

    /// Download one file with Range-resume via a .part checkpoint and
    /// 3 attempts with backoff. HF/HF-Mirror honor Range correctly.
    private func fetch(
        _ file: RemoteFile,
        from source: ASRModelSource,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let final = Self.fileURL(file.name)
        if let size = try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           Int64(size) >= file.minBytes {
            await onProgress(1)
            return
        }

        let url = URL(string: "https://\(source.host)/\(file.path(for: source))")!
        let part = Self.directory.appending(path: "\(file.name).part")
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await downloadResuming(url: url, to: part, onProgress: onProgress)
                let size = (try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard Int64(size) >= file.minBytes else {
                    try? FileManager.default.removeItem(at: part)
                    throw URLError(.cannotParseResponse)
                }
                try? FileManager.default.removeItem(at: final)
                try FileManager.default.moveItem(at: part, to: final)
                return
            } catch {
                guard attempt < 3 else { throw error }
                logger.info("retrying \(file.name) (attempt \(attempt + 1))")
                try await Task.sleep(for: .seconds(Double(attempt) * 2))
            }
        }
    }

    private func downloadResuming(
        url: URL, to part: URL,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let existing = Int64(
            (try? part.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var request = URLRequest(url: url)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        // 200 despite a Range request = server restarted from zero; any
        // partial data is stale.
        var offset = existing
        if http.statusCode == 200, existing > 0 {
            try? FileManager.default.removeItem(at: part)
            offset = 0
        }
        let expectedTotal = offset + max(http.expectedContentLength, 1)

        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written = offset
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                await onProgress(Double(written) / Double(expectedTotal))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        await onProgress(1)
    }
}
