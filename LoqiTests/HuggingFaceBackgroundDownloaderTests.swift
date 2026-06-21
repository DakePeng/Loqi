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

    @Test func manifestValidationRejectsMissingSelectedFile() throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data(count: 2).write(to: dir.appending(path: "config.json"))
        try downloader.writeManifest(
            [HuggingFaceBackgroundDownloader.FileEntry(path: "config.json", size: 2)],
            to: dir)

        let selected = [
            HuggingFaceBackgroundDownloader.FileEntry(path: "config.json", size: 2),
            HuggingFaceBackgroundDownloader.FileEntry(path: "weights.safetensors", size: 10),
        ]
        #expect(!downloader.isValidSnapshot(dir, for: selected))
    }

    @Test func metadataManifestValidatesOwnSnapshotWithoutRemoteList() throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = [
            HuggingFaceBackgroundDownloader.FileEntry(path: "config.json", size: 2),
            HuggingFaceBackgroundDownloader.FileEntry(path: "weights.safetensors", size: 10),
        ]
        try Data(count: 2).write(to: dir.appending(path: "config.json"))
        try Data(count: 10).write(to: dir.appending(path: "weights.safetensors"))
        try downloader.writeManifest(files, to: dir, revision: "main", patterns: ["*.json", "*.safetensors"])

        #expect(downloader.isValidSnapshot(dir, revision: "main", patterns: ["*.json", "*.safetensors"]))
        #expect(!downloader.isValidSnapshot(dir, revision: "dev", patterns: ["*.json", "*.safetensors"]))
        #expect(!downloader.isValidSnapshot(dir, revision: "main", patterns: ["*.safetensors"]))
    }

    @Test func removeStalePartialsDeletesPartAndMetaFiles() throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let nested = dir.appending(path: "tokenizer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let partial = nested.appending(path: "tokenizer.json.part")
        let metadata = nested.appending(path: "tokenizer.json.meta")
        let complete = nested.appending(path: "tokenizer.json")
        try Data(count: 1).write(to: partial)
        try Data(count: 1).write(to: metadata)
        try Data(count: 1).write(to: complete)

        downloader.removeStalePartials(in: dir)

        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(!FileManager.default.fileExists(atPath: metadata.path))
        #expect(FileManager.default.fileExists(atPath: complete.path))
    }

    @Test func rejectsUnsafeRelativePaths() {
        #expect(downloader.isSafeRelativePath("weights.safetensors"))
        #expect(downloader.isSafeRelativePath("tokenizer/tokenizer.json"))
        #expect(!downloader.isSafeRelativePath(""))
        #expect(!downloader.isSafeRelativePath("/weights.safetensors"))
        #expect(!downloader.isSafeRelativePath("tokenizer/../config.json"))
        #expect(!downloader.isSafeRelativePath("tokenizer//config.json"))
        #expect(!downloader.isSafeRelativePath("tokenizer\\config.json"))
        #expect(!downloader.isSafeRelativePath("tokenizer/\u{0}/config.json"))
    }
}
