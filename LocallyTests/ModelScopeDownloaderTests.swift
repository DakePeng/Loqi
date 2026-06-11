import Foundation
import Testing
@testable import Locally

/// Tests the downloader's pure logic: pattern filtering, manifest-based
/// snapshot validation, and the tail() primitive used by overlap-verified
/// resume. Network paths are exercised on-device.
struct ModelScopeDownloaderTests {
    let downloader = ModelScopeDownloader()

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func patternMatching() {
        #expect(downloader.matches("model.safetensors", patterns: ["*.safetensors"]))
        #expect(downloader.matches("sub/dir/model.safetensors", patterns: ["*.safetensors"]))
        #expect(downloader.matches("config.json", patterns: ["*.safetensors", "*.json"]))
        #expect(!downloader.matches("README.md", patterns: ["*.safetensors", "*.json"]))
        #expect(downloader.matches("anything.bin", patterns: []))
    }

    @Test func manifestRoundTripValidates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data("hello world".utf8)
        try payload.write(to: dir.appending(path: "config.json"))
        let files = [ModelScopeDownloader.FileEntry(
            path: "config.json", size: Int64(payload.count))]

        try downloader.writeManifest(files, to: dir)
        #expect(downloader.isValidSnapshot(dir))
    }

    @Test func manifestCatchesTruncatedFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("short".utf8).write(to: dir.appending(path: "weights.bin"))
        let files = [ModelScopeDownloader.FileEntry(path: "weights.bin", size: 9999)]
        try downloader.writeManifest(files, to: dir)
        #expect(!downloader.isValidSnapshot(dir))
    }

    @Test func manifestCatchesMissingFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = [ModelScopeDownloader.FileEntry(path: "gone.bin", size: 10)]
        try downloader.writeManifest(files, to: dir)
        #expect(!downloader.isValidSnapshot(dir))
    }

    @Test func emptyDirectoryIsInvalid() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!downloader.isValidSnapshot(dir))
    }

    @Test func tailReadsLastBytes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appending(path: "data.bin")
        try Data("0123456789".utf8).write(to: file)
        let tail = try downloader.tail(of: file, count: 4)
        #expect(tail == Data("6789".utf8))
        // Requesting more than exists returns the whole file.
        let all = try downloader.tail(of: file, count: 100)
        #expect(all == Data("0123456789".utf8))
    }
}
