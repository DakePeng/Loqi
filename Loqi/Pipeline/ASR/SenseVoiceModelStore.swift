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

    // Shared download shell (state + cancel-able task); forwarding keeps
    // every call site and observation untouched.
    private let downloads = ModelStoreDownloads(
        files: files, directory: directory, logCategory: "sensevoice")
    var downloading: Bool { downloads.downloading }
    var progress: Double { downloads.progress }
    var lastError: String? { downloads.lastError }
    func download(from source: ASRModelSource) async { await downloads.download(from: source) }
    func cancelDownload() { downloads.cancelDownload() }
}

/// Manages the on-disk Dolphin-small CTC files — the high-accuracy tier
/// behind Re-transcribe/imports and the hybrid engine's live finals:
/// non-autoregressive, so a decode pool chews through a file far faster
/// than realtime. Eastern languages only (中文/日本語/한국어 here) —
/// never offered for English.
/// ponytail: hosted in this file, not its own, so the xcodegen-generated
/// pbxproj (which has pending local edits) needn't change; split it out
/// on the next project regen.
@MainActor
@Observable
final class DolphinModelStore {
    nonisolated static let files: [ModelRemoteFile] = [
        ModelRemoteFile(
            name: "model.int8.onnx",
            hfPath: "csukuangfj/sherpa-onnx-dolphin-small-ctc-multi-lang-int8-2025-04-02/resolve/main/model.int8.onnx",
            modelScopePath: "models/csukuangfj/sherpa-onnx-dolphin-small-ctc-multi-lang-int8-2025-04-02/resolve/master/model.int8.onnx",
            minBytes: 200_000_000,
            expectedBytes: 249_658_954),
        ModelRemoteFile(
            name: "tokens.txt",
            hfPath: "csukuangfj/sherpa-onnx-dolphin-small-ctc-multi-lang-int8-2025-04-02/resolve/main/tokens.txt",
            modelScopePath: "models/csukuangfj/sherpa-onnx-dolphin-small-ctc-multi-lang-int8-2025-04-02/resolve/master/tokens.txt",
            minBytes: 300_000,
            expectedBytes: 504_662),
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
        URL.applicationSupportDirectory.appending(path: "Dolphin", directoryHint: .isDirectory)
    }

    nonisolated static func fileURL(_ name: String) -> URL {
        directory.appending(path: name)
    }

    /// All files present and plausibly sized.
    nonisolated static var isInstalled: Bool {
        ModelFileDownloader.allInstalled(files, in: directory)
    }

    // Shared download shell (state + cancel-able task); forwarding keeps
    // every call site and observation untouched.
    private let downloads = ModelStoreDownloads(
        files: files, directory: directory, logCategory: "dolphin")
    var downloading: Bool { downloads.downloading }
    var progress: Double { downloads.progress }
    var lastError: String? { downloads.lastError }
    func download(from source: ASRModelSource) async { await downloads.download(from: source) }
    func cancelDownload() { downloads.cancelDownload() }

    /// Removes the installed files — also how the user leaves Dolphin:
    /// with it gone, backend selection returns to SenseVoice/Apple.
    func removeInstalled() {
        try? FileManager.default.removeItem(at: Self.directory)
    }
}
