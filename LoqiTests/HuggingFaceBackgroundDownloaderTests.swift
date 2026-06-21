import Foundation
import Testing
@testable import Loqi

struct HuggingFaceBackgroundDownloaderTests {
    let downloader = HuggingFaceBackgroundDownloader()

    @Test func matchesPathOrFileName() {
        #expect(downloader.matches("model-00001-of-00002.safetensors", patterns: ["*.safetensors"]))
        #expect(downloader.matches("tokenizer/tokenizer.json", patterns: ["tokenizer/*.json"]))
        #expect(downloader.matches("config.json", patterns: ["*.json"]))
        #expect(!downloader.matches("notes.md", patterns: ["*.json"]))
    }

    @Test func manifestValidationRejectsMissingFile() throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try downloader.writeManifest(
            [HuggingFaceBackgroundDownloader.FileEntry(path: "weights.safetensors", size: 10)],
            to: dir)

        #expect(!downloader.isValidSnapshot(dir))
    }

    @Test func manifestValidationAcceptsMatchingSizes() throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data(count: 10).write(to: dir.appending(path: "weights.safetensors"))
        try downloader.writeManifest(
            [HuggingFaceBackgroundDownloader.FileEntry(path: "weights.safetensors", size: 10)],
            to: dir)

        #expect(downloader.isValidSnapshot(dir))
    }
}
